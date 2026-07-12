// SfmLapackBench — on-device A/B: finalize (enrich + stage1 + stage2 global BA)
// over the SAME cap47 live db, alternating dense backend EIGEN vs LAPACK
// (Accelerate) via the AETHER_EXTRA_DENSE / AETHER_DENSE_LAPACK env hooks in
// the vendored colmap routing. Unplug-safe: auto-starts, logs to
// Documents/run.log, writes Documents/DONE at the end (poll via devicectl).
import SwiftUI
import UIKit

@main
struct SfmLapackBenchApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

func docs() -> String { NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] }

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ip, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576.0 : -1
}

func thermalStr() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

final class BenchLog {
    let path = docs() + "/run.log"
    private let q = DispatchQueue(label: "benchlog")
    var onLine: ((String) -> Void)?
    func line(_ s: String) {
        let stamped = "[\(ISO8601DateFormatter().string(from: Date()))] " + s
        q.sync {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write((stamped + "\n").data(using: .utf8)!)
                h.closeFile()
            } else {
                try? (stamped + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        onLine?(stamped)
    }
}

struct ContentView: View {
    @State private var log = "SfmLapackBench cap47 EIGEN vs LAPACK\n"
    @State private var started = false
    var body: some View {
        ScrollView {
            Text(log).font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .onAppear {
            guard !started else { return }
            started = true
            UIApplication.shared.isIdleTimerDisabled = true
            runBattery { s in DispatchQueue.main.async { log = String((log + s + "\n").suffix(6000)) } }
        }
    }
}

func runBattery(_ ui: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let L = BenchLog(); L.onLine = ui
        try? FileManager.default.removeItem(atPath: docs() + "/DONE")
        guard let src = Bundle.main.path(forResource: "cap47_live", ofType: "db") else {
            L.line("FATAL no bundled db"); try? "FAIL".write(toFile: docs() + "/DONE", atomically: true, encoding: .utf8); return
        }
        // Both arms force DENSE_SCHUR at every size so the ONLY difference is
        // the dense backend (EIGEN vs LAPACK/Accelerate).
        setenv("AETHER_EXTRA_DENSE", "1", 1)
        // Pair 2 relaunch (pair 1 = E1,L1 ran in a previous launch; the 4-round
        // single-process battery died at round 3, suspected jetsam). Fresh
        // process runs L2,E2 — position-counterbalanced vs pair 1.
        let rounds: [(String, Bool)] = [("L2", true), ("E2", false)]
        L.line("device battery start rounds=\(rounds.map { $0.0 }.joined(separator: ","))")
        for (name, lapack) in rounds {
            // Thermal control: wait until state <= fair (max 5 min).
            var waited = 0
            while true {
                let t = thermalStr()
                if t == "nominal" || t == "fair" || waited >= 300 { L.line("round \(name) thermal_pre=\(t) waited=\(waited)s footprint=\(String(format: "%.0f", physFootprintMB()))MB"); break }
                Thread.sleep(forTimeInterval: 15); waited += 15
            }
            // [2026-07-12 tier routing] E arm now sets =0 explicitly (force
            // EIGEN): with the num_images tier routing in the colmap router,
            // an UNSET env means "route by size" — no longer a forced-E arm.
            setenv("AETHER_DENSE_LAPACK", lapack ? "1" : "0", 1)

            let dbPath = docs() + "/r\(name).db"
            try? FileManager.default.removeItem(atPath: dbPath)
            do { try FileManager.default.copyItem(atPath: src, toPath: dbPath) }
            catch { L.line("FATAL db copy \(error)"); break }

            var opts = aether_sfm_options_t()
            aether_sfm_options_default(&opts)
            opts.k_neighbors = 12
            opts.use_gpu_match = 1   // prod Metal GEMM matcher TU is linked
            opts.use_gpu_extract = 0

            var session: OpaquePointer? = nil
            var rc = aether_sfm_create(dbPath, &opts, &session)
            guard rc == AETHER_SFM_OK, session != nil else {
                L.line("round \(name) create FAILED rc=\(rc)"); continue
            }
            var json = [CChar](repeating: 0, count: 1024)
            let t0 = Date()
            rc = aether_sfm_finalize_async(session, &json, 1024)
            L.line("round \(name) phase1 rc=\(rc) json=\(String(cString: json))")
            guard rc == AETHER_SFM_OK else { aether_sfm_free(session); continue }
            var status: Int32 = 0
            repeat {
                Thread.sleep(forTimeInterval: 0.5)
                status = aether_sfm_finalize_status(session)
            } while status == 1
            let wall = Date().timeIntervalSince(t0)
            L.line("round \(name) phase2 status=\(status) wall=\(String(format: "%.1f", wall))s thermal_post=\(thermalStr())")
            if status == 2 {
                var reproj = 0.0
                var pts: Int64 = 0, t3: Int64 = 0, obs: Int64 = 0
                aether_sfm_final_diag(session, &reproj, &pts, &t3, &obs)
                var nposes: Int32 = 0
                _ = aether_sfm_get_poses(session, nil, 0, &nposes)
                L.line("round \(name) RESULT final points=\(pts) track3plus=\(t3) obs=\(obs) mean_reproj_px=\(String(format: "%.4f", reproj)) registered=\(nposes)")
                let modelDir = docs() + "/model_\(name)"
                try? FileManager.default.removeItem(atPath: modelDir)
                try? FileManager.default.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
                let drc = aether_sfm_debug_dump_model(session, modelDir)
                L.line("round \(name) model dump rc=\(drc)")
                // finalize_segments.json lands next to the db (Documents) — archive per round.
                let seg = docs() + "/finalize_segments.json"
                if FileManager.default.fileExists(atPath: seg) {
                    let dst = docs() + "/segments_\(name).json"
                    try? FileManager.default.removeItem(atPath: dst)
                    try? FileManager.default.copyItem(atPath: seg, toPath: dst)
                    if let d = try? String(contentsOfFile: seg, encoding: .utf8) { L.line("round \(name) segments \(d.trimmingCharacters(in: .whitespacesAndNewlines))") }
                }
            }
            aether_sfm_free(session)  // also drops the db copy
            L.line("round \(name) done")
        }
        L.line("battery DONE")
        try? "OK".write(toFile: docs() + "/DONE", atomically: true, encoding: .utf8)
    }
}

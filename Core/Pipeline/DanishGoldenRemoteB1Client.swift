// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import NIOCore
import NIOSSH
import SSHClient

actor DanishGoldenRemoteB1Client: RemoteB1Client {
    private struct Config: Sendable {
        let host = "ssh7.vast.ai"
        let port = UInt16(24151)
        let user = "root"
        let expectedHostOpenSSHKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBUY+XaZrvdOE7UAR+2qsWAKJes4GhpCUSiIMhuMCP8y ssh7.vast.ai"
        let inputDirectory = "/root/donor_whitebox/inputs/real_videos"
        let outputsDirectory = "/root/donor_whitebox/outputs"
        let scriptsDirectory = "/root/donor_whitebox/scripts"
        let connectionAttempts = 3
        let connectionRetryDelaySeconds: UInt64 = 2
        let startAcknowledgeTimeoutSeconds = 8

        var startScript: String {
            "\(scriptsDirectory)/remote_start_realvideo_autofallback_run.sh"
        }
    }

    private struct AssetRecord: Sendable {
        let remotePath: String
    }

    private struct JobRecord: Sendable {
        let assetId: String
        let runName: String
        let outputRoot: String
        var selectedArtifactPath: String?
        var selectedSummaryPath: String?
        var selectedVerdictPath: String?
    }

    private struct RemotePollSnapshot: Decodable, Sendable {
        let state: String
        let progress: Double?
        let stage: String?
        let detail: String?
        let reason: String?
        let etaMinutes: Int?
        let elapsedSeconds: Int?
        let progressBasis: String?
        let artifactPath: String?
        let summaryPath: String?
        let verdictPath: String?
    }

    private let config = Config()
    private var assets: [String: AssetRecord] = [:]
    private var jobs: [String: JobRecord] = [:]

    private func recoveredJobRecord(for jobId: String) -> JobRecord {
        JobRecord(
            assetId: "recovered",
            runName: jobId,
            outputRoot: "\(config.outputsDirectory)/hislam2_\(jobId)",
            selectedArtifactPath: nil,
            selectedSummaryPath: nil,
            selectedVerdictPath: nil
        )
    }

    func upload(
        videoURL: URL,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RemoteB1ClientError.uploadFailed("Input file does not exist")
        }

        let assetId = Self.makeStableToken()
        let remoteExtension = Self.normalizedVideoExtension(for: videoURL)
        let remotePath = "\(config.inputDirectory)/\(assetId).\(remoteExtension)"
        let totalBytes = Self.fileSize(of: videoURL)
        guard totalBytes > 0 else {
            throw RemoteB1ClientError.uploadFailed("Input file is empty")
        }

        if let onProgress {
            await onProgress(
                RemoteUploadProgress(
                    uploadedBytes: 0,
                    totalBytes: totalBytes
                )
            )
        }

        try await withConnection { connection in
            _ = try await Self.runCommand("mkdir -p \(Self.shellQuote(config.inputDirectory))", over: connection)
            let sftp = try await connection.requestSFTPClient(withTimeout: 20.0)
            defer { Task { await sftp.close() } }
            try await Self.writeRemoteFile(
                from: videoURL,
                totalBytes: totalBytes,
                to: remotePath,
                using: sftp,
                onProgress: onProgress
            )
        }

        assets[assetId] = AssetRecord(remotePath: remotePath)
        return assetId
    }

    func startJob(assetId: String) async throws -> String {
        guard let asset = assets[assetId] else {
            throw RemoteB1ClientError.invalidResponse
        }

        let runName = Self.makeRunName(for: assetId)
        let command = [
            "bash",
            Self.shellQuote(config.startScript),
            Self.shellQuote(runName),
            Self.shellQuote(asset.remotePath),
        ].joined(separator: " ")

        try await withConnection { connection in
            _ = try await Self.runCommand(command, over: connection)
        }

        let accepted = try await withConnection { connection in
            try await Self.confirmRemoteStartAccepted(
                runName: runName,
                outputsDirectory: config.outputsDirectory,
                over: connection,
                timeoutSeconds: config.startAcknowledgeTimeoutSeconds
            )
        }
        guard accepted else {
            throw RemoteB1ClientError.networkError("remote_start_not_acknowledged")
        }

        jobs[runName] = JobRecord(
            assetId: assetId,
            runName: runName,
            outputRoot: "\(config.outputsDirectory)/hislam2_\(runName)",
            selectedArtifactPath: nil,
            selectedSummaryPath: nil,
            selectedVerdictPath: nil
        )
        return runName
    }

    func pollStatus(jobId: String) async throws -> JobStatus {
        var job = jobs[jobId] ?? recoveredJobRecord(for: jobId)

        let snapshot: RemotePollSnapshot = try await withConnection { connection in
            try await Self.runJSONCommand(Self.makePollCommand(job: job), over: connection)
        }

        job.selectedArtifactPath = snapshot.artifactPath
        job.selectedSummaryPath = snapshot.summaryPath
        job.selectedVerdictPath = snapshot.verdictPath
        jobs[jobId] = job

        func makeProgress() -> RemoteJobProgress {
            RemoteJobProgress(
                progressFraction: snapshot.progress.map { $0 / 100.0 },
                stageKey: snapshot.stage,
                detail: snapshot.detail,
                etaMinutes: snapshot.etaMinutes,
                elapsedSeconds: snapshot.elapsedSeconds,
                progressBasis: snapshot.progressBasis
            )
        }

        switch snapshot.state {
        case "completed":
            return .completed(makeProgress())
        case "failed":
            return .failed(
                reason: snapshot.reason ?? "remote_failed",
                progress: makeProgress()
            )
        case "pending":
            return .pending(makeProgress())
        default:
            return .processing(makeProgress())
        }
    }

    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        let job = jobs[jobId] ?? recoveredJobRecord(for: jobId)

        let artifactPath: String
        if let selectedArtifactPath = job.selectedArtifactPath {
            artifactPath = selectedArtifactPath
        } else {
            let snapshot: RemotePollSnapshot = try await withConnection { connection in
                try await Self.runJSONCommand(Self.makePollCommand(job: job), over: connection)
            }
            guard let selectedArtifactPath = snapshot.artifactPath else {
                throw RemoteB1ClientError.downloadFailed("No remote artifact selected")
            }
            artifactPath = selectedArtifactPath
        }

        let payload = try await withConnection { connection in
            let sftp = try await connection.requestSFTPClient(withTimeout: 20.0)
            defer { Task { await sftp.close() } }
            return try await Self.readRemoteFile(at: artifactPath, using: sftp)
        }
        guard !payload.isEmpty else {
            throw RemoteB1ClientError.downloadFailed("Downloaded artifact is empty")
        }
        return (payload, .splatPly)
    }

    func cancel(jobId: String) async throws {
        let pidFile = "/root/donor_whitebox/logs/\(jobId).pid"
        let cancelMarker = "/root/donor_whitebox/outputs/hislam2_\(jobId)/summaries/CANCELLED.json"
        let command = """
set -e
mkdir -p $(dirname \(Self.shellQuote(cancelMarker)))
if [ -f \(Self.shellQuote(pidFile)) ]; then
  pid=$(cat \(Self.shellQuote(pidFile)) 2>/dev/null || true)
  if [ -n "$pid" ]; then
    pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 1
    pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
fi
printf '{"state":"cancelled","reason":"cancelled_by_user"}\\n' > \(Self.shellQuote(cancelMarker))
"""
        try await withConnection { connection in
            _ = try await Self.runCommand(command, over: connection)
        }
        jobs.removeValue(forKey: jobId)
    }

    private func withConnection<T>(
        _ body: (SSHConnection) async throws -> T
    ) async throws -> T {
        var lastError: RemoteB1ClientError?

        for attempt in 1...config.connectionAttempts {
            let (connection, authorizedKeyLine) = try Self.makeConnection(config: config)
            do {
                try await connection.start(withTimeout: 20.0)
                let result = try await body(connection)
                await connection.cancel()
                return result
            } catch let remoteError as RemoteB1ClientError {
                await connection.cancel()
                lastError = remoteError
                guard attempt < config.connectionAttempts, Self.shouldRetry(remoteError) else {
                    throw remoteError
                }
            } catch {
                await connection.cancel()
                let wrapped = Self.wrapConnectionError(error, authorizedKeyLine: authorizedKeyLine)
                lastError = wrapped
                guard attempt < config.connectionAttempts, Self.shouldRetry(wrapped) else {
                    throw wrapped
                }
            }

            try? await Task.sleep(
                nanoseconds: config.connectionRetryDelaySeconds * 1_000_000_000
            )
        }

        throw lastError ?? RemoteB1ClientError.networkError("ssh_connection_failed")
    }

    private static func makeConnection(config: Config) throws -> (SSHConnection, String) {
        let identity = try DanishGoldenSSHProvisioning.loadIdentity()
        let authDelegate = DanishGoldenSSHUserAuthDelegate(
            username: config.user,
            privateKey: NIOSSHPrivateKey(ed25519Key: identity.privateKey)
        )
        let hostValidator = DanishGoldenSSHHostKeyValidator(
            expectedOpenSSHKey: config.expectedHostOpenSSHKey
        )
        let authentication = SSHAuthentication(
            username: config.user,
            method: .custom(authDelegate),
            hostKeyValidation: .custom(hostValidator)
        )
        let connection = SSHConnection(
            host: config.host,
            port: config.port,
            authentication: authentication,
            defaultTimeout: 20.0
        )
        return (connection, identity.authorizedKeyLine)
    }

    private static func makeStableToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func makeRunName(for assetId: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let raw = formatter.string(from: Date())
        let compact = raw
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        return "mobile_\(assetId)_autofallback_\(compact)"
    }

    private static func normalizedVideoExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "mov" {
            return ext
        }
        return "mp4"
    }

    private static func fileSize(of url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let sizeNumber = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return sizeNumber.int64Value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func runCommand(
        _ command: String,
        over connection: SSHConnection
    ) async throws -> SSHCommandResponse {
        let response = try await connection.execute(
            SSHCommand("bash -lc \(shellQuote(command))"),
            withTimeout: 30.0
        )
        guard response.status.exitStatus == 0 else {
            let stderr = response.errorOutput.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let stdout = response.standardOutput.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let message = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "remote_command_failed"
            throw RemoteB1ClientError.networkError(message)
        }
        return response
    }

    private static func runJSONCommand<T: Decodable>(
        _ command: String,
        over connection: SSHConnection
    ) async throws -> T {
        let response = try await runCommand(command, over: connection)
        guard let payload = response.standardOutput, !payload.isEmpty else {
            throw RemoteB1ClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw RemoteB1ClientError.invalidResponse
        }
    }

    private static func writeRemoteFile(
        from localURL: URL,
        totalBytes: Int64,
        to remotePath: String,
        using sftp: SFTPClient,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws {
        let remoteFile = try await sftp.openFile(
            at: SFTPFilePath(remotePath),
            flags: [.create, .truncate, .write]
        )
        let chunkSize = 2 * 1024 * 1024
        do {
            let localFile = try FileHandle(forReadingFrom: localURL)
            defer {
                try? localFile.close()
            }

            var offset: Int64 = 0
            while offset < totalBytes {
                guard let chunk = try localFile.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }
                try await remoteFile.write(chunk, at: UInt64(offset))
                offset += Int64(chunk.count)

                if let onProgress {
                    await onProgress(
                        RemoteUploadProgress(
                            uploadedBytes: offset,
                            totalBytes: totalBytes
                        )
                    )
                }
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw RemoteB1ClientError.uploadFailed(String(describing: error))
        }
    }

    private static func readRemoteFile(
        at remotePath: String,
        using sftp: SFTPClient
    ) async throws -> Data {
        let file = try await sftp.openFile(at: SFTPFilePath(remotePath), flags: [.read])
        let expectedSize = try? await sftp.getAttributes(at: SFTPFilePath(remotePath)).size
        var offset: UInt64 = 0
        var data = Data()
        let chunkLength: UInt32 = 256 * 1024

        do {
            while true {
                let chunk = try await file.read(from: offset, length: chunkLength)
                if chunk.isEmpty {
                    break
                }
                data.append(chunk)
                offset += UInt64(chunk.count)
                if let expectedSize, offset >= expectedSize {
                    break
                }
            }
            try await file.close()
            return data
        } catch {
            try? await file.close()
            throw RemoteB1ClientError.downloadFailed(String(describing: error))
        }
    }

    private static func wrapConnectionError(
        _ error: Error,
        authorizedKeyLine: String
    ) -> RemoteB1ClientError {
        let message = describeConnectionError(error)
        let lowered = message.lowercased()
        if lowered.contains("permission denied") || lowered.contains("authentication") || lowered.contains("userauth") {
            return .networkError(
                "The iPhone SSH key is not authorized on the Danish 5090 yet. Add this line to ~/.ssh/authorized_keys: \(authorizedKeyLine)"
            )
        }
        return .networkError(message)
    }

    private static func describeConnectionError(_ error: Error) -> String {
        let nsError = error as NSError
        let typeName = String(reflecting: type(of: error))
        let brief = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        let reflected = String(reflecting: error).trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        parts.append("type=\(typeName)")

        if !nsError.domain.isEmpty || nsError.code != 0 {
            parts.append("ns=\(nsError.domain)(\(nsError.code))")
        }

        if !brief.isEmpty, brief.lowercased() != "unknown" {
            parts.append("desc=\(brief)")
        }

        if !reflected.isEmpty, reflected != brief {
            parts.append("reflect=\(reflected)")
        }

        if parts.count == 1 {
            return "unknown_ssh_error | \(parts[0])"
        }
        return parts.joined(separator: " | ")
    }

    private static func shouldRetry(_ error: RemoteB1ClientError) -> Bool {
        switch error {
        case .networkError, .networkTimeout, .invalidResponse:
            return true
        case .uploadFailed, .downloadFailed, .jobFailed, .notConfigured:
            return false
        }
    }

    private static func confirmRemoteStartAccepted(
        runName: String,
        outputsDirectory: String,
        over connection: SSHConnection,
        timeoutSeconds: Int
    ) async throws -> Bool {
        let pidFile = "/root/donor_whitebox/logs/\(runName).pid"
        let launchLog = "/root/donor_whitebox/logs/\(runName).launch.log"
        let outputRoot = "\(outputsDirectory)/hislam2_\(runName)"
        let command = """
deadline=$((SECONDS+\(timeoutSeconds)))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -s \(shellQuote(pidFile)) ] || [ -f \(shellQuote(launchLog)) ] || [ -d \(shellQuote(outputRoot)) ]; then
    printf 'accepted\\n'
    exit 0
  fi
  sleep 1
done
printf 'not_accepted\\n'
exit 9
"""
        let response = try await connection.execute(
            SSHCommand("bash -lc \(shellQuote(command))"),
            withTimeout: Double(timeoutSeconds + 4)
        )
        return response.status.exitStatus == 0
    }

    private static func makePollCommand(job: JobRecord) -> String {
        let outputRoot = shellQuote(job.outputRoot)
        let launchLog = shellQuote("/root/donor_whitebox/logs/\(job.runName).launch.log")
        let logsRoot = shellQuote("/root/donor_whitebox/logs/\(job.runName)")
        return """
python3 - <<'PY'
import json
import pathlib
import time

output_root = pathlib.Path(\(outputRoot))
summaries = output_root / "summaries"
launch_log = pathlib.Path(\(launchLog))
logs_root = pathlib.Path(\(logsRoot))
pid_file = pathlib.Path("/root/donor_whitebox/logs/\(job.runName).pid")
tiers = ["official_default", "global100_seq", "global200_seq", "global200_exhaustive"]

def load_json(path):
    if not path.exists():
        return None
    return json.loads(path.read_text())

def extract_prep_failure_detail(tier):
    log_path = logs_root / f"{tier}_prep.log"
    if not log_path.exists():
        return None
    text = log_path.read_text(errors="ignore")
    lowered = text.lower()
    if "no images with matches found in the database" in lowered:
        if "cameras.txt" in lowered or "failed to create sparse model" in lowered:
            return "没有建立出足够的图像匹配，未生成可用 sparse / cameras.txt"
        return "没有建立出足够的图像匹配"
    if "failed to create sparse model" in lowered:
        return "未能建立可用的 sparse model"
    if "feature_extractor" in lowered and "sigkill" in lowered:
        return "COLMAP feature_extractor 被 SIGKILL 中止，疑似内存压力"
    if "too few frames selected for colmap" in lowered:
        return "可用帧数量过少，无法完成 COLMAP 预处理"
    if "cameras.txt" in lowered:
        return "COLMAP 没有产出 cameras.txt"

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    for line in reversed(lines):
        lower_line = line.lower()
        if (
            "calledprocesserror" in lower_line
            or "runtimeerror" in lower_line
            or "filenotfounderror" in lower_line
            or "sigkill" in lower_line
        ):
            return line
    return lines[-1] if lines else None

def summarize_all_tier_failures():
    summary_lines = ["这次失败发生在远端预处理阶段："]
    compact_parts = []
    seen_failure = False

    for tier in tiers:
        failure = load_json(summaries / f"{tier}_prep_failure.json")
        if not failure:
            continue
        seen_failure = True
        raw_reason = failure.get("reason") or "prep_failed"
        detail = extract_prep_failure_detail(tier) or raw_reason
        compact_parts.append(f"{tier}={raw_reason}")
        summary_lines.append(f"- {tier}: {detail}")

    if not seen_failure:
        return ("all_tiers_failed", "远端尝试了多个 tier，但这次没有生成可用结果。")

    return ("all_tiers_failed:" + ";".join(compact_parts), "\\n".join(summary_lines))

def read_runner_pid():
    if not pid_file.exists():
        return None
    try:
        text = pid_file.read_text().strip()
        return int(text) if text else None
    except Exception:
        return None

def read_ps_rows():
    try:
        import subprocess
        output = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return []
    rows = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            rows.append((int(parts[0]), parts[1]))
        except ValueError:
            continue
    return rows

def normalize_runtime_status(data):
    if not isinstance(data, dict):
        return None

    state = data.get("state")
    stage = data.get("stage")
    detail = data.get("detail")
    reason = data.get("reason")
    progress_basis = data.get("progress_basis")
    progress = data.get("progress")
    progress_start = data.get("progress_start")
    progress_end = data.get("progress_end")
    phase_budget_sec = data.get("phase_budget_sec")
    phase_started_at_epoch = data.get("phase_started_at_epoch")
    run_started_at_epoch = data.get("run_started_at_epoch")

    elapsed_sec = data.get("elapsed_sec")
    if elapsed_sec is None and isinstance(run_started_at_epoch, (int, float)):
        elapsed_sec = max(0, int(time.time() - float(run_started_at_epoch)))
    elif isinstance(elapsed_sec, (int, float)):
        elapsed_sec = max(0, int(elapsed_sec))
    else:
        elapsed_sec = None

    estimated_remaining_sec = data.get("estimated_remaining_sec")
    over_budget = False
    if estimated_remaining_sec is None and isinstance(phase_budget_sec, (int, float)) and isinstance(phase_started_at_epoch, (int, float)):
        phase_budget_sec = max(0, int(phase_budget_sec))
        phase_elapsed = max(0, int(time.time() - float(phase_started_at_epoch)))
        if phase_budget_sec > 0:
            if phase_elapsed <= int(phase_budget_sec * 1.25):
                estimated_remaining_sec = max(0, phase_budget_sec - phase_elapsed)
            else:
                over_budget = True
                estimated_remaining_sec = None

        if progress is None and isinstance(progress_start, (int, float)) and isinstance(progress_end, (int, float)):
            if phase_budget_sec > 0:
                ratio = min(1.0, max(0.0, phase_elapsed / max(float(phase_budget_sec), 1.0)))
                progress = float(progress_start) + (float(progress_end) - float(progress_start)) * ratio
            else:
                progress = float(progress_end)

    if isinstance(progress, (int, float)):
        progress = max(0.0, min(100.0, float(progress)))
    else:
        progress = None

    eta_minutes = None
    if isinstance(estimated_remaining_sec, (int, float)) and estimated_remaining_sec >= 0:
        estimated_remaining_sec = int(estimated_remaining_sec)
        eta_minutes = 0 if estimated_remaining_sec == 0 else max(1, (estimated_remaining_sec + 59) // 60)
    else:
        estimated_remaining_sec = None

    if over_budget and isinstance(detail, str) and "超过预估" not in detail:
        detail = detail + " 当前阶段耗时已经超过预估，但远端仍在继续。"
        progress_basis = "runtime_over_budget"

    return {
        "state": state,
        "stage": stage,
        "detail": detail,
        "reason": reason,
        "progress": progress,
        "eta_minutes": eta_minutes,
        "elapsed_sec": elapsed_sec,
        "progress_basis": progress_basis or "runtime_status",
    }

selected = None
success = load_json(summaries / "SUCCESS.json") if summaries.exists() else None
if success:
    artifact_path_raw = str(success.get("artifact_path") or "").strip()
    artifact_path = pathlib.Path(artifact_path_raw) if artifact_path_raw else None
    if artifact_path and artifact_path.exists():
        summary_path_raw = str(success.get("summary_path") or "").strip()
        verdict_path_raw = str(success.get("verdict_path") or "").strip()
        selected = {{
            "artifactPath": str(artifact_path),
            "summaryPath": summary_path_raw if summary_path_raw and pathlib.Path(summary_path_raw).exists() else None,
            "verdictPath": verdict_path_raw if verdict_path_raw and pathlib.Path(verdict_path_raw).exists() else None,
        }}

if selected is None:
    for tier in tiers:
        summary = load_json(summaries / f"{tier}_full_summary.json")
        verdict = load_json(summaries / f"{tier}_full_verdict.json")
        candidate = output_root / f"{tier}_out" / "3dgs_final.ply"
        if summary and summary.get("has_3dgs_final") and candidate.exists():
            selected = {{
                "artifactPath": str(candidate),
                "summaryPath": str(summaries / f"{tier}_full_summary.json"),
                "verdictPath": str(summaries / f"{tier}_full_verdict.json") if verdict else None,
            }}
            break

if selected is None:
    for tier in tiers:
        summary = load_json(summaries / f"{tier}_probe_summary.json")
        verdict = load_json(summaries / f"{tier}_probe_verdict.json")
        candidate = output_root / f"{tier}_probe" / "3dgs_final.ply"
        if summary and verdict and summary.get("has_3dgs_final") and verdict.get("passed") is True and candidate.exists():
            selected = {{
                "artifactPath": str(candidate),
                "summaryPath": str(summaries / f"{tier}_probe_summary.json"),
                "verdictPath": str(summaries / f"{tier}_probe_verdict.json"),
            }}
            break

cancelled = load_json(summaries / "CANCELLED.json") if summaries.exists() else None
summary_files = [p.name for p in summaries.glob("*.json")] if summaries.exists() else []
non_cancel_summary_files = [name for name in summary_files if name != "CANCELLED.json"]
progress_files = len(non_cancel_summary_files)
prep_dirs = [p for p in output_root.glob("*_prep") if p.is_dir()] if output_root.exists() else []
probe_dirs = [p for p in output_root.glob("*_probe") if p.is_dir()] if output_root.exists() else []
out_dirs = [p for p in output_root.glob("*_out") if p.is_dir()] if output_root.exists() else []
has_sparse = any((prep / "sparse").exists() for prep in prep_dirs)
has_colmap_db = any((prep / "colmap.db").exists() for prep in prep_dirs)
summary_runtime = load_json(summaries / "RUNTIME_STATUS.json") if summaries.exists() else None
prep_runtime = None
if prep_dirs and not probe_dirs and not out_dirs:
    prep_runtime_paths = [
        prep / "runtime_status.json"
        for prep in prep_dirs
        if (prep / "runtime_status.json").exists()
    ]
    prep_runtime_paths = sorted(prep_runtime_paths, key=lambda p: p.stat().st_mtime, reverse=True)
    if prep_runtime_paths:
        prep_runtime = load_json(prep_runtime_paths[0])
runtime_snapshot = None
if prep_runtime is not None:
    runtime_snapshot = normalize_runtime_status(prep_runtime)
elif summary_runtime is not None:
    runtime_snapshot = normalize_runtime_status(summary_runtime)
state = "processing"
progress = 24.0
stage = "queued"
detail = "远端已经接收任务，正在准备下一阶段。"
reason = None
eta_minutes = None
elapsed_sec = None
progress_basis = None
estimated_remaining_sec = None

timestamps = []
if launch_log.exists():
    timestamps.append(launch_log.stat().st_mtime)
if output_root.exists():
    timestamps.append(output_root.stat().st_mtime)
for candidate in prep_dirs + probe_dirs + out_dirs:
    try:
        timestamps.append(candidate.stat().st_mtime)
    except OSError:
        pass
if summaries.exists():
    for candidate in summaries.glob("*.json"):
        try:
            timestamps.append(candidate.stat().st_mtime)
        except OSError:
            pass

if timestamps:
    elapsed_sec = max(0, int(time.time() - min(timestamps)))

last_activity_age_sec = None
if timestamps:
    last_activity_age_sec = max(0, int(time.time() - max(timestamps)))

runner_pid = read_runner_pid()
ps_rows = read_ps_rows()
runner_alive = False
job_worker_commands = []
for pid, command in ps_rows:
    if runner_pid is not None and pid == runner_pid:
        runner_alive = True
    if "\(job.runName)" in command:
        job_worker_commands.append(command)

summary_candidates = []
if summaries.exists():
    summary_candidates = sorted(summaries.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)

for candidate in summary_candidates:
    data = load_json(candidate)
    if not isinstance(data, dict):
        continue

    if elapsed_sec is None:
        for key in ("elapsed_sec", "elapsedSeconds"):
            value = data.get(key)
            if isinstance(value, (int, float)) and value >= 0:
                elapsed_sec = int(value)
                break

    for key in ("estimated_remaining_sec", "estimatedRemainingSeconds"):
        value = data.get(key)
        if isinstance(value, (int, float)) and value >= 0:
            estimated_remaining_sec = int(value)
            eta_minutes = 0 if estimated_remaining_sec == 0 else max(1, (estimated_remaining_sec + 59) // 60)
            progress_basis = "remote_summary"
            break
    if eta_minutes is not None:
        break

if selected is not None and pathlib.Path(selected["artifactPath"]).exists():
    state = "completed"
    progress = 100.0
    stage = "complete"
    detail = "远端训练完成，结果已经可下载。"
    eta_minutes = 0
    progress_basis = "completed"
elif cancelled is not None:
    state = "failed"
    progress = 42.0
    reason = cancelled.get("reason") or "cancelled"
    stage = "cancelled"
    detail = "这次远端任务已经被取消，所以当前不会继续训练。"
    eta_minutes = None
    progress_basis = None
elif launch_log.exists() and "all tiers failed" in launch_log.read_text(errors="ignore"):
    state = "failed"
    progress = 88.0
    reason, detail = summarize_all_tier_failures()
    stage = "sfm"
    eta_minutes = None
    progress_basis = None
elif runtime_snapshot is not None:
    state = runtime_snapshot["state"] or state
    progress = runtime_snapshot["progress"] if runtime_snapshot["progress"] is not None else progress
    stage = runtime_snapshot["stage"] or stage
    detail = runtime_snapshot["detail"] or detail
    reason = runtime_snapshot["reason"] or reason
    eta_minutes = runtime_snapshot["eta_minutes"]
    elapsed_sec = runtime_snapshot["elapsed_sec"] if runtime_snapshot["elapsed_sec"] is not None else elapsed_sec
    progress_basis = runtime_snapshot["progress_basis"]
elif runner_alive and not job_worker_commands and last_activity_age_sec is not None and last_activity_age_sec >= 45:
    state = "failed"
    progress = 58.0 if (probe_dirs or out_dirs) else 42.0
    stage = "failed"
    reason = "remote_runner_orphaned"
    if probe_dirs or any(name.endswith("_probe_failure.json") for name in non_cancel_summary_files):
        detail = "远端已经跑出过一版候选结果，但后续 fallback 没有继续推进；当前只剩 runner 壳进程，预处理/训练 worker 已经不存在。这次任务已经卡住，建议重新发送。"
    else:
        detail = "远端只剩 runner 壳进程，预处理/训练 worker 已经不存在。这次任务已经卡住，建议重新发送。"
    eta_minutes = None
    progress_basis = "orphaned_runner"
elif not output_root.exists():
    state = "pending"
    progress = 12.0
    stage = "queued"
    detail = "任务已经提交到丹麦 5090，正在等待可用时段。"
elif prep_dirs and not probe_dirs and not out_dirs:
    progress = 36.0 if has_sparse else 28.0
    stage = "sfm"
    if any(name.endswith("_prep_failure.json") for name in non_cancel_summary_files):
        detail = "前几档预处理已经失败，远端正在尝试更稳的回退方案做相机重建。"
    else:
        detail = "正在做相机重建和视角对齐。"
elif probe_dirs or out_dirs:
    if out_dirs:
        progress = 78.0
        stage = "export"
        detail = "远端正在整理 3DGS 结果并准备回传。"
    else:
        progress = 58.0
        stage = "train"
        detail = "远端已经进入 3DGS 训练阶段。"
elif progress_files <= 3:
    progress = 24.0
    stage = "queued"
    detail = "远端正在准备新的回退尝试，尚未真正进入 3DGS 训练。"
elif progress_files <= 6:
    progress = 68.0 + (progress_files - 3) * 6.0
    stage = "export"
    detail = "已经接近完成，正在导出 3DGS 结果。"
else:
    progress = 90.0
    stage = "packaging"
    detail = "正在整理结果文件，马上会回传到手机。"

if state == "processing" and progress_basis is None:
    progress_basis = "stage_only"

print(json.dumps({
    "state": state,
    "progress": progress,
    "stage": stage,
    "detail": detail,
    "reason": reason,
    "etaMinutes": eta_minutes,
    "elapsedSeconds": elapsed_sec,
    "progressBasis": progress_basis,
    "artifactPath": None if selected is None else selected["artifactPath"],
    "summaryPath": None if selected is None else selected["summaryPath"],
    "verdictPath": None if selected is None else selected["verdictPath"],
}))
PY
"""
    }
}

private final class DanishGoldenSSHUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.isEmpty || availableMethods.contains(.publicKey) else {
            let noOffer: NIOSSHUserAuthenticationOffer? = nil
            nextChallengePromise.succeed(noOffer)
            return
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

private final class DanishGoldenSSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let expectedOpenSSHKey: String?

    init(expectedOpenSSHKey: String?) {
        self.expectedOpenSSHKey = expectedOpenSSHKey
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        guard let expectedOpenSSHKey else {
            validationCompletePromise.succeed(())
            return
        }

        do {
            let expected = try NIOSSHPublicKey(openSSHPublicKey: expectedOpenSSHKey)
            if expected == hostKey {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(RemoteB1ClientError.networkError("host_key_mismatch"))
            }
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

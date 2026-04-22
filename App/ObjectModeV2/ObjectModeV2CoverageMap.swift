import Foundation

#if canImport(UIKit) && canImport(simd)
import UIKit
import simd

/// Cell 的当前状态。颜色与判定阈值定义在这里,dome 渲染端只读取。
enum DomeCellState: Int, Sendable {
    case empty      // 灰
    case weak       // 黄
    case ok         // 浅绿
    case excellent  // 深绿

    var uiColor: UIColor {
        switch self {
        case .empty:     return UIColor(white: 0.32, alpha: 0.40)
        case .weak:      return UIColor(red: 0.98, green: 0.74, blue: 0.16, alpha: 0.75)
        case .ok:        return UIColor(red: 0.47, green: 0.86, blue: 0.47, alpha: 0.88)
        case .excellent: return UIColor(red: 0.12, green: 0.70, blue: 0.12, alpha: 0.95)
        }
    }
}

/// Cell 坐标:12 方位 × 5 仰角(整球,覆盖 el ∈ [-75°, 75°])。
/// 方位按初始相机 yaw 为 0°,顺时针增大。
/// el 分 5 档,每档 30°:very low / low / equator / high / very high。
/// 5 档覆盖所有常见场景:地面物体(上 3 档)、眼高物体(中 3 档)、
/// 天花板灯/高处海报(下 2 档)。不同场景只填自己能拍到的 cell,
/// 上传上限由 curateForUpload(targetTotal) 从"已填 cell"动态挑 top-K。
/// 必须用户"真位移"(蹲下、垫高、绕圈)才能激活所有 cell —— 原地旋转不涨。
struct DomeCellIndex: Hashable, Sendable {
    let az: Int        // 0..11  (每 30°)
    let el: Int        // 0..4   (0 very low ~-60°, 2 equator ~0°, 4 very high ~60°)

    static let azimuthCount = 12
    static let elevationCount = 5
    static let totalCells = azimuthCount * elevationCount
}

/// 单帧的捕获元数据 —— 不持有像素数据,只留轻量分数。
/// 像素 buffer 是否上传由外部 Recorder 决定,这里只用于 cell 质量判定。
struct CapturedFrameSample: Sendable {
    let timestamp: TimeInterval        // CACurrentMediaTime(),录制阶段用相同时钟
    let azimuth: Float          // rad,相对 worldYaw
    let elevation: Float        // rad
    let sharpness: Float        // Laplacian variance, 越大越清
    let motionScore: Float      // [0,1], 越低越稳(IMU gyro 积分归一)
    let exposureScore: Float    // [0,1], 1 = 最佳
    let frameID: UUID           // 供 Recorder 关联图像
    /// camera→world 4×4 变换(row-major 16 floats)。ARKit 路径有,
    /// externalFeed(纯 CoreMotion)路径为 nil。上传时一并进 curated.json,
    /// 服务器可用来跳过 VGGT pose 估计。
    let cameraExtrinsic4x4: [Float]?
    /// 相机内参 [fx, fy, cx, cy]。ARKit 路径有,其他路径 nil。
    let cameraIntrinsicFxFyCxCy: [Float]?
}

/// C 架构上传单位:curateForUpload 挑完后的一帧。
/// 比 CapturedFrameSample 多携带:所属 cell 的索引 + 状态 + cell 内排名 + 质量分。
/// 服务器收到后按 frameID 去 Recorder 的 manifest.json 匹配 ARKit pose,
/// 然后按 video timestamp 从 .mov 里提帧即可。
struct CuratedFrame: Sendable {
    let sample: CapturedFrameSample
    let azBin: Int              // 0..11
    let elBin: Int              // 0..4
    let cellState: DomeCellState
    let qualityScore: Float     // 0.5*sharpness - 0.3*motion*1000
    let cellRankInTopK: Int     // 0 = cell 内最好那帧, 1 = 次好, ...
}

/// 深绿阈值,对应 §2.3。调参中心。
struct DomeThresholds {
    var minSharpness: Float = 500         // 有效帧下限
    var excellentMinFrames: Int = 2       // 2 帧即可(放宽)
    var excellentMinSharpnessMedian: Float = 600
    var excellentMinAzSpreadDeg: Float = 3  // 3° 即可(放宽)
    var excellentMinTimeSpreadSec: Float = 0.5  // 0.5s 即可
    var excellentMaxMotion: Float = 0.50
    var maxFramesPerCell: Int = 8         // 防止某 cell 被狂刷

    static let `default` = DomeThresholds()
}

/// 轻量 ring buffer,每个 cell 最多保留 N 个有效帧(N=maxFramesPerCell)。
/// 新帧挤掉最旧的帧 → cell 总内存恒定 = 12*3*8 = 288 个 CapturedFrameSample,
/// 每个 sample 约 64 字节 → 约 18 KB,零压力。
final class DomeCoverageMap {
    // MARK: - 输入状态
    private(set) var worldOrigin: SIMD3<Float>?
    private(set) var worldYaw: Float = 0
    let thresholds: DomeThresholds

    // MARK: - 36 cells(存有效帧)
    private var cells: [[RingBufferCell]]

    // MARK: - 汇总
    private(set) var validFrameCount: Int = 0
    private(set) var currentCell: DomeCellIndex?
    private(set) var currentCellState: DomeCellState = .empty

    // MARK: - 回调
    /// cell 状态变化时派发(dome view 监听后更新对应 cell material)。
    var onCellStateChanged: ((DomeCellIndex, DomeCellState) -> Void)?
    var onAggregateChanged: ((_ valid: Int, _ excellent: Int, _ ok: Int) -> Void)?

    init(thresholds: DomeThresholds = .default) {
        self.thresholds = thresholds
        self.cells = Array(
            repeating: Array(
                repeating: RingBufferCell(capacity: thresholds.maxFramesPerCell),
                count: DomeCellIndex.elevationCount
            ),
            count: DomeCellIndex.azimuthCount
        )
    }

    // MARK: - API

    func lockWorldOrigin(_ origin: SIMD3<Float>, yaw: Float) {
        self.worldOrigin = origin
        self.worldYaw = yaw
    }

    /// 相机新一帧(无论是否有效都可以传,由内部判 validity)。返回本帧命中的 cell,nil = 未命中任何有效 cell。
    @discardableResult
    func ingest(sample: CapturedFrameSample) -> DomeCellIndex? {
        // 硬过滤:sharpness 不够直接丢
        guard sample.sharpness >= thresholds.minSharpness else {
            currentCell = nil
            return nil
        }

        let az = sample.azimuth
        let el = sample.elevation

        let azDeg = (Float(az) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        let azNorm = azDeg < 0 ? azDeg + 360 : azDeg
        let azBin = min(DomeCellIndex.azimuthCount - 1,
                        Int(floor(azNorm / (360 / Float(DomeCellIndex.azimuthCount)))))

        let elDeg = el * 180 / .pi
        let elBin: Int
        // 整球 5 档:30° 每档,超出 ±75° 丢弃(极点数据噪声大)。
        if elDeg < -75 || elDeg > 75 { currentCell = nil; return nil }
        else if elDeg < -45 { elBin = 0 }  // very low  [-75, -45)  天花板灯
        else if elDeg < -15 { elBin = 1 }  // low       [-45, -15)  高处海报
        else if elDeg < 15  { elBin = 2 }  // equator   [-15,  15)  平拍
        else if elDeg < 45  { elBin = 3 }  // high      [ 15,  45)  地面物体
        else                { elBin = 4 }  // very high [ 45,  75]  俯冲特写

        let index = DomeCellIndex(az: azBin, el: elBin)
        let prevState = cells[azBin][elBin].state(using: thresholds)
        cells[azBin][elBin].append(sample)
        validFrameCount += 1
        // 修法 A:把"这次新算的 raw state"推上高水位,确保后续 state() 单调不退色。
        // 即使新帧让 raw 计算掉回 .ok,高水位还在 .excellent → 对外仍报 .excellent。
        let rawComputed = cells[azBin][elBin].computeRawState(using: thresholds)
        cells[azBin][elBin].bumpHighWater(to: rawComputed)
        let newState = cells[azBin][elBin].state(using: thresholds)

        currentCell = index
        currentCellState = newState

        if newState != prevState {
            onCellStateChanged?(index, newState)
            emitAggregate()
        }
        return index
    }

    func state(at index: DomeCellIndex) -> DomeCellState {
        cells[index.az][index.el].state(using: thresholds)
    }

    func reset() {
        for a in 0..<DomeCellIndex.azimuthCount {
            for e in 0..<DomeCellIndex.elevationCount {
                cells[a][e].clear()
            }
        }
        validFrameCount = 0
        currentCell = nil
        currentCellState = .empty
        worldOrigin = nil
        worldYaw = 0
        emitAggregate()
    }

    /// 提供给 Recorder/UI:各等级 cell 计数。
    func cellCounts() -> (empty: Int, weak: Int, ok: Int, excellent: Int) {
        var c = (0, 0, 0, 0)
        for a in 0..<DomeCellIndex.azimuthCount {
            for e in 0..<DomeCellIndex.elevationCount {
                switch cells[a][e].state(using: thresholds) {
                case .empty:     c.0 += 1
                case .weak:      c.1 += 1
                case .ok:        c.2 += 1
                case .excellent: c.3 += 1
                }
            }
        }
        return c
    }

    /// 最终上传清单:只保留 ok/excellent cell 的所有有效帧 frameID。
    /// Recorder 据此过滤实际要打包的图像。
    /// 注意:这是 v1 的"拍谁传谁"接口,会返回所有累积候选帧(可能 200+)。
    /// 新的 C 架构应改用 curateForUpload(targetTotal:) —— 客户端就地挑 top-K,
    /// 服务器不需再做 az×el。保留此接口供灰度期过渡。
    func frameIDsToUpload() -> [UUID] {
        var out: [UUID] = []
        for a in 0..<DomeCellIndex.azimuthCount {
            for e in 0..<DomeCellIndex.elevationCount {
                let s = cells[a][e].state(using: thresholds)
                if s == .ok || s == .excellent {
                    out.append(contentsOf: cells[a][e].frameIDs)
                }
            }
        }
        return out
    }

    // MARK: - C 架构:客户端 curate

    /// 单帧的"质量分" —— sharpness 是主导,motion 扣分。
    /// 系数 1000 = motion 乘回和 sharpness 同量级(sharpness 典型 100~2000,motion [0,1])。
    private func qualityScore(_ s: CapturedFrameSample) -> Float {
        return 0.5 * s.sharpness - 0.3 * s.motionScore * 1000
    }

    /// C 架构的核心筛选器:从已激活(.ok/.excellent)的 cell 里挑 targetTotal 帧,
    /// 分桶均衡,用 (sharpness + motion) 质量分在 cell 内排序。
    ///
    /// 算法(精确跑满 targetTotal,不丢余数):
    ///   1. 每个非空 cell 内按 quality 排序
    ///   2. baseK = targetTotal / cellCount,remainder = targetTotal - baseK*cellCount
    ///   3. 按"每 cell 最好那帧的 quality"把 cell 排序
    ///   4. 前 remainder 个 cell 分 baseK+1 帧,剩下的分 baseK 帧
    ///   5. 如果某 cell 内的候选帧 < 分配数,只能取它所有的(允许总数 < targetTotal)
    ///
    /// 返回的 [CuratedFrame] 已按 cell 质量降序,用户/Recorder 可直接上传。
    /// 服务器收到这份清单后不再做 az×el,直接按 frameID 提帧喂 VGGT。
    func curateForUpload(targetTotal: Int = 80) -> [CuratedFrame] {
        // Step 1: 收集所有非空 cell,cell 内按 quality 排序。
        // 接受 .weak / .ok / .excellent —— 只过滤 .empty。理由:即便 cell 只有 2 帧
        // (.weak),那 2 帧也是经过 sharpness 硬过滤后的有效帧,有总比没有强。
        // 如果 curateForUpload 返回空,iOS 端会静默跳过 C 路径退化为老 az×el,
        // 用户感知就是"明明拍了一堆,服务器还是出烂质量"。
        struct CellGroup {
            let azBin: Int
            let elBin: Int
            let state: DomeCellState
            let ranked: [(sample: CapturedFrameSample, score: Float)]
            var bestScore: Float { ranked.first?.score ?? -.greatestFiniteMagnitude }
        }
        var groups: [CellGroup] = []
        for a in 0..<DomeCellIndex.azimuthCount {
            for e in 0..<DomeCellIndex.elevationCount {
                let st = cells[a][e].state(using: thresholds)
                guard st != .empty else { continue }   // 只过滤完全空的 cell
                let samples = cells[a][e].samplesSnapshot
                guard !samples.isEmpty else { continue }
                let ranked = samples
                    .map { (sample: $0, score: qualityScore($0)) }
                    .sorted { $0.score > $1.score }
                groups.append(CellGroup(azBin: a, elBin: e, state: st, ranked: ranked))
            }
        }
        guard !groups.isEmpty, targetTotal > 0 else { return [] }

        // Step 2: baseK + remainder
        let n = groups.count
        let baseK = targetTotal / n
        let remainder = targetTotal - n * baseK

        // Step 3: 按"cell 最好帧的 quality"排序,前 remainder 个 cell 多拿 1
        let ordered = groups.sorted { $0.bestScore > $1.bestScore }

        // Step 4: 展开
        var out: [CuratedFrame] = []
        out.reserveCapacity(targetTotal)
        for (rank, group) in ordered.enumerated() {
            let k = baseK + (rank < remainder ? 1 : 0)
            let take = min(k, group.ranked.count)
            for i in 0..<take {
                let (s, score) = group.ranked[i]
                out.append(CuratedFrame(
                    sample: s,
                    azBin: group.azBin,
                    elBin: group.elBin,
                    cellState: group.state,
                    qualityScore: score,
                    cellRankInTopK: i
                ))
            }
        }
        return out
    }

    private func emitAggregate() {
        let c = cellCounts()
        onAggregateChanged?(validFrameCount, c.excellent, c.ok)
    }
}

// MARK: - Ring buffer cell

/// 固定容量缓冲 —— 满后用"多样性保留"驱逐策略,**不是 FIFO**。
///
/// Why:cell 30°×30° 内,如果用户停留过久,FIFO 会把"绕过来时拍到的多样视角"
/// 全挤光,只剩"原地不动"的冗余帧 → state 重算时 azSpread/timeSpread 不达标
/// → 已 excellent cell 莫名退色 → 用户怀疑"是不是漏拍了?"。
///
/// 新策略:每来一帧,先看 buffer 满没满。
///   - 没满 → 直接 append。
///   - 满了 → 算 buffer 里"最冗余"那帧(和别的帧距离最近的);算新帧的"新颖度"
///     (和 buffer 所有帧的最近距离)。
///       - 新帧更新颖 → 替换最冗余那帧。
///       - 新帧同等新颖但质量更高 → 替换。
///       - 否则 → **拒收新帧**(不污染 buffer)。
///
/// 距离 = (Δaz_deg)² + (Δel_deg)² + (Δt_sec × 10)²,1 秒 ≈ 10° 等价权重。
/// O(N²) per append,N=8 → ~64 次浮点 ≈ 1μs,可忽略。
///
/// 副作用:curateForUpload(80) 从 buffer 挑 top-K 时,拿到的天然就是 8 个多样帧,
/// 不是 8 个停留帧 → 上传给服务器的素材直接受益。
private struct RingBufferCell {
    let capacity: Int
    private var buf: [CapturedFrameSample] = []
    /// 单调状态高水位:state() 一旦达到 .ok / .excellent 就锁住,即使后续 buffer
    /// 内容(因新帧拉低 medSharp 或拉高 maxMotion)算出更低的状态,对外仍报高水位。
    /// 修法 B(多样性驱逐)防 FIFO 抹掉好帧,但**没法阻止"新加进来的烂帧拉低 aggregate 指标"**;
    /// 高水位是这一层的兜底:用户曾经做到过 → 数据已留在 buffer/上传,显示就不该退色。
    private var highWaterState: DomeCellState = .empty

    init(capacity: Int) {
        self.capacity = max(4, capacity)
        self.buf.reserveCapacity(self.capacity)
    }

    var frameIDs: [UUID] { buf.map(\.frameID) }

    /// 只读快照供 curateForUpload 排序/挑选使用。
    var samplesSnapshot: [CapturedFrameSample] { buf }

    mutating func append(_ s: CapturedFrameSample) {
        if buf.count < capacity {
            buf.append(s)
            return
        }
        // 满了,做多样性保留驱逐
        var worstIdx = 0
        var worstNovelty = Float.greatestFiniteMagnitude
        for i in buf.indices {
            let novelty = Self.minDistance(of: buf[i], to: buf, excluding: i)
            if novelty < worstNovelty {
                worstNovelty = novelty
                worstIdx = i
            }
        }
        let newNovelty = Self.minDistance(of: s, to: buf, excluding: nil)
        let worstQuality = Self.qualityOf(buf[worstIdx])
        let newQuality = Self.qualityOf(s)

        // 主判:新帧明显更新颖 → 替换。
        // 副判:新颖度接近(差 < 1° 等价距离)但质量更高 → 替换(去重保最清晰那张)。
        // 否则:新帧冗余且不更好 → 丢弃,buffer 保留原状。
        let shouldReplace = newNovelty > worstNovelty + 0.001
            || (abs(newNovelty - worstNovelty) <= 1.0 && newQuality > worstQuality)
        if shouldReplace {
            buf[worstIdx] = s
        }
    }

    mutating func clear() {
        buf.removeAll(keepingCapacity: true)
        highWaterState = .empty
    }

    /// 调用方算完 state 后调一下,把高水位推到这次的最高。
    mutating func bumpHighWater(to newState: DomeCellState) {
        if newState.rawValue > highWaterState.rawValue {
            highWaterState = newState
        }
    }

    /// 当前外部可见的 state = max(从 buffer 重算的, 历史高水位)。
    /// 只升不降:用户曾经触达 .excellent → 永远显示 .excellent,不被新一帧的烂数据踩回去。
    var displayedState: DomeCellState { highWaterState }

    // MARK: - 距离 + 质量(static helpers,不依赖 self,方便单测)

    private static func qualityOf(_ s: CapturedFrameSample) -> Float {
        return 0.5 * s.sharpness - 0.3 * s.motionScore * 1000
    }

    /// 两帧之间的"分布距离":(Δaz_deg)² + (Δel_deg)² + (Δt_sec × 10)²,然后开方。
    /// 1 秒时间差等价于 10° 角度差(经验权重,让"绕过来花了 1.5s"和"挪了 15°"在距离上接近)。
    private static func sampleDistance(_ a: CapturedFrameSample, _ b: CapturedFrameSample) -> Float {
        // az 用差的绝对值,因为同一 cell 内 az 至多差 30°,不会跨 ±π 翻卷
        let dAz = abs(a.azimuth - b.azimuth) * 180 / .pi
        let dEl = abs(a.elevation - b.elevation) * 180 / .pi
        let dT = Float(abs(a.timestamp - b.timestamp)) * 10
        return (dAz * dAz + dEl * dEl + dT * dT).squareRoot()
    }

    /// 从 frame s 到 buffer 中所有帧(排除 excluding 索引)的最小距离。
    /// 这个值越小 = s 越冗余;越大 = s 越独特/新颖。
    private static func minDistance(of s: CapturedFrameSample, to buf: [CapturedFrameSample], excluding: Int?) -> Float {
        var m = Float.greatestFiniteMagnitude
        for (i, other) in buf.enumerated() {
            if i == excluding { continue }
            let d = sampleDistance(s, other)
            if d < m { m = d }
        }
        // 如果 buf 只有 s 自己(excluding 把全部排除了),返回大值表示"无可比较 → 视为最新颖"
        return m == .greatestFiniteMagnitude ? 0 : m
    }

    /// 对外可见的 state:max(从 buffer 重算的, 历史高水位),保证单调不退色。
    /// 调用方应 append → state(using:) 一次读出当前;读取本身不更新高水位,
    /// DomeCoverageMap.ingest 会显式 bumpHighWater 保证下次查询稳定。
    func state(using t: DomeThresholds) -> DomeCellState {
        let computed = computeRawState(using: t)
        return computed.rawValue >= highWaterState.rawValue ? computed : highWaterState
    }

    /// 直接从当前 buffer 重算 state,不掺杂高水位 —— 用来 update 高水位本身。
    func computeRawState(using t: DomeThresholds) -> DomeCellState {
        let valid = buf
        if valid.isEmpty { return .empty }
        if valid.count <= 2 { return .weak }
        if valid.count >= t.excellentMinFrames {
            let azs = valid.map { $0.azimuth * 180 / .pi }
            let minAz = azs.min() ?? 0
            let maxAz = azs.max() ?? 0
            var azSpread = maxAz - minAz
            if azSpread > 180 { azSpread = 360 - azSpread }
            let timeSpread = Float(valid.last!.timestamp - valid.first!.timestamp)
            let sortedSharp = valid.map(\.sharpness).sorted()
            let medSharp = sortedSharp[sortedSharp.count / 2]
            let maxMotion = valid.map(\.motionScore).max() ?? 1.0
            if azSpread >= t.excellentMinAzSpreadDeg
                && timeSpread >= t.excellentMinTimeSpreadSec
                && medSharp >= t.excellentMinSharpnessMedian
                && maxMotion <= t.excellentMaxMotion {
                return .excellent
            }
        }
        return .ok
    }
}

// MARK: - C 架构上传契约 v1
//
// 文件名:curated.json,和 .mov 一起上传到服务器。
// 服务器解析本文件后:
//   1. 对 `frames` 里每个条目,按 video_timestamp_sec 从 .mov 抽帧到 curated/{00000..00079}.jpg
//   2. 跳过服务器端 az × el 重新分桶(信任客户端)
//   3. 直接喂给 VGGT → 2DGS → MAtCha 管线
//
// Schema 版本化:任何新增字段都 additive,不改既有字段语义。
// 服务器解析时用 "client_curated_v1" 识别该 contract;其他 contract(如 object_publish_v1)
// 走老的 time-uniform fallback。

let CURATED_CONTRACT_VERSION = "client_curated_v1"

/// 上传清单的根对象。
struct CuratedUploadManifest: Codable, Sendable {
    let contractVersion: String         // = CURATED_CONTRACT_VERSION
    let jobId: String                   // 客户端生成的 UUID
    let captureStartEpochMs: Int64      // 录制开始时间(Unix ms)
    let captureEndEpochMs: Int64        // 录制结束时间
    let videoAssetFilename: String      // = "capture.mov"(和 .mov 文件名一致)
    let videoDurationSec: Double
    let videoSize: VideoSize
    let arkit: ARKitContext
    let domeSpec: DomeSpec
    let curationStats: CurationStats
    let frames: [CuratedFrameEntry]     // 已由 curateForUpload 挑好的 ≤ targetTotal 帧

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case jobId = "job_id"
        case captureStartEpochMs = "capture_start_epoch_ms"
        case captureEndEpochMs = "capture_end_epoch_ms"
        case videoAssetFilename = "video_asset_filename"
        case videoDurationSec = "video_duration_sec"
        case videoSize = "video_size"
        case arkit
        case domeSpec = "dome_spec"
        case curationStats = "curation_stats"
        case frames
    }
}

struct VideoSize: Codable, Sendable {
    let width: Int
    let height: Int
}

/// 拍摄时的世界参考系信息 —— 服务器用来做 gravity-aligned 后处理。
struct ARKitContext: Codable, Sendable {
    let worldOrigin: [Float]           // 物体中心(3 个 float)
    let worldYawRad: Float             // 锁定瞬间的相机水平朝向基准
    let gravityWorld: [Float]          // 重力方向在世界系中的向量(3 个 float)
    let trackingStateAtLock: String    // "normal" / "limited" / "notAvailable"

    enum CodingKeys: String, CodingKey {
        case worldOrigin = "world_origin"
        case worldYawRad = "world_yaw_rad"
        case gravityWorld = "gravity_world"
        case trackingStateAtLock = "tracking_state_at_lock"
    }
}

/// dome 分桶定义 —— 客户端和服务器必须用同一套定义才能 debug 对齐。
struct DomeSpec: Codable, Sendable {
    let azimuthBins: Int                // = 12
    let elevationBins: Int              // = 5
    let elevationEdgesDeg: [Float]      // = [-75, -45, -15, 15, 45, 75]
    let maxFramesPerCell: Int           // = 8
    let qualityScoreFormula: String     // = "0.5*sharpness - 0.3*motion*1000"

    enum CodingKeys: String, CodingKey {
        case azimuthBins = "azimuth_bins"
        case elevationBins = "elevation_bins"
        case elevationEdgesDeg = "elevation_edges_deg"
        case maxFramesPerCell = "max_frames_per_cell"
        case qualityScoreFormula = "quality_score_formula"
    }
}

/// curate 过程的统计(debug + 服务器日志用)。
struct CurationStats: Codable, Sendable {
    let targetTotal: Int                // 目标帧数(80)
    let actualTotal: Int                // 实际挑出帧数(可能 < target 如果候选不够)
    let filledCellCount: Int            // .ok + .excellent cell 数
    let excellentCellCount: Int         // 仅 .excellent
    let okCellCount: Int                // 仅 .ok
    let baseK: Int                      // targetTotal / filledCellCount
    let remainderCellsGotBonus: Int     // 前 remainder 个 cell 分到 baseK+1
    let totalCandidateFrameCount: Int   // 所有已过滤过 sharpness 的候选帧总数

    enum CodingKeys: String, CodingKey {
        case targetTotal = "target_total"
        case actualTotal = "actual_total"
        case filledCellCount = "filled_cell_count"
        case excellentCellCount = "excellent_cell_count"
        case okCellCount = "ok_cell_count"
        case baseK = "base_k"
        case remainderCellsGotBonus = "remainder_cells_got_bonus"
        case totalCandidateFrameCount = "total_candidate_frame_count"
    }
}

/// 单帧条目。服务器按 video_timestamp_sec 从 .mov 抽帧,按 frame_uuid 和 Recorder 的
/// 本地 manifest 做索引对应(如果之后我们也把 manifest.json 上传)。
struct CuratedFrameEntry: Codable, Sendable {
    let frameUuid: String                // CapturedFrameSample.frameID.uuidString
    let videoTimestampSec: Double        // .mov 中的时间戳(-ss 参数可直接用)
    let captureEpochMs: Int64            // Unix ms(debug 用)
    let azBin: Int                       // 0..11
    let elBin: Int                       // 0..4
    let azRad: Float                     // 相对 worldYaw
    let elRad: Float                     // 绝对仰角
    let sharpness: Float                 // Laplacian variance
    let motionScore: Float               // [0,1]
    let qualityScore: Float              // 客户端计算的排序分
    let cellState: String                // "ok" | "excellent"
    let cellRankInTopK: Int              // 0 = cell 内最好
    let arkitExtrinsic4x4: [Float]?      // 16 floats(可选,来自 Recorder manifest.json)
    let arkitIntrinsicFxFyCxCy: [Float]? // 4 floats(可选)

    enum CodingKeys: String, CodingKey {
        case frameUuid = "frame_uuid"
        case videoTimestampSec = "video_timestamp_sec"
        case captureEpochMs = "capture_epoch_ms"
        case azBin = "az_bin"
        case elBin = "el_bin"
        case azRad = "az_rad"
        case elRad = "el_rad"
        case sharpness
        case motionScore = "motion_score"
        case qualityScore = "quality_score"
        case cellState = "cell_state"
        case cellRankInTopK = "cell_rank_in_top_k"
        case arkitExtrinsic4x4 = "arkit_extrinsic_4x4"
        case arkitIntrinsicFxFyCxCy = "arkit_intrinsic_fx_fy_cx_cy"
    }
}

// MARK: - Builder:从 curateForUpload 输出拼出上传 payload

/// 传入 curateForUpload() 结果,组装完整的 CuratedUploadManifest 用于 JSON 序列化。
///
/// ARKit pose (cameraExtrinsic4x4, cameraIntrinsicFxFyCxCy)已经由 ARDomeCoordinator
/// 的 handleFrame 时写入每个 CapturedFrameSample,这里直接透传。
/// externalFeed(CoreMotion)路径下这两个字段为 nil,服务器仍能走 VGGT 自行估 pose。
enum CuratedUploadBuilder {
    static func build(
        jobId: String,
        captureStartMediaTime: TimeInterval,  // 首帧的 CACurrentMediaTime(),用来算 video_timestamp_sec
        captureStartEpochMs: Int64,
        captureEndEpochMs: Int64,
        videoAssetFilename: String,
        videoDurationSec: Double,
        videoSize: VideoSize,
        arkit: ARKitContext,
        curatedFrames: [CuratedFrame],
        totalCandidateFrameCount: Int,
        filledCellCount: Int,
        excellentCellCount: Int,
        okCellCount: Int,
        targetTotal: Int
    ) -> CuratedUploadManifest {
        let baseK = filledCellCount > 0 ? targetTotal / filledCellCount : 0
        let remainder = filledCellCount > 0 ? targetTotal - baseK * filledCellCount : 0

        let entries: [CuratedFrameEntry] = curatedFrames.map { cf in
            // sample.timestamp 是 CACurrentMediaTime(),减去首帧时间得到 .mov 内的秒偏移
            let videoTsSec = max(0, cf.sample.timestamp - captureStartMediaTime)
            return CuratedFrameEntry(
                frameUuid: cf.sample.frameID.uuidString,
                videoTimestampSec: videoTsSec,
                captureEpochMs: Int64(cf.sample.timestamp * 1000),
                azBin: cf.azBin,
                elBin: cf.elBin,
                azRad: cf.sample.azimuth,
                elRad: cf.sample.elevation,
                sharpness: cf.sample.sharpness,
                motionScore: cf.sample.motionScore,
                qualityScore: cf.qualityScore,
                cellState: {
                    switch cf.cellState {
                    case .excellent: return "excellent"
                    case .ok: return "ok"
                    case .weak: return "weak"
                    case .empty: return "empty"
                    }
                }(),
                cellRankInTopK: cf.cellRankInTopK,
                arkitExtrinsic4x4: cf.sample.cameraExtrinsic4x4,
                arkitIntrinsicFxFyCxCy: cf.sample.cameraIntrinsicFxFyCxCy
            )
        }

        return CuratedUploadManifest(
            contractVersion: CURATED_CONTRACT_VERSION,
            jobId: jobId,
            captureStartEpochMs: captureStartEpochMs,
            captureEndEpochMs: captureEndEpochMs,
            videoAssetFilename: videoAssetFilename,
            videoDurationSec: videoDurationSec,
            videoSize: videoSize,
            arkit: arkit,
            domeSpec: DomeSpec(
                azimuthBins: 12,
                elevationBins: 5,
                elevationEdgesDeg: [-75, -45, -15, 15, 45, 75],
                maxFramesPerCell: 8,
                qualityScoreFormula: "0.5*sharpness - 0.3*motion*1000"
            ),
            curationStats: CurationStats(
                targetTotal: targetTotal,
                actualTotal: curatedFrames.count,
                filledCellCount: filledCellCount,
                excellentCellCount: excellentCellCount,
                okCellCount: okCellCount,
                baseK: baseK,
                remainderCellsGotBonus: remainder,
                totalCandidateFrameCount: totalCandidateFrameCount
            ),
            frames: entries
        )
    }

    /// 把 Manifest 序列化成 pretty-printed JSON Data(可直接写入 curated.json 或 base64 上传)。
    static func encode(_ manifest: CuratedUploadManifest) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.keyEncodingStrategy = .useDefaultKeys   // 我们用 CodingKeys 手动映射 snake_case
        return try enc.encode(manifest)
    }
}

#endif

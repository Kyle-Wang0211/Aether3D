import Foundation

#if canImport(UIKit) && canImport(SceneKit) && canImport(simd)
import UIKit
import SceneKit
import simd

/// 屏幕空间的 3D 球形引导 UI。固定在快门位置,随相机 yaw/pitch 旋转,
/// 中心指示圈不转,显示当前 cell 状态。
///
/// 性能设计:
///   - 36 个 cell node + 4 种共享 material,每帧只改 material 指针,不分配。
///   - dome 旋转矩阵只在 updateRotation 里 simd 运算,~200 ns/帧。
///   - SCNView 用 metal backend,antialiasing 2x(iPhone 12 以上 4x 也轻松)。
///   - 脉冲动画用 SCNAction,GPU 原生,零 CPU 每帧成本。
///
/// 用法:
///   let dome = ObjectModeV2DomeView(frame: CGRect(x: 0, y: 0, width: 90, height: 90))
///   dome.onTap = { [weak self] in self?.finishCapture() }
///   // 每帧(由 AR coordinator 驱动):
///   dome.updateRotation(targetYaw: camAz, targetPitch: camEl)
///   dome.updateCell(index, state: .excellent)
///   dome.setCenterIndicator(.excellent)
final class ObjectModeV2DomeView: UIView {

    // MARK: - Public

    var onTap: (() -> Void)?

    /// 低通滤波系数(0..1),越大越跟手越抖,首版 0.2。
    var smoothingAlpha: Float = 0.2

    /// 俯仰缩放系数:
    ///   1.0 = 精确对齐(用户当前 cell 落到 dome 中心 +Z,与 yaw 的 -π/2 offset 配合)
    ///   < 1.0 = 衰减(视觉更柔,但 cell 不落在中心,纵向会有偏移)
    /// 配合 ObjectModeV2ARDomeCoordinator 里 `targetPitch: snap.currentElevation`
    /// 的正号,只有 pitchScale=1.0 时 cell 会精确居中。
    var pitchScale: Float = 1.0

    // MARK: - Private state

    private let scnView = SCNView()
    private let scene = SCNScene()
    private let domeContainer = SCNNode()    // 旋转的部分
    private let centerIndicator = CAShapeLayer()
    private let hudLabel = UILabel()

    /// 36 个 cell mesh 的引用(索引 [az][el])。
    private var cellNodes: [[SCNNode]] = []

    /// 4 种预分配的共享 material(避免每帧新建)。
    private var sharedMaterials: [DomeCellState: SCNMaterial] = [:]

    /// 平滑后的旋转角度(单位 rad)。
    private var smoothYaw: Float = 0
    private var smoothPitch: Float = 0

    /// 首次调用 updateRotation 时直接 snap 到目标,不走 lerp 动画,
    /// 避免锁定瞬间出现"从默认 0 角度动画到正确角度"的误导性视觉(例如
    /// 用户面对物体看到球形 UI 从 3 点钟扫到 6 点钟的"彩蛋")。
    private var hasSnappedInitial: Bool = false

    /// 是否 tracking 失效 → 冻结旋转。
    private var isTrackingFrozen: Bool = false

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false  // tap 走 SwiftUI 层

        setupScene()
        // centerIndicator 删掉 —— 中间黄/绿点对用户无意义,移除减少视觉噪音
        setupHUD()
        buildCells()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scnView.frame = bounds
        let cx = bounds.midX, cy = bounds.midY
        centerIndicator.frame = bounds
        let r: CGFloat = 7
        let ring = UIBezierPath(arcCenter: CGPoint(x: cx, y: cy), radius: r,
                                startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        centerIndicator.path = ring.cgPath

        // HUD label 在 dome 顶上方
        hudLabel.frame = CGRect(x: 0, y: -18, width: bounds.width, height: 14)
    }

    // MARK: - Scene setup

    private func setupScene() {
        scnView.scene = scene
        scnView.backgroundColor = .clear
        scnView.isOpaque = false
        scnView.antialiasingMode = .multisampling2X
        scnView.rendersContinuously = true
        scnView.allowsCameraControl = false
        scnView.preferredFramesPerSecond = 30
        // tap 事件透过 SCNView 到外层 DomeView(handleTap 接收)——
        // 否则 SCNView 自己吞掉 tap,用户点球无法触发 onTap 结束录制。
        scnView.isUserInteractionEnabled = false
        addSubview(scnView)

        // Camera — FOV 60° + z=2.5,正对球心,严格同心(不加 pitch offset)
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera?.fieldOfView = 60
        camNode.position = SCNVector3(0, 0, 2.5)
        scene.rootNode.addChildNode(camNode)

        // 柔和从上方补光(让 dome 面可见)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .omni
        light.light?.color = UIColor.white
        light.light?.intensity = 900
        light.position = SCNVector3(0, 3, 3)
        scene.rootNode.addChildNode(light)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)

        scene.rootNode.addChildNode(domeContainer)

        // 预分配 4 种共享 material
        for s in [DomeCellState.empty, .weak, .ok, .excellent] {
            let m = SCNMaterial()
            m.diffuse.contents = s.uiColor
            m.lightingModel = .constant       // 无光照计算,色板纯粹 = 一致性好
            m.isDoubleSided = true
            m.writesToDepthBuffer = false     // 避免 dome 自遮挡闪烁
            sharedMaterials[s] = m
        }
    }

    private func setupCenterIndicator() {
        centerIndicator.fillColor = UIColor.clear.cgColor
        centerIndicator.strokeColor = UIColor.white.cgColor
        centerIndicator.lineWidth = 1.6
        layer.addSublayer(centerIndicator)
    }

    private func setupHUD() {
        hudLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        hudLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        hudLabel.textAlignment = .center
        addSubview(hudLabel)
    }

    private func setupGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    /// 生成 12 × 3 个 cell mesh,每个是 dome 表面的一个梯形。
    /// 几何只建一次,之后不 reallocate。
    private func buildCells() {
        cellNodes.removeAll()
        let R: Float = 1.0            // dome 半径
        let azStep: Float = 2 * .pi / Float(DomeCellIndex.azimuthCount)
        // 整球 5 档,每档 30°,覆盖 ±75° elevation,共 12×5=60 cell。
        // 覆盖所有场景(地面物体用上 3 档,海报用中 3 档,天花板灯用下 2 档)。
        // 和 ObjectModeV2CoverageMap.swift 的 elBin 边界严格对齐。
        let elBounds: [(Float, Float)] = [
            (-75 * .pi / 180, -45 * .pi / 180),  // very low  (0) 天花板灯
            (-45 * .pi / 180, -15 * .pi / 180),  // low       (1) 高处海报
            (-15 * .pi / 180,  15 * .pi / 180),  // equator   (2) 平拍
            ( 15 * .pi / 180,  45 * .pi / 180),  // high      (3) 地面物体
            ( 45 * .pi / 180,  75 * .pi / 180),  // very high (4) 俯冲特写
        ]

        for az in 0..<DomeCellIndex.azimuthCount {
            var row: [SCNNode] = []
            let a0 = Float(az) * azStep
            let a1 = a0 + azStep

            for el in 0..<DomeCellIndex.elevationCount {
                let (e0, e1) = elBounds[el]
                let geom = makeDomeQuad(R: R, a0: a0, a1: a1, e0: e0, e1: e1)
                geom.firstMaterial = sharedMaterials[.empty]
                let node = SCNNode(geometry: geom)
                domeContainer.addChildNode(node)
                row.append(node)
            }
            cellNodes.append(row)
        }

        // 小赤道参考线(半透明灰)让 dome 更有立体感
        let equator = SCNTorus(ringRadius: CGFloat(R * 0.995), pipeRadius: 0.004)
        let eqMat = SCNMaterial()
        eqMat.diffuse.contents = UIColor(white: 1, alpha: 0.25)
        eqMat.lightingModel = .constant
        equator.firstMaterial = eqMat
        let eqNode = SCNNode(geometry: equator)
        eqNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)  // 水平放
        domeContainer.addChildNode(eqNode)
    }

    /// 生成一片梯形 mesh(4 顶点 + 2 三角形)。
    /// 共用顶点公式球面坐标 (azimuth, elevation) → (x, y, z)。
    private func makeDomeQuad(R: Float, a0: Float, a1: Float, e0: Float, e1: Float) -> SCNGeometry {
        func pt(_ a: Float, _ e: Float) -> SCNVector3 {
            SCNVector3(
                R * cos(e) * cos(a),
                R * sin(e),
                R * cos(e) * sin(a)
            )
        }
        let v0 = pt(a0, e0)
        let v1 = pt(a1, e0)
        let v2 = pt(a1, e1)
        let v3 = pt(a0, e1)

        let source = SCNGeometrySource(vertices: [v0, v1, v2, v3])
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        return SCNGeometry(sources: [source], elements: [element])
    }

    // MARK: - Public update APIs

    /// 每帧调用,喂当前相机相对物体中心的 azimuth / elevation(rad)。
    func updateRotation(targetYaw: Float, targetPitch: Float) {
        guard !isTrackingFrozen else { return }
        let scaledPitch = targetPitch * pitchScale
        if !hasSnappedInitial {
            // 锁定后第一次:直接 snap,不 lerp,避免"从 0 动画到正确位置"被用户看见
            smoothYaw = targetYaw
            smoothPitch = scaledPitch
            hasSnappedInitial = true
        } else {
            // 后续跟手滑动:低通滤波跟随相机方向
            smoothYaw   = lerpAngle(smoothYaw,   targetYaw,    alpha: smoothingAlpha)
            smoothPitch = lerp     (smoothPitch, scaledPitch,  alpha: smoothingAlpha)
        }

        // ⚠️ 不用 eulerAngles —— SceneKit 默认是内旋(intrinsic) ZYX/XYZ 顺序,
        // yaw 已改变本地 X 轴朝向后,pitch 会绕旋转后的 X(= 世界 -Z)做旋转,
        // 视觉上表现为 ROLL(用户竖直移动手机 → dome 侧倾),不是真正的 pitch。
        // 用 quaternion 显式组合:先绕世界 Y 做 yaw,再绕世界 X 做 pitch(外旋)。
        // simd_quatf 乘法:q_a * q_b 表示"先应用 q_b,再应用 q_a"。
        let yawQ   = simd_quatf(angle: smoothYaw,   axis: SIMD3<Float>(0, 1, 0))
        let pitchQ = simd_quatf(angle: smoothPitch, axis: SIMD3<Float>(1, 0, 0))
        domeContainer.simdOrientation = pitchQ * yawQ
    }

    /// 重置 lerp 平滑,下一次 updateRotation 会直接 snap 到目标值。
    /// 调用时机:用户重新锁定物体中心(切换 lock 路径或重启录制)。
    func resetRotationSmoothing() {
        hasSnappedInitial = false
    }

    func setTrackingFrozen(_ frozen: Bool) {
        isTrackingFrozen = frozen
        alpha = frozen ? 0.4 : 1.0
    }

    /// 更新某个 cell 状态 —— 指针换 material,零分配。
    func updateCell(_ index: DomeCellIndex, state: DomeCellState) {
        guard index.az < cellNodes.count, index.el < cellNodes[index.az].count else { return }
        let node = cellNodes[index.az][index.el]
        node.geometry?.firstMaterial = sharedMaterials[state]

        if state == .excellent {
            // 一次性脉冲动画(scale 1 → 1.08 → 1),完成后自动移除。
            let grow = SCNAction.scale(to: 1.08, duration: 0.12)
            let shrink = SCNAction.scale(to: 1.0, duration: 0.18)
            node.removeAllActions()
            node.runAction(SCNAction.sequence([grow, shrink]))
        }
    }

    /// 中心指示圈颜色(= 当前 cell 状态)。
    func setCenterIndicator(_ state: DomeCellState) {
        switch state {
        case .empty:
            centerIndicator.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
            centerIndicator.fillColor = UIColor.clear.cgColor
        case .weak, .ok, .excellent:
            centerIndicator.strokeColor = UIColor.white.cgColor
            centerIndicator.fillColor = state.uiColor.cgColor
        }
    }

    /// dome 顶部 HUD label ("30 帧 · 6 深绿")
    func setHUD(_ text: String) {
        hudLabel.text = text
    }

    // MARK: - Helpers

    @objc private func handleTap() { onTap?() }

    private func lerp(_ a: Float, _ b: Float, alpha: Float) -> Float {
        a + (b - a) * alpha
    }

    private func lerpAngle(_ a: Float, _ b: Float, alpha: Float) -> Float {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d >  .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return a + d * alpha
    }
}

#endif

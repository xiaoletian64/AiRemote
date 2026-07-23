import Foundation
import CoreBluetooth
import AVFoundation
import CoreAudio
import CoreGraphics
import ApplicationServices
import IOKit.hid
import Combine
import AppKit
import ServiceManagement

// ============ ADPCM (IMA, low-nibble-first, 16 kHz mono) ============
struct ADPCM {
    static let step: [Int32] = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    static let idxT: [Int32] = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]
    var pred: Int32 = 0, idx: Int32 = 0
    mutating func reset() { pred = 0; idx = 0 }
    mutating func nib(_ n: UInt8) -> Float {
        let s = ADPCM.step[Int(idx)]; var d = s >> 3
        if n & 4 != 0 { d += s }; if n & 2 != 0 { d += s >> 1 }; if n & 1 != 0 { d += s >> 2 }
        pred += (n & 8 != 0) ? -d : d; pred = max(-32768, min(32767, pred))
        idx += ADPCM.idxT[Int(n & 15)]; idx = max(0, min(88, idx))
        return Float(pred) / 32768.0
    }
    mutating func decode(_ data: Data) -> [Float] {
        var o = [Float](); o.reserveCapacity(data.count * 2)
        for b in data { o.append(nib(b & 15)); o.append(nib((b >> 4) & 15)) }
        return o
    }
}

// ============ 语音增强 DSP（16 kHz）：高通 → 人声EQ → 噪声门 → AGC → 软限幅 ============
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    mutating func reset() { z1 = 0; z2 = 0 }
    mutating func run(_ x: Float) -> Float {
        let y = b0*x + z1
        z1 = b1*x - a1*y + z2
        z2 = b2*x - a2*y
        return y
    }
    static func highpass(f0: Float, fs: Float, q: Float) -> Biquad {
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1+al
        var b = Biquad()
        b.b0 = (1+cw)/2/a0; b.b1 = -(1+cw)/a0; b.b2 = (1+cw)/2/a0
        b.a1 = -2*cw/a0; b.a2 = (1-al)/a0
        return b
    }
    static func peaking(f0: Float, fs: Float, q: Float, dbGain: Float) -> Biquad {
        let A = pow(10, dbGain/40)
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1 + al/A
        var b = Biquad()
        b.b0 = (1 + al*A)/a0; b.b1 = -2*cw/a0; b.b2 = (1 - al*A)/a0
        b.a1 = -2*cw/a0; b.a2 = (1 - al/A)/a0
        return b
    }
    static func lowshelf(f0: Float, fs: Float, q: Float, dbGain: Float) -> Biquad {
        let A = pow(10, dbGain/40)
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1 + al/A
        var b = Biquad()
        b.b0 = (1 + al*A)/a0; b.b1 = -2*cw/a0; b.b2 = (1 - al*A)/a0
        b.a1 = -2*cw/a0; b.a2 = (1 - al/A)/a0
        return b
    }
    static func highshelf(f0: Float, fs: Float, q: Float, dbGain: Float) -> Biquad {
        // RBJ high-shelf：在高频段整体抬升/衰减，用于增加空气感
        let A = pow(10, dbGain/40)
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q)
        let a0 = (A+1) - (A-1)*cw + 2*sqrt(A)*al
        var b = Biquad()
        b.b0 = (A*((A+1) + (A-1)*cw + 2*sqrt(A)*al))/a0
        b.b1 = (-2*A*((A+1) - (A-1)*cw))/a0
        b.b2 = (A*((A+1) + (A-1)*cw - 2*sqrt(A)*al))/a0
        b.a1 = (2*((A-1) + (A+1)*cw))/a0
        b.a2 = ((A+1) + (A-1)*cw - 2*sqrt(A)*al)/a0
        return b
    }
}

struct VoiceDSP {
    // 频谱整形链：高通切低频嗡嗡 → 低shelf压200Hz → 中频提清晰度 → 高频提亮
    // 高通从 120 提到 160Hz：蓝牙遥控器 + 室内环境低频噪声多在 80-200Hz，切更狠识别更干净。
    var hp = Biquad.highpass(f0: 160, fs: 16000, q: 0.7)     // 滤低频噪声（切更狠）
    var ls = Biquad.lowshelf(f0: 220, fs: 16000, q: 0.5, dbGain: -6)  // 压 200Hz 嗡嗡声（加深）
    // 语音清晰度关键频段是 1-4kHz（辅音辨别，决定识别率）。原来只 2500Hz 单点 +3dB 不够，
    // 改为两点：1500Hz 轻提（鼻音/元音饱满）+ 3000Hz 多提（辅音清晰）。
    var eq1 = Biquad.peaking(f0: 1500, fs: 16000, q: 1.2, dbGain: 2)   // 中频饱满
    var eq2 = Biquad.peaking(f0: 3000, fs: 16000, q: 1.0, dbGain: 4)   // 辅音清晰（提亮加强）
    var hs = Biquad.highshelf(f0: 4000, fs: 16000, q: 0.7, dbGain: 3)  // 高频空气感
    var env: Float = 0
    var gate: Float = 0
    var gain: Float = 4
    var noiseFloor: Float = 0.0025
    var noiseMin: Float = 1.0
    var dcOffset: Float = 0   // 直流偏移估计（ADPCM 解码可能残留，拉低 SNR 估计准确度）
    // 宽频稳态噪声估计（谱减的简化版）：用短时能量跟踪背景噪声，语音活动时缓慢上推，
    // 静音时快速下压。比原来的单 noiseFloor 更能压风扇/电流声这类全程噪声。
    var noiseEst: Float = 0.002
    mutating func reset() {
        hp.reset(); ls.reset(); eq1.reset(); eq2.reset(); hs.reset()
        env = 0; gate = 0; noiseFloor = 0.0025; noiseMin = 1.0; dcOffset = 0; noiseEst = 0.002
    }
    mutating func process(_ xs: [Float]) -> [Float] {
        var out = [Float](); out.reserveCapacity(xs.count)
        for x0 in xs {
            // 1) 去直流偏移（一阶高通的极低频等效，不影响语音）
            dcOffset += (x0 - dcOffset) * 0.001
            var x = x0 - dcOffset
            // 2) 频谱整形链
            x = hs.run(eq2.run(eq1.run(ls.run(hp.run(x)))))
            let ax = abs(x)
            env = max(ax, env * 0.999)
            noiseMin = min(noiseMin, ax + 1e-6)
            // 3) 宽频噪声估计：静音段快速学习，语音段缓慢遗忘
            if ax < noiseFloor * 2 {
                noiseEst += (ax - noiseEst) * 0.02   // 静音：快速逼近真实背景
            } else {
                noiseEst += (noiseEst - ax) * 0.0001 * 0   // 语音段：保持（不减）
                noiseEst = max(noiseEst, ax * 0.15)         // 但不让它被瞬时尖峰拉太高
            }
            noiseEst = max(0.0003, min(0.02, noiseEst))
            if ax < noiseFloor * 2 {
                noiseFloor += (noiseMin - noiseFloor) * 0.001
            } else if env < noiseFloor * 4 {
                noiseFloor += (0.0025 - noiseFloor) * 0.0001
            }
            noiseFloor = max(0.0003, min(0.008, noiseFloor))
            noiseMin = min(noiseMin + 0.00001, 1.0)
            // 4) 宽频谱减：从信号里减去估计的噪声能量（过减则限幅，避免音乐噪声）
            if ax > noiseEst * 1.5 {
                let overSub: Float = 1.5   // 过减系数，压更多噪声
                let reduced = sqrt(max(0, ax * ax - (noiseEst * overSub) * (noiseEst * overSub)))
                x *= reduced / max(ax, 1e-6)
            } else {
                x *= 0.1   // 纯噪声段大幅衰减
            }
            // 5) 噪声门。开启快（0.05，话头不丢），关闭慢（0.0008，句尾弱音不被门切断）。
            // 之前关闭用 0.002 太快，会把"最后两个字"的尾音压没——这是吞尾字的主因之一。
            let snr = env / max(noiseFloor, 1e-6)
            let gateOpen: Float
            if snr > 3.0 { gateOpen = 1.0 }
            else if snr < 1.5 { gateOpen = 0.02 }
            else { gateOpen = (snr - 1.5) / 1.5 * 0.98 + 0.02 }
            let rate: Float = gateOpen > gate ? 0.05 : 0.0008
            gate += (gateOpen - gate) * rate
            x *= gate
            // 6) AGC（响应加快，避免句尾小音量词被压）
            if env > noiseFloor * 3 {
                let desired = min(24, max(1, 0.3 / max(env, 1e-4)))
                gain += (desired - gain) * 0.003   // 从 0.001 提到 0.003，跟得上句内起伏
            }
            out.append(tanh(x * gain))
        }
        return out
    }
}

// ============ ring buffer feeding BlackHole ============
final class Ring {
    private var buf: [Float]; private var r = 0, w = 0, cnt = 0
    private let lock = NSLock(); let cap: Int
    init(_ c: Int) { cap = c; buf = [Float](repeating: 0, count: c) }
    func push(_ s: [Float]) { lock.lock(); defer { lock.unlock() }
        for v in s { buf[w] = v; w = (w+1)%cap; if cnt < cap { cnt += 1 } else { r = (r+1)%cap } } }
    func pop(_ p: UnsafeMutablePointer<Float>, _ n: Int) { lock.lock(); defer { lock.unlock() }
        var i = 0; while i < n && cnt > 0 { p[i] = buf[r]; r = (r+1)%cap; cnt -= 1; i += 1 }
        while i < n { p[i] = 0; i += 1 } }
}

// magic marker so our own synthetic CGEvents are ignored by our tap
let kSyntheticMarker: Int64 = 0x4D49_5245  // "MIRE"

/// 发现到的遥控器候选项（UI 展示用，不含 CBPeripheral 本身）。
/// Identifiable 让 ForEach 直接用；id 即 peripheral.identifier，与 selectedRemoteID 对齐。
struct RemoteCandidate: Identifiable, Hashable {
    // id 设为 var：同一物理设备在不同扫描轮次里 peripheral.identifier 可能变化，
    // 按 name 合并去重时需要把 id 更新为最新句柄，保证 selectRemote 能取到有效 peripheral。
    var id: UUID
    var name: String
    var rssi: Int
    var connected: Bool   // 是否是当前活跃连接（dev）
}

@MainActor
final class Engine: ObservableObject {
    // status published to UI
    @Published var btOn = false
    @Published var remoteConnected = false
    @Published var handshakeReady = false
    @Published var blackholeFound = false
    @Published var blackholeSelectedAsInput = false
    @Published var axTrusted = false
    @Published var inputMonitoringOK = false
    @Published var micStreaming = false
    @Published var voicePacketCount = 0
    @Published var voiceBytesReceived = 0
    @Published var voiceFailure = ""
    @Published var lastButton = ""            // last raw button seen (for Learn)
    @Published var lastButtonUsage: Int = 0
    @Published var capturingUsage: Int? = nil // which button is currently recording a key (-1 = voice)
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Published var menuBarOnly = UserDefaults.standard.bool(forKey: "menuBarOnly")
    @Published var log: [String] = []
    @Published var scanning = false
    @Published var lastFoundName: String? = nil
    @Published var lastRSSI: Int = 0
    // 多遥控器：发现的候选设备列表 + 当前选中。单选语义——同时只连一台。
    // CBPeripheral 不直接进 SwiftUI，所以这里只暴露 id/name/rssi，用 id 去 discoveredPeripherals 取连接对象。
    @Published var discoveredRemotes: [RemoteCandidate] = []
    @Published var selectedRemoteID: UUID? = nil
    // 前台弹窗用：最新按键事件显示 + 触发抖动 token
    @Published var lastKeyLabel: String = "—"
    @Published var lastKeyMapping: String = ""
    @Published var lastKeyAtMs: TimeInterval = 0
    @Published var keyFlash: Int = 0

    @Published var config = ConfigStore.load()

    private let ring = Ring(16000 * 4)
    private var codec = ADPCM()
    private var dsp = VoiceDSP()
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private let voiceGlobeMapper = VoiceGlobeMapper()
    @Published var hardwareGlobeReady = false

    // BLE
    private var cm: CBCentralManager!
    private var dev: CBPeripheral?
    private var tx: CBCharacteristic?
    private var capsSent = false
    // 多候选：按 peripheral.identifier 缓存发现到的设备对象，供 selectRemote 连接使用。
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var streaming = false
    private var lastVoicePacketAt: TimeInterval = 0
    private var voiceSessionStartAt: TimeInterval = 0   // 本次语音键按下的起始时间，用于丢包统计
    private var systemSuspended = false
    // 用户主动断开标志：为 true 时 didDisconnect 不自动重连。selectRemote/retryScan/恢复时复位。
    private var userDisconnected = false
    private var reconnectGeneration = 0
    private var lastRecoveryAt: TimeInterval = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    // HID
    private var hidMgr: IOHIDManager?
    private var hidBufs: [UnsafeMutablePointer<UInt8>] = []
    private var lastHidKeycodeAt: [CGKeyCode: TimeInterval] = [:]
    private var voiceHidDown = false   // 语音键的 HID F5 正被按住（需持续吞掉）
    private var downButtonUsage: Int = 0
    // 圆盘协议学习模式：UI 开启后，记录原始 03 报告 + 时间戳，供分析顺/逆时针编码规律。
    @Published var ringLearningMode = false
    private var ringLearningBuffer: [(bytes: [UInt8], at: TimeInterval)] = []
    private var ringLearnStartAt: TimeInterval = 0
    // 圆盘校准滚动解码器：3 帧稳定同方向才发有界滚动，静置/不稳噪声自动过滤。
    private var ringDecoder = RingScrollDecoder()
    // 圆盘开关：默认关闭（防误触）。用户在 UI 开启后才解码滚动事件。
    @Published var ringEnabled: Bool = UserDefaults.standard.bool(forKey: "ringEnabled")
    // HID 诊断模式：开启时记录所有原始字节。默认关闭，避免圆盘噪声刷满日志；统计始终开启。
    @Published var hidDiagMode: Bool = false
    @Published private(set) var inputSafetySummary = "报告：按键 0 · 圆盘 0；拦截 Back 0"
    private var inputStatistics = RemoteInputStatistics()
    private var nextInputSafetySummaryAt: TimeInterval = 0
    func setHidDiagMode(_ on: Bool) { hidDiagMode = on; L(on ? "🔬 HID 诊断已开启" : "HID 诊断已关闭") }
    private func recordReport(_ kind: RemoteHIDReportKind) {
        inputStatistics.recordReport(kind)
        refreshInputSafetySummaryIfNeeded()
    }
    private func recordDisposition(_ disposition: RemoteInputDisposition, usage: UInt8) {
        inputStatistics.recordDisposition(disposition, usage: usage)
        refreshInputSafetySummaryIfNeeded(force: disposition == .blockedBack)
    }
    private func refreshInputSafetySummaryIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now >= nextInputSafetySummaryAt else { return }
        nextInputSafetySummaryAt = now + 0.5
        inputSafetySummary = inputStatistics.summary
    }
    func setRingEnabled(_ on: Bool) {
        guard ringEnabled != on else { return }
        ringEnabled = on
        UserDefaults.standard.set(on, forKey: "ringEnabled")
        if !on { ringDecoder.reset() }   // 关闭时清了解码器状态，避免下次开启残留
        L(on ? "🖲 圆盘滚动已开启" : "🖲 圆盘滚动已关闭（默认）")
    }
    // Back 短脉冲过滤：<35ms 的孤立 down→up 视为抖动，不启动删除定时器。
    private var backDownAt: TimeInterval = 0
    // value callback 状态机：当前 active 的 usage（用于 down/up 配对，学 mi-ao HIDButtonEventReducer）
    private var activeValueUsage: Int = 0
    // 速率熔断：统计导航/编辑类键（Delete/方向/回车）的触发频率。
    // 2 秒内 ≥8 次判定设备异常（Pro 静置自发特征）。触发后持续拦截，
    // 直到连续 10 秒无导航键事件才恢复（自发噪声持续不断会被一直挡住，
    // 用户回来正常低频按键，静默 10 秒后自动解除）。
    // 只统计这些键，避免误伤 Mac 键盘正常打字（字母键不计数）。
    private var navKeyTimestamps: [TimeInterval] = []
    private var circuitBreakerActive = false           // 是否处于熔断态
    private var lastNavKeyAt: TimeInterval = 0         // 最近一次导航键事件时间（熔断静默判断用）
    // 软件层休眠/唤醒状态机（TV 键唤醒）：
    // 唤醒态：正常处理所有键。每次按键续期唤醒窗口。
    // 休眠态：tap 拦截所有导航键；只有 TV 键（静置不自发，已验证）能唤醒。
    // 默认启动即唤醒（首次使用无感）；30 秒无按键自动休眠。
    @Published var remoteAwake: Bool = true
    private var awakeUntil: TimeInterval = 0           // 唤醒有效期，到期自动休眠
    private let awakeTimeout: TimeInterval = 30.0      // 30秒无按键进入休眠
    // TV 唤醒开关：开启时启用休眠/唤醒状态机；关闭时保持常唤醒（传统行为）。
    @Published var tvWakeEnabled: Bool = UserDefaults.standard.bool(forKey: "tvWakeEnabled")
    func setTvWakeEnabled(_ on: Bool) {
        tvWakeEnabled = on
        UserDefaults.standard.set(on, forKey: "tvWakeEnabled")
        if on {
            remoteAwake = false  // 开启即进入休眠，需 TV 键唤醒
            L("💤 TV 唤醒已开启：遥控器进入休眠，按 TV 键唤醒")
        } else {
            remoteAwake = true
            L("▶️ TV 唤醒已关闭：遥控器保持常唤醒")
        }
    }
    /// TV 键唤醒（由 handleHIDReport 收到 usage 0x35 时调用）
    func wakeByTVKey() {
        guard tvWakeEnabled else { return }
        remoteAwake = true
        awakeUntil = ProcessInfo.processInfo.systemUptime + awakeTimeout
        L("🔔 TV 键唤醒，30 秒内正常处理按键")
    }
    /// 续期唤醒（唤醒期内有合法按键时调用）
    private func keepAwake() {
        guard tvWakeEnabled, remoteAwake else { return }
        awakeUntil = ProcessInfo.processInfo.systemUptime + awakeTimeout
    }
    /// 检查是否该自动休眠（定时器调用）
    func checkAutoSleep() {
        guard tvWakeEnabled, remoteAwake else { return }
        if ProcessInfo.processInfo.systemUptime > awakeUntil {
            remoteAwake = false
            L("💤 30 秒无按键，遥控器进入休眠（按 TV 键唤醒）")
        }
    }
    // 全局暂停开关：开启时 tap 拦截所有导航/编辑类键（菜单栏一键，离开时用）。
    @Published var remotePaused: Bool = false
    func toggleRemotePause() {
        remotePaused.toggle()
        L(remotePaused ? "⏸ 遥控器已暂停（拦截所有按键）" : "▶️ 遥控器已恢复")
    }
    // 方向键/OK 延迟确认：按下后等 40ms 还在按才真正触发，过滤 <40ms 的抖动脉冲。
    // 抖动 release（usage=0）到来时若 pendingDirection 还未触发，取消它。
    private var pendingDirectionUsage: Int = 0
    private var pendingDirectionMapping: ButtonMapping?
    private var pendingDirectionTimer: Timer?
    private var pendingDirectionDownAt: TimeInterval = 0
    // 抖动检测：拿起遥控器/手指碰圆环时会产生密集且多变的 usage 切换（0xF1/0x28/0x51 混跳），
    // 真实按键是单一 usage 持续保持。记录近期（200ms 内）出现的不同 usage 集合，
    // 若短时间内切换 ≥3 种不同 usage，判定为抖动，忽略这批脉冲，避免误删除。
    private var recentUsages: [(usage: Int, at: TimeInterval)] = []
    private var bounceSuppressUntil: TimeInterval = 0   // 抖动抑制期，此期间忽略新的 down
    private var downTarget: ButtonMapping?
    private var longPressTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private var longPressFired = false
    private var deleteRepeatStartedAt: TimeInterval = 0
    private var lastDeleteRepeatAt: TimeInterval = 0
    private var keyMonitor: Any?
    private var localFnDown = false

    // event tap
    private var tap: CFMachPort?
    private var proxy: BTProxy!   // 强引用，避免被释放导致委托丢失
    private var btProxyRef: BTProxy?  // 额外持有，防止 weak 丢失

    private let ATVV = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private let TX = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private let RX = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private let CTL = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private let seed = [CBUUID(string:"1812"), CBUUID(string:"180F"),
                        CBUUID(string:"AB5E0001-5A21-4F05-BC7D-AF01F617B664")]

    static let logFile: FileHandle? = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/小米超级键盘", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("superkeyboard.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        return handle
    }()
    func L(_ s: String) {
        NSLog("[小米超级键盘] %@", s)
        // 持久日志加 ISO8601 时间戳（含毫秒），便于关联圆盘帧/修饰键状态/滤波判定
        let ts = Self.isoFormatter.string(from: Date())
        Engine.logFile?.write("\(ts)  \(s)\n".data(using: .utf8)!)
        log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) }
    }
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // ---------- lifecycle ----------
    private var started = false
    func start() { startIfNeeded() }
    func startIfNeeded() {
        guard !started else { return }
        started = true
        proxy = BTProxy(self)
        btProxyRef = proxy   // 额外强引用
        enforceInputSafetyMappings()
        ConfigStore.save(config)
        L("语音键映射: \(config.voice.display)")
        applyVoiceGlobeMapping()

        checkPermissions()
        L("权限状态: 辅助功能=\(axTrusted ? "已授权" : "未授权"), 输入监控=\(inputMonitoringOK ? "已授权" : "未授权")")

        // BLE 初始化
        cm = CBCentralManager(delegate: proxy, queue: nil)
        installSessionObservers()
        requestInitialPermissionsOnce()

        // HID 和音频等权限到位后再做，定时器会重试
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // 权限就绪前不做任何"报错"日志
                if AXIsProcessTrusted() && !self.axTrusted { self.axTrusted = true; self.L("✅ 辅助功能已授权") }
                let imOK = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
                if imOK && !self.inputMonitoringOK { self.inputMonitoringOK = true; self.L("✅ 输入监控已授权") }

                if self.axTrusted && self.tap == nil { self.installTap() }
                if self.inputMonitoringOK && self.hidMgr == nil { self.setupHID() }
                if self.axTrusted && self.keyMonitor == nil { self.installKeyCapture() }
                if !self.hardwareGlobeReady { self.applyVoiceGlobeMapping() }

                // 启动音频（只需一次）
                if self.srcNode == nil {
                    self.setupAudio()
                } else {
                    self.audioWatchdog()
                }
                // TV 唤醒状态机：检查是否该自动休眠（30秒无按键）
                self.checkAutoSleep()
            }
        }
    }

    /// 迁移旧配置：Home 从即时打开备忘录收紧为 3 秒长按，避免圆盘噪声误启动应用。
    private func enforceInputSafetyMappings() {
        guard let home = config.buttons.firstIndex(where: { $0.usage == 0x4A }) else { return }
        config.buttons[home].keycode = KeyNames.kNone
        config.buttons[home].longPressKeycode = KeyNames.kOpenNotes
    }

    /// TCC permission requests are deliberately made at most once for a fresh
    /// installation. Users can still revisit the Settings tab if they dismiss a
    /// system prompt, but normal launches never create repeated prompts.
    private func requestInitialPermissionsOnce() {
        let key = "hasRequestedInitialPermissions"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if !AXIsProcessTrusted() {
                _ = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                )
                self.L("📌 已发起一次辅助功能授权请求")
            }
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                self.L("📌 已发起一次输入监控授权请求")
            }
        }
    }

    func stop() {
        longPressTimer?.invalidate(); deleteRepeatTimer?.invalidate(); specialTimer?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        voiceGlobeMapper.restore()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        hardwareGlobeReady = false
        L("已恢复遥控器原始语音键映射")
    }

    /// A locked Mac can leave CoreBluetooth and CoreAudio objects alive while their
    /// underlying transport is no longer usable. Treat both a real display wake and
    /// an unlocked user session as a fresh connection generation.
    private func installSessionObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareForSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recoverAfterSessionChange(reason: "屏幕唤醒") }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recoverAfterSessionChange(reason: "解锁后恢复") }
        })
    }

    private func prepareForSleep() {
        guard !systemSuspended else { return }
        systemSuspended = true
        reconnectGeneration &+= 1
        cm?.stopScan(); scanning = false
        streaming = false; micStreaming = false; voiceHidDown = false
        longPressTimer?.invalidate(); longPressTimer = nil
        deleteRepeatTimer?.invalidate(); deleteRepeatTimer = nil
        engine.pause()
        L("🌙 系统睡眠：已暂停语音与重连任务")
    }

    private func recoverAfterSessionChange(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        // macOS may emit both screen-wake and session-active for one unlock.
        guard now - lastRecoveryAt > 1.0 else { return }
        lastRecoveryAt = now
        systemSuspended = false
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        L("☀️ \(reason)：正在恢复遥控器、音频与 Fn 映射")

        cm?.stopScan(); scanning = false
        streaming = false; micStreaming = false; voiceHidDown = false
        remoteConnected = false; handshakeReady = false; capsSent = false; tx = nil
        if let dev { cm?.cancelPeripheralConnection(dev) }
        teardownHID()
        checkBlackHole()
        if blackholeFound && !blackholeSelectedAsInput { selectBlackHoleAsSystemInput() }
        applyVoiceGlobeMapping()

        // Bluetooth and CoreAudio are commonly still settling during the first
        // second after unlock; reconnect only after that window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.reconnectGeneration == generation, !self.systemSuspended else { return }
            self.audioWatchdog(reason: "\(reason) 后恢复")
            self.setupHID()
            self.startSearching()
        }
    }

    private func applyVoiceGlobeMapping() {
        let mode = config.voiceMode
        let applied = voiceGlobeMapper.apply(mode)
        if applied != hardwareGlobeReady {
            hardwareGlobeReady = applied
            let target = mode == .leftControl ? "左 Control" : "Apple Globe/Fn"
            L(applied
                ? "✅ 语音键硬件映射已启用：F5 → \(target)"
                : "等待小米遥控器 HID 服务，以启用语音键 \(target) 映射")
        }
    }

    /// 切换语音键 HID 重映射目标（Globe / 左 Control）。重新应用设备层映射并保存配置。
    func setVoiceMode(_ mode: VoiceMode) {
        guard config.voiceMode != mode else { return }
        config.voiceMode = mode
        // 先恢复成"应用前"状态，再用新模式重写，避免旧目标残留
        voiceGlobeMapper.restore()
        hardwareGlobeReady = false
        applyVoiceGlobeMapping()
        saveConfig()
        L("语音键模式已切换为 \(mode.label)")
    }

    // ---------- 圆盘协议学习模式 ----------
    /// 开启学习：清缓冲区，开始记录原始 03 报告。UI 引导用户在圆盘各位置转动采样。
    func startRingLearning() {
        ringLearningMode = true
        ringLearningBuffer.removeAll()
        ringLearnStartAt = ProcessInfo.processInfo.systemUptime
        L("🗃 圆盘学习模式已开启，请在圆盘各位置转动采样（顺时针/逆时针各几圈）")
    }
    /// 结束学习：停止记录，分析规律并固化。当前先打印统计，后续实现自动生成判定规则。
    func stopRingLearning() {
        ringLearningMode = false
        L("🗃 圆盘学习结束，共记录 \(ringLearningBuffer.count) 个报告")
        analyzeRingLearning()
    }
    /// 分析学习缓冲区，找出顺/逆时针的编码特征。当前输出统计供确认规律。
    private func analyzeRingLearning() {
        guard !ringLearningBuffer.isEmpty else { return }
        var xSum = 0, ySum = 0, wheelSum = 0
        var xNeg = 0, yNeg = 0, wheelNeg = 0
        for r in ringLearningBuffer {
            let x = Int16(UInt16(r.bytes[2]) | UInt16(r.bytes[3]) << 8)
            let y = Int16(UInt16(r.bytes[4]) | UInt16(r.bytes[5]) << 8)
            let w = Int8(bitPattern: r.bytes[6])
            xSum += Int(x); if x < 0 { xNeg += 1 }
            ySum += Int(y); if y < 0 { yNeg += 1 }
            wheelSum += Int(w); if w < 0 { wheelNeg += 1 }
        }
        let n = ringLearningBuffer.count
        L("📊 学习分析（\(n) 报告）: X均值=\(Double(xSum)/Double(n)) 负值占比=\(Double(xNeg)/Double(n)) | Y均值=\(Double(ySum)/Double(n)) 负值=\(Double(yNeg)/Double(n)) | wheel均值=\(Double(wheelSum)/Double(n)) 负值=\(Double(wheelNeg)/Double(n))")
        // 关键判断：如果某分量有明显正负区分，说明该分量编码方向
        if Double(wheelNeg)/Double(n) > 0.3 || Double(wheelNeg)/Double(n) < 0.1 && wheelSum != 0 {
            L("→ wheel 分量疑似编码方向（正值多/负值多）")
        }
        if Double(xNeg)/Double(n) > 0.3 || (Double(xNeg)/Double(n) < 0.1 && xSum != 0) {
            L("→ X 分量疑似编码方向")
        }
        if Double(yNeg)/Double(n) > 0.3 || (Double(yNeg)/Double(n) < 0.1 && ySum != 0) {
            L("→ Y 分量疑似编码方向")
        }
    }

    // ---------- keyboard capture (record a target key) ----------
    func beginCapture(usage: Int) { capturingUsage = usage; L("请在键盘上按下要映射的键…") }
    func cancelCapture() { capturingUsage = nil }
    func clearMapping(usage: Int) {
        if usage == -1 { config.voice.keycode = KeyNames.kNone; config.voice.cmd = false; config.voice.shift = false; config.voice.opt = false; config.voice.ctrl = false; config.voice.longPressKeycode = nil }
        else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].keycode = KeyNames.kNone; config.buttons[i].cmd = false
            config.buttons[i].shift = false; config.buttons[i].opt = false; config.buttons[i].ctrl = false
            config.buttons[i].longPressKeycode = nil
        }
        saveConfig()
    }
    private var pendingCaptureMod: UInt16? = nil   // 录制中按住的修饰键（等松开或组合普通键）
    private func installKeyCapture() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self else { return ev }
            // A real keyboard Fn/Globe press means the user is about to use a
            // Mac-native voice feature. Route that feature to the built-in mic.
            // Remote voice is distinguished by the BLE/HID state and continues
            // to use BlackHole; its voiceButton handler switches it back.
            if ev.type == .flagsChanged, ev.keyCode == 0x3F {
                let down = ev.modifierFlags.contains(.function)
                if down && !self.localFnDown && !self.voiceHidDown {
                    self.localFnDown = true
                    self.selectBuiltInMicrophone()
                } else if !down {
                    self.localFnDown = false
                }
            }
            guard self.capturingUsage != nil else { return ev }
            let loneMods: Set<UInt16> = [0x36,0x37,0x38,0x3C,0x3A,0x3D,0x3B,0x3E,0x39,0x3F]
            let f = ev.modifierFlags
            if ev.type == .keyDown {
                // 普通键落下：连同当前按住的修饰键一起录成组合
                self.pendingCaptureMod = nil
                self.applyCapture(keycode: Int(ev.keyCode),
                                  cmd: f.contains(.command), shift: f.contains(.shift),
                                  opt: f.contains(.option), ctrl: f.contains(.control))
                return nil // swallow this key so it doesn't act while recording
            }
            // flagsChanged：修饰键按下先挂起，等松开时才录成"单独修饰键"，给组合留机会
            guard loneMods.contains(ev.keyCode) else { return nil }
            let active: Bool
            switch ev.keyCode {
            case 0x36,0x37: active = f.contains(.command)
            case 0x38,0x3C: active = f.contains(.shift)
            case 0x3A,0x3D: active = f.contains(.option)
            case 0x3B,0x3E: active = f.contains(.control)
            case 0x39:      active = f.contains(.capsLock)
            case 0x3F:      active = f.contains(.function)
            default:        active = false
            }
            if active { self.pendingCaptureMod = ev.keyCode; return nil }
            // 松开：只有它是最后按下的挂起修饰键才录制（含其余仍按住的修饰键 → 支持纯修饰键组合）
            guard self.pendingCaptureMod == ev.keyCode else { self.pendingCaptureMod = nil; return nil }
            self.pendingCaptureMod = nil
            var cmd = f.contains(.command), shift = f.contains(.shift), opt = f.contains(.option), ctrl = f.contains(.control)
            switch ev.keyCode {   // 自身类别也算按下（目标 App 靠 flag 识别修饰键）
            case 0x36,0x37: cmd = true
            case 0x38,0x3C: shift = true
            case 0x3A,0x3D: opt = true
            case 0x3B,0x3E: ctrl = true
            default: break
            }
            self.applyCapture(keycode: Int(ev.keyCode), cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
            return nil
        }
    }
    private func applyCapture(keycode: Int, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) {
        guard let usage = capturingUsage else { return }
        if usage == -1 {
            config.voice.keycode = keycode; config.voice.cmd = cmd; config.voice.shift = shift; config.voice.opt = opt; config.voice.ctrl = ctrl
        } else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].keycode = keycode; config.buttons[i].cmd = cmd
            config.buttons[i].shift = shift; config.buttons[i].opt = opt; config.buttons[i].ctrl = ctrl
        }
        let label = KeyNames.label(keycode: keycode, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
        L("已录制映射 → \(label)")
        capturingUsage = nil
        saveConfig()
    }

    func saveConfig() { ConfigStore.save(config); L("配置已保存") }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            L(on ? "已开启开机自启" : "已关闭开机自启")
        } catch {
            L("开机自启设置失败: \(error.localizedDescription)（App 需位于 /Applications）")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setMenuBarOnly(_ on: Bool) {
        menuBarOnly = on
        UserDefaults.standard.set(on, forKey: "menuBarOnly")
        L(on ? "已切换为仅菜单栏模式" : "已显示主窗口模式")
    }

    func checkPermissions() {
        axTrusted = AXIsProcessTrusted()
        inputMonitoringOK = (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
        checkBlackHole()
    }
    func checkBlackHole() {
        let was = blackholeFound
        let device = Self.deviceID(named: "BlackHole")
        blackholeFound = (device != nil)
        blackholeSelectedAsInput = device.map { Self.defaultInputDevice() == $0 } ?? false
        // 只在状态变化时记日志，避免刷屏
        if blackholeFound && !was {
            L("✅ BlackHole 声卡已就绪 (设备 \(device?.description ?? "?"))")
            selectBlackHoleAsSystemInput()
        }
        else if !blackholeFound && !was { L("⚠️ BlackHole 未检测到；语音不会送入系统输入") }
    }

    /// 一键安装 BlackHole 2ch 驱动（UI「安装语音驱动」按钮调用）。
    /// BlackHole 是内核态音频驱动，必须装到 /Library/Audio/Plug-Ins/HAL（系统目录），
    /// 所以需要管理员密码 + 安装后重启 Mac。这两步是 macOS 硬要求，App 无法绕过。
    ///
    /// 合规说明：BlackHole 预编译包 License 不允许第三方重分发，所以 App 不内置 pkg，
    /// 而是运行时从 Existential Audio 官方下载，并用 brew 记录的官方 sha256 校验完整性，
    /// 确保下载内容未被篡改，再调用系统 installer 安装。
    @Published var blackholeInstalling = false
    private static let blackholePkgURL = "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg"
    private static let blackholePkgSHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    func installBlackHole() {
        guard !blackholeFound else {
            L("BlackHole 已安装，无需重复安装")
            return
        }
        blackholeInstalling = true
        L("📦 正在从官方下载 BlackHole 2ch 驱动…")
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 下载官方 pkg 到临时目录
            let tmpPkg = "/tmp/BlackHole2ch-\(ProcessInfo.processInfo.processIdentifier).pkg"
            let fm = FileManager.default
            try? fm.removeItem(atPath: tmpPkg)
            let downloadTask = Process()
            downloadTask.launchPath = "/usr/bin/curl"
            downloadTask.arguments = ["-sL", "--fail", "--max-time", "60",
                                      "-o", tmpPkg, Self.blackholePkgURL]
            let dlPipe = Pipe()
            downloadTask.standardError = dlPipe
            do { try downloadTask.run(); downloadTask.waitUntilExit() } catch {
                DispatchQueue.main.async { self.finishBlackHoleInstall(false, "下载失败：\(error.localizedDescription)") }
                return
            }
            guard downloadTask.terminationStatus == 0 else {
                let err = String(data: dlPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "?"
                DispatchQueue.main.async { self.finishBlackHoleInstall(false, "下载失败（网络？）：\(err)") }
                return
            }
            // 2) 校验 sha256（防止下载内容被篡改）
            let shaTask = Process()
            shaTask.launchPath = "/usr/bin/shasum"
            shaTask.arguments = ["-a", "256", tmpPkg]
            let shaPipe = Pipe()
            shaTask.standardOutput = shaPipe
            do { try shaTask.run(); shaTask.waitUntilExit() } catch {
                DispatchQueue.main.async { self.finishBlackHoleInstall(false, "校验启动失败") }
                return
            }
            let shaOut = String(data: shaPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let actual = shaOut.split(separator: " ").first.map(String.init) ?? ""
            guard actual == Self.blackholePkgSHA256 else {
                DispatchQueue.main.async { self.finishBlackHoleInstall(false, "校验失败：下载内容与官方 sha256 不符（\(actual)），已中止安装") }
                return
            }
            // 3) 用 osascript 弹管理员密码框，调系统 installer 安装
            DispatchQueue.main.async { self.L("✓ 下载校验通过，请输入管理员密码完成安装…") }
            let script = "do shell script \"/usr/sbin/installer -pkg \\\"\(tmpPkg)\\\" -target /\" with administrator privileges"
            let instTask = Process()
            instTask.launchPath = "/usr/bin/osascript"
            instTask.arguments = ["-e", script]
            let instPipe = Pipe()
            instTask.standardOutput = instPipe
            instTask.standardError = instPipe
            do { try instTask.run(); instTask.waitUntilExit() } catch {
                DispatchQueue.main.async { self.finishBlackHoleInstall(false, "安装启动失败：\(error.localizedDescription)") }
                return
            }
            let status = instTask.terminationStatus
            let output = String(data: instPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? fm.removeItem(atPath: tmpPkg)   // 清理临时 pkg
            DispatchQueue.main.async {
                self.finishBlackHoleInstall(status == 0, status == 0 ? "" : "安装失败（可能取消了密码框）：\(output)")
            }
        }
    }
    private func finishBlackHoleInstall(_ success: Bool, _ failure: String) {
        blackholeInstalling = false
        if success {
            L("✅ BlackHole 驱动已安装。请【重启 Mac】后语音转麦克风功能才能生效。")
            checkBlackHole()
        } else {
            L("❌ \(failure)")
        }
    }

    /// The app produces audio into BlackHole, so selecting it as the system input is
    /// required for Dictation and input methods to receive the remote microphone.
    func selectBlackHoleAsSystemInput() {
        guard let device = Self.deviceID(named: "BlackHole") else {
            L("⚠️ 无法选择 BlackHole：CoreAudio 尚未枚举该设备。安装驱动后请重启 Mac。")
            blackholeSelectedAsInput = false
            return
        }
        var selected = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &selected)
        blackholeSelectedAsInput = status == noErr && Self.defaultInputDevice() == device
        L(blackholeSelectedAsInput ? "✅ 已自动选择 BlackHole 为系统输入" : "⚠️ BlackHole 已检测到，但设为系统输入失败 (OSStatus \(status))")
    }

    /// Switch to the Mac's actual built-in input device for a physical Fn/Globe
    /// voice action. Selecting by CoreAudio transport avoids locale-dependent
    /// device names such as “MacBook Air麦克风”.
    func selectBuiltInMicrophone() {
        guard let device = Self.builtInInputDevice() else {
            L("⚠️ 未找到 Mac 内建麦克风，保持当前系统输入")
            return
        }
        var selected = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &selected)
        blackholeSelectedAsInput = false
        L(status == noErr ? "🎙️ 本机 Fn 已切换到 Mac 内建麦克风" : "⚠️ 切换 Mac 内建麦克风失败 (OSStatus \(status))")
    }
    /// Explicit retry actions for the one-time initial TCC request. Repeated
    /// automatic prompts are noisy and macOS ignores them after the first denial.
    func requestAX() {
        if !AXIsProcessTrusted() {
            let _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            L("📌 请在弹窗中点击「打开系统设置」，勾选本 App")
        }
        checkPermissions()
    }
    func requestInputMonitoring() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            L("📌 已请求输入监控权限；请在系统设置中允许本 App")
        }
        checkPermissions()
    }
    /// 一次性申请所有未授权的权限（UI"一键授权"调用）。
    /// 对每项独立判断：未授权才请求，已授权则跳过。macOS 对同一 App 每项权限最多主动弹一次，
    /// 若之前拒绝过则请求会被系统静默忽略——此时打开系统设置页让用户手动开启。
    func requestAllPermissions() {
        var requested: [String] = []
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            requested.append("辅助功能")
        }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            requested.append("输入监控")
        }
        if requested.isEmpty {
            L("✅ 所有权限均已授权")
        } else {
            L("📌 已请求授权：" + requested.joined(separator: "、") + "；请在系统设置中允许本 App")
            // 请求发出后打开系统设置页，方便用户直接勾选（尤其之前拒绝过、系统不再弹窗的情况）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        checkPermissions()
    }
    func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // ---------- audio ----------
    private var audioSetupDone = false
    private func setupAudio() {
        guard !audioSetupDone else { return }
        audioSetupDone = true
        checkBlackHole()
        if !blackholeFound {
            L("⚠️ 未找到 BlackHole。请安装 BlackHole 2ch 并在系统声音输入中选中它；App 不会自动请求管理员权限安装驱动。")
        }
        // 持续监控：检测到 BlackHole 出现后挂上
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioWatchdog(reason: "配置变化通知") }
        }
        rebuildAudio()
    }
    /// 重建音频图并挂到 BlackHole
    private func rebuildAudio() {
        // 防止空 fmt 重建
        if srcNode == nil {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            srcNode = AVAudioSourceNode(format: fmt) { [ring] _, _, frames, abl in
                let l = UnsafeMutableAudioBufferListPointer(abl)
                if let m = l[0].mData { ring.pop(m.assumingMemoryBound(to: Float.self), Int(frames)) }
                return noErr
            }
            engine.attach(srcNode)
            engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
            do { try engine.start() } catch { L("音频引擎启动失败: \(error)") }
        }
        setOutputDevice()
        engine.prepare()
        if !engine.isRunning {
            do { try engine.start() } catch { L("音频引擎启动失败: \(error)") }
        }
        verifyOutputDevice()
    }
    func audioWatchdog(reason: String = "定时检查") {
        guard let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit else { return }
        var cur: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        guard cur != bh || !engine.isRunning else { return }
        L("⚠️ 音频输出脱离 BlackHole（\(reason)，当前设备 \(cur)），自动重新挂载…")
        engine.stop()
        setOutputDevice()
        engine.prepare()
        do { try engine.start() } catch { L("音频引擎重启失败: \(error)") }
        verifyOutputDevice()
    }
    private func setOutputDevice() {
        guard let bh = Self.deviceID(named: "BlackHole") else { L("⚠️ 未找到 BlackHole 声卡，语音无法当麦克风"); return }
        guard let u = engine.outputNode.audioUnit else { L("⚠️ 输出单元不可用"); return }
        var d = bh
        let st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { L("⚠️ 切换输出到 BlackHole 失败 (OSStatus \(st))") }
    }
    private func verifyOutputDevice() {
        guard let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit else { return }
        var cur: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        if cur == bh {
            L("音频输出已挂到 BlackHole (设备 \(bh))")
        } else {
            // 启动过程又被重置了：停机重设再启动
            L("⚠️ 输出设备被重置 (当前 \(cur))，重试切换 BlackHole…")
            engine.stop()
            setOutputDevice()
            engine.prepare()
            do { try engine.start() } catch { L("音频引擎重启失败: \(error)") }
            AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
            L(cur == bh ? "音频输出已挂到 BlackHole (设备 \(bh))" : "❌ 仍未能切到 BlackHole，语音无法当麦克风")
        }
    }
    static func deviceID(named target: String) -> AudioDeviceID? {
        var size = UInt32(0)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        let n = Int(size)/MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: n)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        for id in ids {
            var ns = UInt32(MemoryLayout<CFString?>.size); var name: CFString? = nil
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            withUnsafeMutablePointer(to: &name) { _ = AudioObjectGetPropertyData(id, &na, 0, nil, &ns, $0) }
            if let nm = name as String?, nm.contains(target) { return id }
        }
        return nil
    }
    static func defaultInputDevice() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    static func builtInInputDevice() -> AudioDeviceID? {
        var size = UInt32(0)
        var allDevices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &allDevices, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &allDevices, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var transport: UInt32 = 0
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                               mScope: kAudioObjectPropertyScopeGlobal,
                                                               mElement: kAudioObjectPropertyElementMain)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                             mScope: kAudioDevicePropertyScopeInput,
                                                             mElement: kAudioObjectPropertyElementMain)
            var streamsSize = UInt32(0)
            if AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
                return id
            }
        }
        return nil
    }

    // ---------- BLE (ATVV voice + mic) ----------
    fileprivate func btStateChanged(_ c: CBCentralManager) {
        let stMap: [CBManagerState: String] = [.unknown:"unknown", .resetting:"resetting", .unsupported:"unsupported", .unauthorized:"unauthorized", .poweredOff:"poweredOff", .poweredOn:"poweredOn"]
        let old = btOn
        btOn = (c.state == .poweredOn)
        L("🔵 蓝牙状态: \(stMap[c.state] ?? "?")")
        if !old && btOn {
            L("🔵 蓝牙已开，启动搜索")
            startSearching()
        } else if c.state == .unauthorized {
            L("⚠️ 蓝牙未授权，请在系统设置→隐私与安全→蓝牙 中允许本 App")
        }
    }
    func startSearching() {
        guard !systemSuspended, let c = cm, c.state == .poweredOn else { return }
        let generation = reconnectGeneration
        // 1) 枚举所有系统已配对/已连接的遥控器，全部加入候选列表（不再 .first 抢一台）。
        //    小米/联想遥控器配对后会与系统持有 HID(0x1812)/Battery(0x180F) 持续连接。
        for svc in seed {
            for d in c.retrieveConnectedPeripherals(withServices: [svc]) {
                addCandidate(d, rssi: 0, via: "system/\(svc.uuidString)")
            }
        }
        // 2) 连接选中项。扫描只在"没有候选"或"用户手动要求重扫"时启动，
        //    避免每次重连/恢复都触发 30 秒扫描，导致列表反复刷新和重复条目。
        connectSelectedIfNeeded()
        if discoveredRemotes.isEmpty && !scanning {
            startScan(generation: generation)
        }
    }

    private func startScan(generation: Int) {
        guard let c = cm, !scanning else { return }
        scanning = true
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        L("🎧 正在扫描蓝牙语音遥控器…")
        L("💡 提示：长按遥控器【主页+菜单】5秒，指示灯快闪即进入配对模式")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let s = self, s.scanning, !s.systemSuspended,
                  s.reconnectGeneration == generation else { return }
            s.cm?.stopScan(); s.scanning = false
            if s.discoveredRemotes.isEmpty {
                s.L("⚠️ 30 秒内未发现遥控器，将在 3 秒后重试。")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.reconnectGeneration == generation, !self.systemSuspended else { return }
                    self.startSearching()
                }
            } else {
                s.L("扫描结束，共发现 \(s.discoveredRemotes.count) 个候选遥控器")
            }
        }
    }

    /// 设备显示名覆盖。某些遥控器的广播名不直观（如 "XiaoxinM2Pro BT"），
    /// 按原始名映射成用户更易识别的名字。匹配用小写子串，兼容大小写差异。
    /// - "小米蓝牙语音遥控器"（小米 RC003/2Pro，VID 0x2717）→ 小米蓝牙遥控器2 Pro
    /// - "XiaoxinM2Pro BT"（联想，VID 0x17EF）→ 小米蓝牙语音遥控器
    static func displayName(for rawName: String) -> String {
        let n = rawName.lowercased()
        // 先匹配联想那台（"xiaoxin" 是更独特的标记），避免和小米那台混。
        if n.contains("xiaoxin") || n.contains("m2pro") { return "小米蓝牙语音遥控器" }
        if n.contains("小米蓝牙") || n.contains("xiaomi") { return "小米蓝牙遥控器2 Pro" }
        return rawName
    }

    /// 把发现到的设备加入候选列表（按 identifier 去重），并缓存 CBPeripheral 供连接用。
    private func addCandidate(_ p: CBPeripheral, rssi: Int, via: String) {
        let id = p.identifier
        let rawName = p.name ?? "未知遥控器"
        let name = Self.displayName(for: rawName)
        let isFirst = discoveredPeripherals.isEmpty
        discoveredPeripherals[id] = p
        // 双重去重：同一台物理设备可能因系统配对枚举/扫描返回不同 identifier 的 CBPeripheral，
        // 但显示名一致。用户视角下"同名就是同一台"，所以按 (id, name) 任一命中都视为已存在，
        // 把新对象并入已有条目（更新 RSSI / peripheral 句柄），避免列表出现重复。
        let byID = discoveredRemotes.firstIndex { $0.id == id }
        let byName = discoveredRemotes.firstIndex { $0.name == name }
        if let i = byID ?? byName {
            discoveredRemotes[i].name = name
            if rssi != 0 { discoveredRemotes[i].rssi = rssi }
            // 已连接的条目保留 connected=true，不被新对象覆盖成 false
            if dev?.identifier == id { discoveredRemotes[i].connected = true }
            // 用最新的 peripheral 句柄（连接用），并让 id 字段与实际 dev 对齐
            discoveredRemotes[i].id = id
        } else {
            discoveredRemotes.append(RemoteCandidate(id: id, name: name, rssi: rssi, connected: dev?.identifier == id))
            L("📡 发现遥控器: \(name) (RSSI \(rssi)dBm, via \(via))")
        }
        // 首次发现且用户尚未选择时，默认选第一台（保持开箱即用）
        if selectedRemoteID == nil {
            // 优先恢复上次持久化的选择（系统配对设备 identifier 跨重启稳定）
            if isFirst, let saved = UserDefaults.standard.string(forKey: "selectedRemoteID"),
               let savedID = UUID(uuidString: saved) {
                selectedRemoteID = savedID
            }
            // 若保存的选择不在当前候选中，或没有保存过，则选首个
            if selectedRemoteID == nil || !discoveredPeripherals.keys.contains(selectedRemoteID!) {
                if isFirst { selectedRemoteID = id }
            }
        }
    }

    /// 连接当前选中设备（若未选中则选首个）。仅在未连接或连接的不是目标时才连。
    private func connectSelectedIfNeeded() {
        guard let c = cm else { return }
        let target = selectedRemoteID ?? discoveredRemotes.first?.id
        guard let id = target, let p = discoveredPeripherals[id] else { return }
        if let cur = dev, cur.identifier == id, remoteConnected { return }   // 已是目标且已连接
        if let cur = dev, cur.identifier != id {
            cm.cancelPeripheralConnection(cur)   // 切换：先断旧设备
        }
        dev = p; p.delegate = proxy; capsSent = false; tx = nil
        handshakeReady = false
        c.connect(p, options: nil)
        // 刷新各候选的 connected 标记
        for i in discoveredRemotes.indices {
            discoveredRemotes[i].connected = (p.identifier == discoveredRemotes[i].id)
        }
        L("🔗 连接遥控器: \(Self.displayName(for: p.name ?? "?"))")
    }

    /// 手动切换当前遥控器（UI 调用）。
    func selectRemote(_ id: UUID) {
        guard selectedRemoteID != id || dev?.identifier != id else { return }
        userDisconnected = false   // 切换设备视为主动操作，清除断开标志
        selectedRemoteID = id
        // 持久化选择：系统配对设备的 identifier 跨重启稳定，下次启动自动回连同一台
        UserDefaults.standard.set(id.uuidString, forKey: "selectedRemoteID")
        // 清掉旧连接的 ATVV 状态，避免错位
        if let cur = dev, cur.identifier != id {
            cm.cancelPeripheralConnection(cur)
            dev = nil; tx = nil; capsSent = false
            handshakeReady = false; streaming = false; micStreaming = false
        }
        connectSelectedIfNeeded()
    }

    // 防御性：连接失败也重连
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        L("⚠️ 连接失败: \(Self.displayName(for: p.name ?? "?")) \(error?.localizedDescription ?? "?")，3 秒后重试。")
        // 连接失败时把候选标记为未连接
        if let i = discoveredRemotes.firstIndex(where: { $0.id == p.identifier }) {
            discoveredRemotes[i].connected = false
        }
        let generation = reconnectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.reconnectGeneration == generation, !self.systemSuspended else { return }
            self.connectSelectedIfNeeded()
        }
    }
    func retryScan() {
        // 手动重新扫描：清候选后重新发现，保留 selectedRemoteID 以便回连原选择
        userDisconnected = false
        discoveredRemotes.removeAll(); discoveredPeripherals.removeAll()
        if let cur = dev { cm?.cancelPeripheralConnection(cur) }
        dev = nil; tx = nil; capsSent = false
        remoteConnected = false; handshakeReady = false; streaming = false; micStreaming = false
        recoverAfterSessionChange(reason: "手动重新连接")
    }
    /// 菜单栏「连接设备」：连回当前选中的遥控器（清除用户断开标志）。
    func connectSelectedRemote() {
        userDisconnected = false
        L("📎 用户请求连接设备")
        // 若之前用 blueutil 真断了，先用 blueutil 重连系统蓝牙，再让 App 重新搜索 ATVV 通道
        let rawName = discoveredRemotes.first(where: { $0.id == selectedRemoteID })?.name ?? ""
        reconnectViaBlueutilThenApp(deviceName: rawName)
    }
    /// 用 blueutil 重连系统蓝牙，成功/失败后都让 App 重新搜索（BLE 通道独立于系统 HID）。
    private func reconnectViaBlueutilThenApp(deviceName: String) {
        if deviceName.isEmpty || (
            !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/blueutil")
            && !FileManager.default.isExecutableFile(atPath: "/usr/local/bin/blueutil")) {
            // 无 blueutil 或无名，直接走 App 重连
            connectSelectedIfNeeded()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 找 MAC（从所有 paired 设备里匹配名字）
            let listTask = Process()
            listTask.launchPath = "/usr/bin/env"
            listTask.arguments = ["blueutil", "--paired"]
            let pipe = Pipe(); listTask.standardOutput = pipe; listTask.standardError = Pipe()
            do { try listTask.run(); listTask.waitUntilExit() } catch { return }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var matchedMAC: String?
            for line in output.split(separator: "\n") {
                let s = String(line)
                if s.contains("name: \"\(deviceName)\"") || s.contains(deviceName) {
                    if let r = s.range(of: "address: ([0-9a-fA-F-]{17})", options: .regularExpression) {
                        matchedMAC = s[r].replacingOccurrences(of: "address: ", with: "")
                    }
                }
            }
            if let mac = matchedMAC {
                let connTask = Process()
                connTask.launchPath = "/usr/bin/env"
                connTask.arguments = ["blueutil", "--connect", mac]
                try? connTask.run(); connTask.waitUntilExit()
                Task { @MainActor in self.L("🔌 blueutil 重连系统蓝牙：\(deviceName) (\(mac))") }
            }
            // 无论 blueutil 成功与否，都让 App 重新搜索连接 ATVV 通道
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.connectSelectedIfNeeded()
                if self.dev == nil { self.startSearching() }
            }
        }
    }
    /// 菜单栏「断开设备」：断开当前遥控器，且不自动重连（直到用户主动连接）。
    func disconnectCurrentRemote() {
        userDisconnected = true
        streaming = false; micStreaming = false
        // 获取当前设备原始名（blueutil 按名字匹配 MAC）
        let rawName = dev?.name ?? discoveredRemotes.first(where: { $0.id == selectedRemoteID })?.name ?? ""
        if let cur = dev { cm?.cancelPeripheralConnection(cur) }
        dev = nil; tx = nil; capsSent = false
        remoteConnected = false; handshakeReady = false
        if let i = discoveredRemotes.firstIndex(where: { $0.connected }) { discoveredRemotes[i].connected = false }
        recoverStuckModifiers()
        L("✂️ 用户请求断开设备，不再自动重连")
        // 用 blueutil 真断系统蓝牙（BLE 通道断开对按键无效，按键走系统 HID 直传；
        // 只有系统蓝牙断开才能让遥控器彻底停止发 HID 报告）。
        disconnectViaBlueutil(deviceName: rawName)
    }
    /// 用 blueutil 按设备名匹配 MAC 并断开系统蓝牙连接（彻底断，防自发误触）。
    private func disconnectViaBlueutil(deviceName: String) {
        guard !deviceName.isEmpty else { return }
        // blueutil 可能未安装，优雅降级
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/blueutil")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/blueutil") else {
            L("⚠️ 未安装 blueutil，无法真断蓝牙。安装：brew install blueutil")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 读已连接设备列表，匹配名字拿 MAC
            let listTask = Process()
            listTask.launchPath = "/usr/bin/env"
            listTask.arguments = ["blueutil", "--connected"]
            let pipe = Pipe(); listTask.standardOutput = pipe; listTask.standardError = pipe
            do { try listTask.run(); listTask.waitUntilExit() } catch { return }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // 输出行格式: address: xx-xx-xx-xx-xx-xx, connected, ..., name: "设备名", ...
            var matchedMAC: String?
            for line in output.split(separator: "\n") {
                let s = String(line)
                if s.contains("name: \"\(deviceName)\"") || s.contains(deviceName) {
                    if let addrRange = s.range(of: "address: ([0-9a-fA-F-]{17})", options: .regularExpression) {
                        matchedMAC = s[addrRange].replacingOccurrences(of: "address: ", with: "")
                    }
                }
            }
            guard let mac = matchedMAC else {
                Task { @MainActor in self.L("⚠️ blueutil 未找到设备「\(deviceName)」") }
                return
            }
            // 2) 断开（不 unpair，便于重连）
            let discTask = Process()
            discTask.launchPath = "/usr/bin/env"
            discTask.arguments = ["blueutil", "--disconnect", mac]
            do { try discTask.run(); discTask.waitUntilExit() } catch { return }
            let status = discTask.terminationStatus
            Task { @MainActor in
                self.L(status == 0 ? "🔌 blueutil 已断开系统蓝牙：\(deviceName) (\(mac))" : "⚠️ blueutil 断开失败（状态 \(status)）")
            }
        }
    }
    fileprivate func didDiscover(_ p: CBPeripheral, rssi: Int) {
        // 加入候选列表（addCandidate 内部按 id/名称去重），扫描继续让用户能看到所有设备。
        addCandidate(p, rssi: rssi, via: "scan")
        lastFoundName = p.name ?? "?"
        lastRSSI = rssi
        // 只在当前没有任何活跃连接时才尝试连接选中项，避免每个广播都触发断连重连。
        if dev == nil || !remoteConnected {
            connectSelectedIfNeeded()
        }
    }
    fileprivate func didConnect(_ p: CBPeripheral) { remoteConnected = true; p.discoverServices([ATVV]) }
    fileprivate func didDisconnect() {
        remoteConnected = false; handshakeReady = false; streaming = false
        // 修饰键卡死恢复：BLE 断开后检查系统修饰键状态，若 Command/Shift/Control/Option
        // 仍被标记按下，发合成 key-up 复位（满足验收标准：断开后 USB 键盘状态全零）。
        recoverStuckModifiers()
        // 用户主动断开时不自动重连；系统睡眠也不重连
        guard !systemSuspended, !userDisconnected else { return }
        // 自动重连：先看是否系统配对，再扫描
        let generation = reconnectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.reconnectGeneration == generation,
                  !self.systemSuspended, !self.userDisconnected else { return }
            self.startSearching()
        }
    }
    /// 检查系统修饰键状态，若遥控器遗留了"按下未松开"，发 key-up 复位。
    private func recoverStuckModifiers() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var recovered: [String] = []
        // 修饰键 keycode：左⌘=0x37 右⌘=0x36 左⇧=0x38 右⇧=0x3C 左⌥=0x3A 右⌥=0x3D 左⌃=0x3B 右⌃=0x3E
        if flags.contains(.maskCommand) {
            postKey(0x37, down: false, cmd: false); postKey(0x36, down: false, cmd: false); recovered.append("⌘")
        }
        if flags.contains(.maskShift) {
            postKey(0x38, down: false, cmd: false); postKey(0x3C, down: false, cmd: false); recovered.append("⇧")
        }
        if flags.contains(.maskAlternate) {
            postKey(0x3A, down: false, cmd: false); postKey(0x3D, down: false, cmd: false); recovered.append("⌥")
        }
        if flags.contains(.maskControl) {
            postKey(0x3B, down: false, cmd: false); postKey(0x3E, down: false, cmd: false); recovered.append("⌃")
        }
        if !recovered.isEmpty {
            L("🔧 BLE 断开后复位卡死修饰键：\(recovered.joined(separator: " "))")
        }
    }
    fileprivate func didServices(_ p: CBPeripheral) {
        if let s = p.services?.first(where: { $0.uuid == ATVV }) { p.discoverCharacteristics([TX,RX,CTL], for: s) }
    }
    fileprivate func didChars(_ p: CBPeripheral, _ s: CBService) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == TX { tx = ch }
            else if ch.uuid == RX || ch.uuid == CTL { p.setNotifyValue(true, for: ch) }
        }
    }
    fileprivate func didNotify(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        if ch.uuid == CTL && ch.isNotifying && !capsSent {
            sendATVVCaps(force: false)
        }
    }
    fileprivate func didWrite(_ p: CBPeripheral, _ ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == TX else { return }
        if let error {
            handshakeReady = false
            voiceFailure = "ATVV 握手写入失败：\(error.localizedDescription)"
            L("❌ \(voiceFailure)")
        } else {
            handshakeReady = true
            voiceFailure = ""
            L("✅ ATVV 语音握手已确认")
        }
    }
    private func sendATVVCaps(force: Bool) {
        guard let p = dev, let tx else {
            voiceFailure = "未找到 ATVV 命令通道"
            L("❌ \(voiceFailure)")
            return
        }
        guard force || !capsSent else { return }
        capsSent = true
        handshakeReady = false
        p.writeValue(Data([0x0A,0x00,0x06,0x00,0x01]), for: tx, type: .withResponse)
        L("→ 正在请求 ATVV 语音能力…")
    }
    fileprivate func didValue(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        guard let d = ch.value else { return }
        if ch.uuid == RX {
            if streaming {
                voicePacketCount += 1
                voiceBytesReceived += d.count
                lastVoicePacketAt = ProcessInfo.processInfo.systemUptime
                voiceFailure = ""
                if voicePacketCount == 1 {
                    L("✅ 已收到首个 ATVV 音频帧（\(d.count) bytes），正在解码并转发")
                }
                let pcm = dsp.process(codec.decode(d))
                if micStreaming { ring.push(pcm) }
            }
        } else if ch.uuid == CTL, let f = d.first {
            // 诊断：记录 CTL 通道收到的原始值，便于确认 Pro 语音键的按下/松开字节
            L("CTL 通道收到: 0x\(String(format:"%02X", f)) (共 \(d.count) bytes: \(d.map{String(format:"%02X",$0)}.joined(separator:" ")))")
            if f == 0x04 { voiceButton(down: true) }
            else if f == 0x00 { voiceButton(down: false) }
        }
    }
    private func voiceButton(down: Bool) {
        // 两种模式都通过 HID 设备层重映射（F5 → Globe 或 LeftControl），这里不再发合成键。
        // config.voice.keycode 固定 0x3F，仅用于 v.display 文案；真正的按键行为由 voiceMode 决定。
        let v = config.voice
        let modeLabel = config.voiceMode == .leftControl ? "左 Control" : v.display
        // BLE 通道也标记语音键状态：与 HID 报告双保险，谁先到谁立标记，确保原生 F5 被吞
        voiceHidDown = down
        lastHidKeycodeAt[HIDMap.voiceKeycode] = ProcessInfo.processInfo.systemUptime
        if down {
            if blackholeFound && !blackholeSelectedAsInput { selectBlackHoleAsSystemInput() }
            codec.reset(); dsp.reset(); streaming = true
            micStreaming = config.voiceStartsMic && blackholeFound && blackholeSelectedAsInput
            voicePacketCount = 0; voiceBytesReceived = 0; voiceFailure = ""
            voiceSessionStartAt = ProcessInfo.processInfo.systemUptime
            // 按键已由 HID 重映射处理，此处只管音频流；不再 postKey，避免和重映射重复。
            if !handshakeReady {
                voiceFailure = "ATVV 尚未握手完成"
                sendATVVCaps(force: true)
            } else if config.voiceStartsMic && !micStreaming {
                voiceFailure = "BlackHole 未就绪，音频只做接收诊断，不会转发"
            }
            L("🎤 语音键按下 → \(modeLabel)\(micStreaming ? " + 麦克风转发" : "")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.streaming, self.voicePacketCount == 0 else { return }
                self.voiceFailure = "未收到音频帧，正在重试 ATVV 握手"
                self.L("⚠️ \(self.voiceFailure)")
                self.sendATVVCaps(force: true)
            }
        } else {
            // 松键不立即关闭音频流：BLE 上可能还有 1-2 个尾音包在路上（CTL 的松开信号
            // 0x00 往往比最后一个 RX 音频包早到几百毫秒）。立即关 streaming 会导致句尾
            // 一两个字被丢弃（"最后两个字被吃"的根因）。延迟 300ms 再关，让尾音包都收进来。
            // micStreaming 保持 true，让 ring 继续接收尾音；streaming 保持 true 让 didValue 继续解码。
            L("语音键松开 · 等待尾音包（300ms）…")
            let sessionPackets = voicePacketCount
            let sessionBytes = voiceBytesReceived
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                // 300ms 内若又按下语音键（连续操作），不关闭
                guard !self.voiceHidDown else { return }
                let extraPackets = self.voicePacketCount - sessionPackets
                let extraBytes = self.voiceBytesReceived - sessionBytes
                streaming = false; micStreaming = false
                let dur = ProcessInfo.processInfo.systemUptime - voiceSessionStartAt
                let expBytes = Int(dur * 8000)
                let ratio = expBytes > 0 ? Double(voiceBytesReceived) / Double(expBytes) : 0
                let lossPct = max(0, 1.0 - ratio) * 100
                if extraPackets > 0 {
                    L("语音键松开 · 时长 \(String(format:"%.1f", dur))s · 收到 \(voicePacketCount) 帧 / \(voiceBytesReceived) bytes（含尾音 +\(extraPackets)帧/\(extraBytes)b）· 丢失 \(String(format:"%.0f", min(100,lossPct)))%")
                } else {
                    L("语音键松开 · 时长 \(String(format:"%.1f", dur))s · 收到 \(voicePacketCount) 帧 / \(voiceBytesReceived) bytes · 预期 ~\(expBytes) bytes · 丢失 \(String(format:"%.0f", min(100,lossPct)))%")
                }
            }
        }
    }

    // ---------- HID reading ----------
    private func setupHID() {
        guard hidMgr == nil else { return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // 匹配已知遥控器厂商 VID（小米 0x2717 / 联想 0x17EF）。
        // 用 IOHIDManagerRegisterInputValueCallback（元素值回调）而非 RegisterInputReportCallback，
        // 因为 value callback 在内核 hidutil No-Event 映射【之前】拿到原始 usage——
        // 这样内核屏蔽自发噪声到前台的同时，App 仍能读取按键做映射（变速删除/备忘录等）。
        IOHIDManagerSetDeviceMatchingMultiple(mgr, [
            [kIOHIDVendorIDKey: 0x2717],
            [kIOHIDVendorIDKey: 0x17EF],
        ] as CFArray)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openRes == kIOReturnSuccess else {
            L("⚠️ IOHIDManagerOpen 失败: \(openRes)（输入监控权限未授权？）")
            return
        }
        // 注册 value 回调（Manager 级，对所有匹配设备生效）。
        // 回调签名：(context, result, sender, value)。value 是 IOHIDValue。
        // 在内核 hidutil No-Event 映射【之前】拿到原始 usage，不受屏蔽影响。
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let valueCallback: IOHIDValueCallback = { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let rawValue = IOHIDValueGetIntegerValue(value)
            if Thread.isMainThread {
                MainActor.assumeIsolated { me.handleHIDValue(page: page, usage: usage, rawValue: rawValue) }
            } else {
                DispatchQueue.main.async {
                    Task { @MainActor in me.handleHIDValue(page: page, usage: usage, rawValue: rawValue) }
                }
            }
        }
        IOHIDManagerRegisterInputValueCallback(mgr, valueCallback, ctx)
        // 同时注册 report callback：value callback 在部分 BLE HID 设备上不可靠（收不到事件），
        // report callback 直接拿原始报告字节，更可靠。handleHIDReport 已含完整解析逻辑
        // （XiaomiRemoteHIDParser 翻译 compact/keyboard-array/consumer 三种形态）。
        // 两条路径都调 hidReport(usage:)，但 hidReport 内部有 downButtonUsage 去重，
        // 同一键不会双触发。report callback 是音量键等 special 动作的主路径。
        let reportCallback: IOHIDReportCallback = { context, result, _, type, reportID, report, length in
            guard result == kIOReturnSuccess, let context else { return }
            let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
            let n = min(Int(length), 64)
            let bytes = Array(UnsafeBufferPointer(start: report, count: n))
            if Thread.isMainThread {
                MainActor.assumeIsolated { me.handleHIDReport(bytes) }
            } else {
                DispatchQueue.main.async {
                    Task { @MainActor in me.handleHIDReport(bytes) }
                }
            }
        }
        IOHIDManagerRegisterInputReportCallback(mgr, reportCallback, ctx)
        // 枚举设备用于日志
        inputMonitoringOK = true
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty {
            var seen = Set<String>()
            var count = 0
            for dvc in set {
                let name = (IOHIDDeviceGetProperty(dvc, kIOHIDProductKey as CFString) as? String) ?? "?"
                let vid = (IOHIDDeviceGetProperty(dvc, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
                let pid = (IOHIDDeviceGetProperty(dvc, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
                guard RemoteDeviceFilter.isEligible(vid: vid, pid: pid, product: name) else { continue }
                let key = "\(vid):\(pid):\(name)"
                if seen.contains(key) { continue }
                seen.insert(key)
                count += 1
                L("📱 HID 设备: \(Self.displayName(for: name)) (VID 0x\(String(format:"%04X",vid)) PID 0x\(String(format:"%04X",pid)))")
            }
            L("✅ HID 监听 \(count) 个遥控设备（value callback，内核屏蔽后仍可读）")
        }
        hidMgr = mgr
        if hidMgr != nil { flashKey(label: "✓ 遥控器就绪", mapping: "可以开始按键") }
    }

    private func teardownHID() {
        guard let manager = hidMgr else { return }
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDDeviceClose(device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            }
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        hidMgr = nil
        hidBufs.forEach { $0.deallocate() }
        hidBufs.removeAll()
        L("已重置遥控器 HID 监听")
    }

    /// Xiaomi remotes expose both compact and keyboard-array report layouts.
    /// Normalize either form before dispatching a button action.
    /// IOHIDValue 回调处理（内核 hidutil 映射前读取，不受 No-Event 屏蔽影响）。
    /// 每个 HID 元素值变化触发一次，做 down/up 配对后调用 hidReport(usage:) 复用全部映射逻辑。
    private func handleHIDValue(page: UInt32, usage: UInt32, rawValue: Int) {
        // 同时处理两种报告页：
        //   - Keyboard page (0x07)：小米主流形态，usage 直接是内部键码
        //   - Consumer Control page (0x0C)：部分固件走此页（Volume+=0xE9 / Volume-=0xEA 等），
        //     用 consumerToInternal 翻译成内部统一 usage 后复用同一套映射逻辑。
        let u: Int
        if page == 0x07 {
            u = Int(usage)
        } else if page == 0x0C {
            guard let mapped = XiaomiRemoteHIDParser.consumerToInternal[UInt8(truncatingIfNeeded: usage)] else { return }
            u = Int(mapped)
        } else {
            return
        }
        let knownUsages: Set<Int> = [0x52, 0x51, 0x50, 0x4F, 0x28, 0xF1, 0x4A, 0x35, 0x65, 0x66, 0x3E, 0x80, 0x81]
        guard knownUsages.contains(u) else { return }

        if rawValue != 0 {
            // 新键按下：若之前有别的键 active，先发 release
            if activeValueUsage != 0 && activeValueUsage != u {
                hidReport(usage: 0)
            }
            // 同键重复（自动重复）→ 忽略
            if activeValueUsage == u { return }
            activeValueUsage = u
            hidReport(usage: UInt8(u))
        } else {
            // release（rawValue==0）
            if activeValueUsage == u {
                hidReport(usage: 0)
                activeValueUsage = 0
            }
        }
    }

    private func handleHIDReport(_ bytes: [UInt8]) {
        // 诊断模式：记录所有 HID 报告原始字节（含被过滤的圆盘/圆环），用于排查"静置自发误触"。
        // 通过 hidDiagMode 开关控制，避免正常使用时刷屏。标注报告格式便于区分真实按压 vs 自发噪声。
        if hidDiagMode {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let fmt = bytes.count == 7 && bytes[0] == 0x01 ? "01格式" : (bytes.count == 7 && bytes[0] == 0x03 ? "03格式" : "其他")
            L("🔬HID原始[\(fmt) \(bytes.count)字节]: \(hex)")
        }
        let reportKind = RemoteHIDReportKind.classify(bytes)
        recordReport(reportKind)
        // 圆盘 ReportID=0x03 的位移字节可能恰好等于 0x28/方向键 usage。
        // 必须在通用 usage 扫描前分流，否则会被误派发为按键。
        if reportKind == .scrollRing {
            // 圆盘默认关闭（防误触）。用户在 UI 开启后才解码滚动；关闭时直接静默丢弃。
            guard ringEnabled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            if let evt = ringDecoder.consume(bytes, at: now) {
                postScroll(evt.lines)
                L("🖲圆盘滚动: \(hex) → \(evt.lines) 行")
            } else if ringLearningMode {
                // 学习模式额外记录原始字节供分析（非学习模式不刷屏）
                ringLearningBuffer.append((bytes: bytes, at: now))
                L("🗃圆盘帧: \(hex)（未达稳定阈值，忽略）")
            }
            return
        }
        let known = Set(config.buttons.map { UInt8(truncatingIfNeeded: $0.usage) } + [HIDMap.voiceUsage])
        // 先尝试解析已知 usage——即使报告来自鼠标/指针通道，若内含已知按键也优先识别。
        if let usage = XiaomiRemoteHIDParser.usage(in: bytes, known: known) {
            hidReport(usage: usage)
            return
        }
        if XiaomiRemoteHIDParser.isRelease(bytes) {
            hidReport(usage: 0)
            return
        }
        // Pro 圆环转动会发密集的键盘数组报告（ReportID=0x01，10 字节，主键 [3] 是字母/数字
        // usage 如 0x04(A)/0x2C(空格)/0x1D(Z) 等 + 各种修饰键组合）。这些不是按压键
        // （按压键走 0x28/0xF1/0x4A/0x65 等，已在上面识别），是圆环触摸滑动产生的噪声，
        // 静默丢弃，不打印日志。圆环的方向识别留待后续采样工具实现。
        if bytes.count == 10 && bytes[0] == 0x01 {
            return
        }
        // 真正未知的报告才打印，便于把新 usage 补进 Config.known
        L("未识别的 HID 报告: \(XiaomiRemoteHIDParser.describe(bytes))")
    }

    private func hidReport(usage: UInt8) {
        let now = ProcessInfo.processInfo.systemUptime
        if usage != 0 {
            let disposition = RemoteInputGuard.disposition(for: usage)
            recordDisposition(disposition, usage: usage)
            if disposition == .blockedBack {
                // 分支 59268b0 已验证 Back(0xF1) 会在静置时自发出现；它不再参与任何映射。
                L("🛡 Back(0xF1) 已统一过滤，不执行任何动作")
                return
            }
        }
        if usage == 0x00 {
            longPressTimer?.invalidate(); longPressTimer = nil
            deleteRepeatTimer?.invalidate(); deleteRepeatTimer = nil
            // 方向键延迟确认取消：若 pendingDirection 还未触发（<80ms 就 release），视为抖动脉冲，
            // 不发送 key-down，也不发 key-up（彻底静默），过滤拿起误触。
            if pendingDirectionUsage != 0 {
                let heldMs = Int((now - pendingDirectionDownAt) * 1000)
                L("方向键采样: 0x\(String(format: "%02X", pendingDirectionUsage)) 按住 \(heldMs)ms（<80ms，未执行）")
                pendingDirectionTimer?.invalidate(); pendingDirectionTimer = nil
                pendingDirectionUsage = 0; pendingDirectionMapping = nil; pendingDirectionDownAt = 0
                downButtonUsage = 0; downTarget = nil; longPressFired = false
                recentUsages.removeAll()
                return
            }
            recentUsages.removeAll()   // release 时清抖动记录，允许下一轮真实按压
            if voiceHidDown { voiceHidDown = false; lastHidKeycodeAt[HIDMap.voiceKeycode] = now }
            if let t = downTarget {
                if t.usage == 0xF1 && t.keycode == 0x33 {
                    // Back 键不再承担删除（避免遥控器自发 0xF1 误删用户内容）。
                    // 仅做脉冲时长诊断，不主动发任何删除键。Back 的实际行为交给系统透传。
                    // deleteRepeatTimer 已在上面 invalidate。
                    let pulseMs = Int((now - backDownAt) * 1000)
                    if pulseMs < 35 {
                        L("Back(0xF1) 短脉冲 \(pulseMs)ms，视为抖动忽略")
                    } else {
                        L("Back(0xF1) 松开（按下 \(pulseMs)ms，不删除）")
                    }
                } else if t.longPressKeycode != nil {
                    if !longPressFired { tapMapping(t) }
                } else if t.keycode >= KeyNames.kSpecialBase { stopSpecial(t.keycode) }
                else if t.keycode != KeyNames.kNone { postKey(CGKeyCode(t.keycode), down: false, cmd: false) }
                if [0x52, 0x51, 0x50, 0x4F].contains(t.usage), pendingDirectionDownAt > 0 {
                    let heldMs = Int((now - pendingDirectionDownAt) * 1000)
                    L("方向键采样: 0x\(String(format: "%02X", t.usage)) 按住 \(heldMs)ms（已执行）")
                }
            }
            downButtonUsage = 0; downTarget = nil; longPressFired = false; pendingDirectionDownAt = 0
            return
        }
        if usage == HIDMap.voiceUsage {
            voiceHidDown = true
            lastHidKeycodeAt[HIDMap.voiceKeycode] = now
            return
        }
        // HID keeps emitting the same key-down report while a key is held.  Synthesize
        // one key-down only; the all-zero report below is responsible for key-up.
        if downButtonUsage == Int(usage) { return }
        // 抖动检测：拿起遥控器/手指抖动会产生短时间多键快速来回跳的脉冲序列
        // （如 0xf1→0x28→0x52 混跳）。真实人不可能在 150ms 内连按 3 种不同按压键。
        // 阈值用 3（不是 4）：实测拿起抖动常是 3 种混合，4 会漏判。
        recentUsages = recentUsages.filter { now - $0.at < 0.15 }
        recentUsages.append((Int(usage), now))
        let distinctCount = Set(recentUsages.map { $0.usage }).count
        if distinctCount >= 3 {
            bounceSuppressUntil = now + 0.15
            recentUsages.removeAll()
            // 抖动判定时强制停掉所有按键定时器（防止 Back 的 0.4s 删除定时器已启动、继续删）
            longPressTimer?.invalidate(); longPressTimer = nil
            deleteRepeatTimer?.invalidate(); deleteRepeatTimer = nil
            downButtonUsage = 0; downTarget = nil
            L("⚠️ 检测到抖动（150ms 内 \(distinctCount) 种按键切换），已停所有定时器")
            return
        }
        // 处于抖动抑制期内，忽略新的 down（release 不忽略，确保能复位）
        if now < bounceSuppressUntil {
            return
        }
        // 额外保护：Back(删除) 的定时器若在等待中（0.4s 内）收到别的按键，立即取消
        // （真实长按 Back 不会夹杂其他按键）。
        if downButtonUsage == 0xF1 && Int(usage) != 0xF1 {
            deleteRepeatTimer?.invalidate(); deleteRepeatTimer = nil
            longPressTimer?.invalidate(); longPressTimer = nil
            downButtonUsage = 0; downTarget = nil
        }
        lastButtonUsage = Int(usage)
        lastButton = String(format: "0x%02x", usage)
        if let kc = HIDMap.usageToKeycode[usage] { lastHidKeycodeAt[kc] = now }
        guard let m = config.buttons.first(where: { $0.usage == Int(usage) }) else {
            let msg = String(format: "按键 0x%02x 未在映射表中（保持原样）", usage)
            L(msg)
            self.flashKey(label: String(format: "0x%02x", usage), mapping: "未映射")
            return
        }
        let msg = String(format: "0x%02x [%@] → %@", usage, m.name, m.display)
        L(msg)
        self.flashKey(label: m.name, mapping: m.display)
        // TV 键静置时不自发，作为唯一删除入口：按下删除一个字符，同时续期唤醒。
        // Back 已无条件过滤；OK 保持确认键，避免删除和确认互相误伤。
        if usage == RemoteInputGuard.deleteUsage {
            wakeByTVKey()
            postKey(0x33, down: true, cmd: false)
            postKey(0x33, down: false, cmd: false)
            downButtonUsage = Int(usage); downTarget = nil
            L("TV(删除) 单击删除 1 字")
            flashKey(label: "TV 键", mapping: "删除 1 字")
            return
        }
        if m.keycode == KeyNames.kNone { downButtonUsage = Int(usage); downTarget = nil; return }
        if Int(usage) == 0x28 && m.keycode == 0x33 {
            // OK 改为「仅长按删除」：单击不删除（避免拿起遥控器/手指抖动误触），
            // 按住 ≥400ms 才开始连续删除。OK 自发 0 次（最稳），适合承担删除。
            backDownAt = now
            downButtonUsage = Int(usage); downTarget = m
            L("OK(删除) 已按下，按住 0.4 秒后开始删除…")
            startDeleteRepeat(usage: 0x28)
            return
        }
        if Int(usage) == 0xF1 && m.keycode == 0x33 {
            // Back「单击删 1 个字」：down 时发一次完整 keyDown+keyUp，不启动连续删除。
            // 用户已知接受 Pro 遥控器自发 0xF1 的误删风险（仅单字，不会连续删一片）。
            backDownAt = now
            downButtonUsage = Int(usage); downTarget = nil   // downTarget=nil：release 不再补发
            postKey(0x33, down: true, cmd: false)
            postKey(0x33, down: false, cmd: false)
            L("Back(删除) 单击删除 1 字")
            return
        }
        if Int(usage) == 0x28 {
            // OK 只有持续 2 秒才发一次当前映射（默认 Return）；短按/噪声不产生任何动作。
            var gatedMapping = m
            gatedMapping.keycode = KeyNames.kNone
            gatedMapping.longPressKeycode = m.keycode
            downButtonUsage = Int(usage); downTarget = gatedMapping; longPressFired = false
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: RemoteInputGuard.confirmLongPressDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downButtonUsage == Int(usage) else { return }
                    self.longPressFired = true
                    self.tapMapping(m)
                    self.flashKey(label: "长按 OK", mapping: m.display)
                }
            }
            return
        }
        if Int(usage) == 0x65 {
            // Menu 只有持续 2 秒才发一次当前映射（默认 Esc）；短按/噪声不产生任何动作。
            var gatedMapping = m
            gatedMapping.keycode = KeyNames.kNone
            gatedMapping.longPressKeycode = m.keycode
            downButtonUsage = Int(usage); downTarget = gatedMapping; longPressFired = false
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: RemoteInputGuard.menuLongPressDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downButtonUsage == Int(usage) else { return }
                    self.longPressFired = true
                    self.tapMapping(m)
                    self.flashKey(label: "长按 Menu", mapping: m.display)
                }
            }
            return
        }
        // 方向键必须持续 80ms 才确认；阈值来自用户实测短按分布。
        if Int(usage) == 0x52 || Int(usage) == 0x51
            || Int(usage) == 0x50 || Int(usage) == 0x4F {
            pendingDirectionUsage = Int(usage)
            pendingDirectionMapping = m
            pendingDirectionDownAt = now
            downButtonUsage = Int(usage)   // 标记为按下，防止 HID 重复 down 干扰
            pendingDirectionTimer?.invalidate()
            pendingDirectionTimer = Timer.scheduledTimer(withTimeInterval: RemoteInputGuard.directionHoldDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.pendingDirectionUsage == Int(usage) else { return }
                    // 80ms 内没收到 release，确认是真实按压，发送 key-down
                    if let pm = self.pendingDirectionMapping {
                        self.downTarget = pm
                        if pm.keycode >= KeyNames.kSpecialBase { self.startSpecial(pm.keycode) }
                        else { self.postKey(CGKeyCode(pm.keycode), down: true, cmd: pm.cmd, shift: pm.shift, opt: pm.opt, ctrl: pm.ctrl) }
                    }
                    self.pendingDirectionUsage = 0
                    self.pendingDirectionMapping = nil
                    self.pendingDirectionTimer = nil
                }
            }
            return
        }
        if Int(usage) == 0x4A {
            // Home 只有持续 3 秒才打开备忘录；短按/噪声 release 不产生任何动作。
            downButtonUsage = Int(usage); downTarget = m; longPressFired = false
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: RemoteInputGuard.homeLongPressDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downButtonUsage == Int(usage) else { return }
                    self.longPressFired = true
                    self.trigger(keycode: KeyNames.kOpenNotes, mapping: m, down: true)
                    self.flashKey(label: "长按 Home", mapping: "打开备忘录")
                }
            }
            return
        }
        if let long = m.longPressKeycode {
            downButtonUsage = Int(usage); downTarget = m; longPressFired = false
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downButtonUsage == Int(usage) else { return }
                    self.longPressFired = true
                    self.trigger(keycode: long, mapping: m, down: true)
                    self.flashKey(label: "长按 \(m.name)", mapping: KeyNames.label(keycode: long, cmd: false, shift: false, opt: false, ctrl: false))
                }
            }
            return
        }
        if m.keycode >= KeyNames.kSpecialBase {
            startSpecial(m.keycode); downButtonUsage = Int(usage); downTarget = m; return
        }
        postKey(CGKeyCode(m.keycode), down: true, cmd: m.cmd, shift: m.shift, opt: m.opt, ctrl: m.ctrl)
        downButtonUsage = Int(usage); downTarget = m
    }

    private func tapMapping(_ mapping: ButtonMapping) {
        trigger(keycode: mapping.keycode, mapping: mapping, down: true)
        if mapping.keycode < KeyNames.kSpecialBase && mapping.keycode != KeyNames.kNone {
            postKey(CGKeyCode(mapping.keycode), down: false, cmd: false)
        }
    }

    private func trigger(keycode: Int, mapping: ButtonMapping, down: Bool) {
        if keycode >= KeyNames.kSpecialBase { if down { startSpecial(keycode) } else { stopSpecial(keycode) } }
        else if keycode != KeyNames.kNone { postKey(CGKeyCode(keycode), down: down, cmd: mapping.cmd, shift: mapping.shift, opt: mapping.opt, ctrl: mapping.ctrl) }
    }

    /// 启动长按连续删除定时器。
    /// - 参数 usage：触发删除的 usage（0x28 = OK，0xF1 = Back）。两者共用同一套
    ///   "0.4s 后开始 → 越删越快"的手感；OK 是"仅长按删除"（单击不删），Back 是
    ///   "单击删 1 个 + 长按连续"（down 路径已先发过单击的 keyDown+keyUp）。
    private func startDeleteRepeat(usage: Int) {
        deleteRepeatTimer?.invalidate()
        deleteRepeatStartedAt = ProcessInfo.processInfo.systemUptime
        lastDeleteRepeatAt = deleteRepeatStartedAt
        // macOS 原生长按删除手感：慢起步 → 平滑指数加速 → 高速收尾。
        // "越闪越快"的视觉节奏来自间隔本身的非线性收缩（每次删除后间隔乘以衰减系数），
        // 而不是按固定时间线性变化。这比线性加速更符合人眼对节奏变化的感知。
        // 首延迟 0.4s：配合"仅长按删除"——拿起抖动脉冲通常 <300ms，400ms 足以过滤；
        // 真实长按 0.4s 后才开始删，响应仍够快。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.downButtonUsage == usage else { return }
            // 动态间隔：用可变状态而非闭包常量，每删一次就收缩一次
            var interval: Float = 0.12        // 起始 0.12s（~8 次/秒，慢，能看清一个个删）
            let minInterval: Float = 0.022    // 收尾 0.022s（~45 次/秒，飞快）
            let decay: Float = 0.92           // 每删一次间隔 ×0.92（指数加速）
            self.lastDeleteRepeatAt = ProcessInfo.processInfo.systemUptime
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downButtonUsage == usage else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - self.lastDeleteRepeatAt >= TimeInterval(interval) else { return }
                    self.lastDeleteRepeatAt = now
                    self.postKey(0x33, down: true, cmd: false)
                    self.postKey(0x33, down: false, cmd: false)
                    // 每删一次，间隔指数收缩一次 → 越闪越快
                    interval = max(minInterval, interval * decay)
                }
            }
        }
    }

    /// 触发前台大字弹窗：刷新 label / mapping / token，UI 监听 keyFlash 来做动画
    private func flashKey(label: String, mapping: String) {
        lastKeyLabel = label
        lastKeyMapping = mapping
        lastKeyAtMs = Date().timeIntervalSince1970
        keyFlash &+= 1
    }

    private func showNotification(title: String, body: String) {
        // 旧通知 API 已废弃，全部走前台弹窗 flashKey
        flashKey(label: title, mapping: body)
    }

    // ---------- CGEvent tap: suppress originals of mapped buttons ----------
    private func installTap() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, ud in
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        return Unmanaged.passUnretained(event)
                    }
                    guard let ud = ud else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<Engine>.fromOpaque(ud).takeUnretainedValue()
                    // ignore our own synthetic events
                    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker {
                        return Unmanaged.passUnretained(event)
                    }
                    let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    if me.shouldSuppress(kc) {
                        return nil // swallow the remote's original key
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: ctx) else { L("⚠️ 无法创建事件拦截（需辅助功能授权）"); return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }
    // 导航/编辑类键码集合：用于速率熔断统计（Delete/方向/回车/空格/Esc）。
    // 这些是遥控器自发误触的主角，Mac 键盘连续高频敲它们很少见。
    private static let navKeycodes: Set<CGKeyCode> = [
        0x33,       // Delete / Backspace
        0x7E, 0x7D, 0x7B, 0x7C,  // 方向 上/下/左/右
        0x24,       // Return
        0x31,       // Space
        0x35,       // Esc
    ]
    // 休眠态/全局暂停 可拦截的键（只含方向键 + Esc）。
    // Delete/Return/Space 绝对不拦——它们是 Mac 键盘高频刚需键，拦了会废掉打字。
    // 遥控器 Delete/Return 自发的防护交给：40ms 短脉冲过滤 + 速率熔断（不靠休眠态全拦）。
    private static let suppressibleNavKeycodes: Set<CGKeyCode> = [
        0x7E, 0x7D, 0x7B, 0x7C,  // 方向 上/下/左/右
        0x35,       // Esc
    ]
    // called from tap thread — keep it cheap & thread-safe-ish (dictionary read)
    nonisolated func shouldSuppress(_ kc: CGKeyCode) -> Bool {
        // 注意：此函数从 CGEvent tap 线程高频调用，绝不能在里面打日志或做重活，
        // 否则会拖慢整个事件流（曾因每次都 L() 导致主线程繁忙、语音卡顿、Back 删除时序错乱）。
        //
        // 核心原则：Mac 键盘永远好用。App 是"键盘之外的附加"，防误触只靠 TV 唤醒状态机，
        // 绝不无差别吞 Mac 键盘的键（曾因速率熔断/全集拦截误伤 Mac 的 Delete/回车）。
        // Mac 刚需键（Delete/Return/Space）任何情况下都不拦——即便休眠态也不拦，
        // 因为 CGEvent tap 分不清事件来自 Mac 键盘还是遥控器，宁可放过不可误伤。
        var suppress = false
        MainActor.assumeIsolated {
            let now = ProcessInfo.processInfo.systemUptime
            // F5（语音键）：仅在 HID 重映射未就绪时吞掉，防止触发 macOS 原生听写
            if kc == HIDMap.voiceKeycode {
                suppress = !hardwareGlobeReady && (voiceHidDown || (lastHidKeycodeAt[kc].map { now - $0 < 0.12 } ?? false))
                return
            }
            // Mac 刚需键（Delete/回车/空格）任何情况下都不拦——分不清来源，宁可放过
            if kc == 0x33 || kc == 0x24 || kc == 0x31 { return }
            // ① 全局暂停 / ② 休眠态：只拦方向键 + Esc（Mac 键盘这些键用得少，且 TV 模式下
            // 用户预期方向键被锁）。Delete/回车/空格已在上面放行。
            if (remotePaused || (tvWakeEnabled && !remoteAwake)) && Self.suppressibleNavKeycodes.contains(kc) {
                suppress = true
                return
            }
            // 唤醒期内有合法导航键，续期（防止操作中途进入休眠）
            if tvWakeEnabled && remoteAwake && Self.navKeycodes.contains(kc) {
                awakeUntil = now + awakeTimeout
            }
            // 内核 hidutil No-Event 屏蔽已吞掉遥控器原始事件，系统不会双触发，
            // 不需要原来的 120ms 时间窗拦截。shouldSuppress 现在只处理 F5 和休眠态。
        }
        return suppress
    }

    // ---------- 特殊动作：鼠标移动/点击/滚轮 ----------
    private var specialTimer: Timer?
    private var specialCode = 0
    private var mouseSpeed: CGFloat = 0

    func setSpecial(usage: Int, keycode: Int) {
        if usage == -1 {
            config.voice.keycode = keycode; config.voice.cmd = false; config.voice.shift = false; config.voice.opt = false; config.voice.ctrl = false
        } else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].keycode = keycode; config.buttons[i].cmd = false
            config.buttons[i].shift = false; config.buttons[i].opt = false; config.buttons[i].ctrl = false
        }
        L("已设置映射 → \(KeyNames.label(keycode: keycode, cmd: false, shift: false, opt: false, ctrl: false))")
        saveConfig()
    }

    func setLongPressSpecial(usage: Int, keycode: Int?) {
        guard usage != -1, let i = config.buttons.firstIndex(where: { $0.usage == usage }) else { return }
        config.buttons[i].longPressKeycode = keycode
        L(keycode == nil ? "已清除长按动作" : "已设置长按动作 → \(KeyNames.label(keycode: keycode!, cmd: false, shift: false, opt: false, ctrl: false))")
        saveConfig()
    }

    private func startSpecial(_ code: Int) {
        switch code {
        case KeyNames.kMouseClick:  postMouse(.leftMouseDown, .left)
        case KeyNames.kMouseRClick: postMouse(.rightMouseDown, .right)
        case KeyNames.kLockScreen:
            lockScreen()
        case KeyNames.kShowDesktop:
            // F11 is macOS's standard Show Desktop shortcut. It keeps the
            // remote's Home button system-level and independent of any editor.
            postKey(0x67, down: true, cmd: false, shift: false, opt: false, ctrl: false)
            postKey(0x67, down: false, cmd: false)
            L("→ 已发送显示桌面（F11）")
        case KeyNames.kOpenNotes:
            // 打开 macOS 备忘录，并自动新建一条笔记。用 NSWorkspace 按 bundle id 打开，
            // App 真正激活后再发 ⌘N 新建笔记（在 completion 里触发，避免 App 还没起来就发键）。
            let ws = NSWorkspace.shared
            let openAndFocus = {
                // 等 Notes 完全成为前台后再发 ⌘N。延迟 0.4s 足够它绘制窗口。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    // ⌘N = 新建笔记（Notes 的标准快捷键）
                    self.postKey(0x2D, down: true, cmd: true)   // 0x2D = N
                    self.postKey(0x2D, down: false, cmd: false)
                }
            }
            if let appURL = ws.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true   // 确保成为前台
                ws.openApplication(at: appURL, configuration: config) { _, error in
                    if let error {
                        Task { @MainActor in self.L("⚠️ 打开备忘录失败：\(error.localizedDescription)") }
                    } else {
                        Task { @MainActor in
                            self.L("→ 已打开备忘录，正在新建笔记…")
                            openAndFocus()
                        }
                    }
                }
            } else {
                // 兜底：用 open 命令打开，再延迟发 ⌘N
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", "Notes"]
                try? task.run()
                L("→ 已打开备忘录（fallback），正在新建笔记…")
                openAndFocus()
            }
        case KeyNames.kScreenshotAndLock:
            // Save a full-screen screenshot first; lock shortly afterwards so the
            // screenshot reflects the current coding context rather than the lock UI.
            postKey(0x14, down: true, cmd: true, shift: true, opt: false, ctrl: false)
            postKey(0x14, down: false, cmd: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.lockScreen() }
        case KeyNames.kInterrupt:
            postKey(0x08, down: true, cmd: false, ctrl: true) // ⌃C
            postKey(0x08, down: false, cmd: false)
            L("→ 已发送终端中断 ⌃C")
        case KeyNames.kVolumeUp:
            // 立即调一次，再起 0.18s 间隔的连续调节定时器；松开由 stopSpecial 兜底停掉。
            adjustSystemVolume(step: 1)
            specialCode = code
            specialTimer?.invalidate()
            specialTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.adjustSystemVolume(step: 1) }
            }
        case KeyNames.kVolumeDown:
            adjustSystemVolume(step: -1)
            specialCode = code
            specialTimer?.invalidate()
            specialTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.adjustSystemVolume(step: -1) }
            }
        case KeyNames.kShutdownConfirm:
            confirmShutdown()
        default:
            specialCode = code; mouseSpeed = 4
            specialTimer?.invalidate()
            specialTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.specialTick() }
            }
        }
    }
    private func stopSpecial(_ code: Int) {
        switch code {
        case KeyNames.kMouseClick:  postMouse(.leftMouseUp, .left)
        case KeyNames.kMouseRClick: postMouse(.rightMouseUp, .right)
        default: specialTimer?.invalidate(); specialTimer = nil
        }
    }
    private func lockScreen() {
        // Use the standard ⌃⌘Q shortcut directly.  The former AppleScript route
        // also required a separate Automation permission for System Events and
        // silently failed when that permission had not been granted.
        guard AXIsProcessTrusted() else {
            L("❌ 锁屏未执行：请先在设置中授权辅助功能")
            return
        }
        postKey(0x0C, down: true, cmd: true, ctrl: true)
        postKey(0x0C, down: false, cmd: false)
        L("→ 已发送锁屏快捷键 ⌃⌘Q")
    }
    private func confirmShutdown() {
        let alert = NSAlert()
        alert.messageText = "要关机吗？"
        alert.informativeText = "这是由遥控器长按电源键触发的。未保存的工作可能会丢失。"
        alert.addButton(withTitle: "关机")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
        _ = script?.executeAndReturnError(nil)
    }
    private func specialTick() {
        switch specialCode {
        case KeyNames.kMouseUp:    moveMouse(0, -1)
        case KeyNames.kMouseDown:  moveMouse(0, 1)
        case KeyNames.kMouseLeft:  moveMouse(-1, 0)
        case KeyNames.kMouseRight: moveMouse(1, 0)
        case KeyNames.kScrollUp:   postScroll(2)
        case KeyNames.kScrollDown: postScroll(-2)
        default: break
        }
    }
    private func moveMouse(_ dx: CGFloat, _ dy: CGFloat) {
        let p = CGEvent(source: nil)?.location ?? .zero
        var np = CGPoint(x: p.x + dx * mouseSpeed, y: p.y + dy * mouseSpeed)
        mouseSpeed = min(28, mouseSpeed * 1.05)   // 按住越久移动越快
        // 不越出屏幕：目标点不在任何屏幕上时，钳制回当前屏幕
        var cnt: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &cnt)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(cnt))
        CGGetActiveDisplayList(cnt, &ids, &cnt)
        let ds = ids.map { CGDisplayBounds($0) }
        if !ds.contains(where: { $0.contains(np) }), let d = ds.first(where: { $0.contains(p) }) {
            np.x = min(max(np.x, d.minX), d.maxX - 1)
            np.y = min(max(np.y, d.minY), d.maxY - 1)
        }
        if let e = CGEvent(mouseEventSource: evSrc, mouseType: .mouseMoved, mouseCursorPosition: np, mouseButton: .left) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    private func postMouse(_ type: CGEventType, _ btn: CGMouseButton) {
        let p = CGEvent(source: nil)?.location ?? .zero
        if let e = CGEvent(mouseEventSource: evSrc, mouseType: type, mouseCursorPosition: p, mouseButton: btn) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    private func postScroll(_ lines: Int32) {
        if let e = CGEvent(scrollWheelEvent2Source: evSrc, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    // ---------- 系统音量（CoreAudio 合成，不依赖系统收到 HID 事件）----------
    /// 遥控器音量键(0x80/0x81) 的原始 HID 事件被 VoiceGlobeMapper 在内核层映射成
    /// No-Event 吞掉，系统收不到 → 无法走原生音量 HUD。App 在 value callback
    /// （内核映射之前）能读到原始 usage，触发本方法用 CoreAudio 直接调系统默认
    /// 输出设备的音量。步长 1/16（约 6.25%），按住通过 specialTimer 连续调节。
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// 调系统默认输出设备音量。step ∈ {-1, +1}；读当前音量 → 加减 1/16 → 钳制 [0,1] → 写回。
    /// 没有音量属性（HDMI/DisplayLink 等数字输出）时静默跳过，不刷屏。
    private func adjustSystemVolume(step: Int) {
        guard let dev = Self.defaultOutputDevice() else { return }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,    // kAudioDevicePropertyScopeOutput
            mElement: kAudioObjectPropertyElementMain)  // master channel = 0
        // 先看 master channel (0) 有没有音量属性；没有再退到 channel 1（部分设备只有 per-channel volume）
        var hasVolume = AudioObjectHasProperty(dev, &addr)
        if !hasVolume {
            addr.mElement = 1
            hasVolume = AudioObjectHasProperty(dev, &addr)
        }
        guard hasVolume,
              AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr else { return }
        let delta: Float32 = 1.0 / 16.0
        let oldVol = vol
        vol = max(0, min(1, vol + Float32(step) * delta))
        // 读到的音量和新音量一样（已在边界）就不写，避免无意义调用 + 日志噪音
        guard abs(vol - oldVol) > 0.0001 else { return }
        guard AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol) == noErr else { return }
        L("🔊 音量\(step > 0 ? "+" : "−") \(String(format: "%.0f%%", oldVol * 100))→\(String(format: "%.0f%%", vol * 100))")
        // per-channel：同步 channel 2（立体声右声道）
        if addr.mElement == 1 {
            var addr2 = addr; addr2.mElement = 2
            if AudioObjectHasProperty(dev, &addr2) {
                _ = AudioObjectSetPropertyData(dev, &addr2, 0, nil, size, &vol)
            }
        }
    }

    // ---------- synthesize keys ----------
    // 用 .privateState 而非 .hidSystemState：私有状态源不污染系统 HID 修饰键状态。
    // 之前用 hidSystemState 时，合成带 ⌘ 的事件（如 ⌘N 打开备忘录）会改变系统对修饰键的
    // 认知，导致物理 ⌘ 键失灵（"command 不能用"）。privateState 下合成事件自带 flags，
    // 不读取也不修改系统状态，彻底隔离。postKey 已显式传 cmd/shift/opt/ctrl，不受影响。
    private let evSrc = CGEventSource(stateID: .privateState)
    func postKey(_ code: CGKeyCode, down: Bool, cmd: Bool, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) {
        guard AXIsProcessTrusted() else {
            if code == 0x3F && down { L("❌ Fn 未发送：需要在系统设置中允许「小米超级键盘」的辅助功能权限") }
            return
        }
        var flags: CGEventFlags = []
        if down {
            if cmd { flags.insert(.maskCommand) }
            if shift { flags.insert(.maskShift) }
            if opt { flags.insert(.maskAlternate) }
            if ctrl { flags.insert(.maskControl) }
            // Fn is a modifier in macOS, not merely a normal virtual key.  Sending
            // both the key code and secondary-Fn flag makes remote hold behave like
            // holding the physical Fn key for input methods such as WeChat IME.
            if code == 0x3F { flags.insert(.maskSecondaryFn) }
        }
        // macOS delivers the physical Fn key as a modifier transition, not as a
        // normal keyDown/keyUp pair.  Several input methods intentionally ignore
        // synthetic normal key events for Fn, so use the matching event family.
        if code == 0x3F {
            guard let e = CGEvent(keyboardEventSource: evSrc, virtualKey: code, keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
            L(down ? "→ 已发送 Fn 按下（flagsChanged）" : "→ 已发送 Fn 松开（flagsChanged）")
            return
        }
        guard let e = CGEvent(keyboardEventSource: evSrc, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
        e.post(tap: .cghidEventTap)
    }
}

// CBCentralManager/CBPeripheral delegate proxy (Engine is @MainActor)
final class BTProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var e: Engine?
    init(_ e: Engine) { self.e = e }
    func centralManagerDidUpdateState(_ c: CBCentralManager) { Task { @MainActor in e?.btStateChanged(c) } }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { Task { @MainActor in e?.didConnect(p) } }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { Task { @MainActor in e?.didDisconnect() } }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { Task { @MainActor in e?.centralManager(c, didFailToConnect: p, error: error) } }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String : Any], rssi RSSI: NSNumber) {
        guard let name = (p.name ?? d[CBAdvertisementDataLocalNameKey] as? String)?.lowercased() else { return }
        let keywords = ["小米蓝牙","遥控","语音","xiaomi","mi tv","mitv","mi remote","miremote","aibao","xiaoxin","m2pro","lenovo"]
        guard keywords.contains(where: { name.contains($0) }) else { return }
        Task { @MainActor in e?.didDiscover(p, rssi: RSSI.intValue) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { Task { @MainActor in e?.didServices(p) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) { Task { @MainActor in e?.didChars(p, s) } }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didNotify(p, ch) } }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didWrite(p, ch, error: error) } }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didValue(p, ch) } }
}

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
}

struct VoiceDSP {
    var hp = Biquad.highpass(f0: 120, fs: 16000, q: 0.8)     // 滤低频噪声
    var ls = Biquad.lowshelf(f0: 200, fs: 16000, q: 0.5, dbGain: -4)  // 压 200Hz 嗡嗡声
    var eq = Biquad.peaking(f0: 2500, fs: 16000, q: 1.0, dbGain: 3)  // 提亮人声
    var env: Float = 0
    var gate: Float = 0
    var gain: Float = 4
    var noiseFloor: Float = 0.0025
    var noiseMin: Float = 1.0
    mutating func reset() { hp.reset(); ls.reset(); eq.reset(); env = 0; gate = 0; noiseFloor = 0.0025; noiseMin = 1.0 }
    mutating func process(_ xs: [Float]) -> [Float] {
        var out = [Float](); out.reserveCapacity(xs.count)
        for x0 in xs {
            var x = eq.run(ls.run(hp.run(x0)))
            env = max(abs(x), env * 0.999)
            noiseMin = min(noiseMin, abs(x) + 1e-6)
            if abs(x) < noiseFloor * 2 {
                noiseFloor += (noiseMin - noiseFloor) * 0.001
            } else if env < noiseFloor * 4 {
                noiseFloor += (0.0025 - noiseFloor) * 0.0001
            }
            noiseFloor = max(0.0003, min(0.008, noiseFloor))
            noiseMin = min(noiseMin + 0.00001, 1.0)
            let snr = env / max(noiseFloor, 1e-6)
            let gateOpen: Float
            if snr > 3.5 { gateOpen = 1.0 }
            else if snr < 1.8 { gateOpen = 0.02 }
            else { gateOpen = (snr - 1.8) / 1.7 * 0.98 + 0.02 }
            let rate: Float = gateOpen > gate ? 0.05 : 0.0003
            gate += (gateOpen - gate) * rate
            x *= gate
            if env > noiseFloor * 3 {
                let desired = min(24, max(1, 0.25 / max(env, 1e-4)))
                gain += (desired - gain) * 0.001
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
    @Published var log: [String] = []
    @Published var scanning = false
    @Published var lastFoundName: String? = nil
    @Published var lastRSSI: Int = 0
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
    private var streaming = false
    private var lastVoicePacketAt: TimeInterval = 0

    // HID
    private var hidMgr: IOHIDManager?
    private var hidBufs: [UnsafeMutablePointer<UInt8>] = []
    private var lastHidKeycodeAt: [CGKeyCode: TimeInterval] = [:]
    private var voiceHidDown = false   // 语音键的 HID F5 正被按住（需持续吞掉）
    private var downButtonUsage: Int = 0
    private var downTarget: ButtonMapping?
    private var longPressTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private var longPressFired = false
    private var keyMonitor: Any?

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
            .appendingPathComponent("Logs/MiVibeBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("mivibeboard.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        return handle
    }()
    func L(_ s: String) {
        NSLog("[MiVibeBoard] %@", s)
        Engine.logFile?.write((s + "\n").data(using: .utf8)!)
        log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // ---------- lifecycle ----------
    private var started = false
    func start() { startIfNeeded() }
    func startIfNeeded() {
        guard !started else { return }
        started = true
        proxy = BTProxy(self)
        btProxyRef = proxy   // 额外强引用
        ConfigStore.save(config)
        L("语音键映射: \(config.voice.display)")
        applyVoiceGlobeMapping()

        checkPermissions()
        L("权限状态: 辅助功能=\(axTrusted ? "已授权" : "未授权"), 输入监控=\(inputMonitoringOK ? "已授权" : "未授权")")

        // BLE 初始化
        cm = CBCentralManager(delegate: proxy, queue: nil)

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
            }
        }
    }

    func stop() {
        longPressTimer?.invalidate(); deleteRepeatTimer?.invalidate(); specialTimer?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        voiceGlobeMapper.restore()
        hardwareGlobeReady = false
        L("已恢复遥控器原始语音键映射")
    }

    private func applyVoiceGlobeMapping() {
        let applied = voiceGlobeMapper.apply()
        if applied != hardwareGlobeReady {
            hardwareGlobeReady = applied
            L(applied
                ? "✅ 语音键硬件映射已启用：F5 → Apple Globe/Fn"
                : "等待小米遥控器 HID 服务，以启用硬件 Globe/Fn 映射")
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
            guard let self = self, self.capturingUsage != nil else { return ev }
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
    /// Each TCC permission is requested only from its explicit UI button.  Repeated
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
        guard let c = cm, c.state == .poweredOn else { return }
        // 1) 优先看是否已在系统蓝牙里配对过（按多个服务 UUID 逐个 try）
        //    小米遥控器配对后会与系统持有 HID(0x1812)/Battery(0x180F) 持续连接
        for svc in seed {
            if let d = c.retrieveConnectedPeripherals(withServices: [svc]).first {
                dev = d; d.delegate = proxy; capsSent = false; c.connect(d, options: nil)
                L("🔗 已连接系统配对的遥控器: \(d.name ?? "?") (via service \(svc.uuidString))")
                return
            }
        }
        // 2) 否则主动扫描，按名字匹配
        if !scanning {
            scanning = true
            lastFoundName = nil
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            L("🎧 正在扫描小米蓝牙语音遥控器…")
            L("💡 提示：长按遥控器【主页+菜单】5秒，指示灯快闪即进入配对模式")
            // 30 秒内没找到就停止扫描
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let s = self, s.scanning else { return }
                s.cm?.stopScan(); s.scanning = false
                s.L("⚠️ 30 秒内未发现遥控器，将在 3 秒后重试。")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startSearching() }
            }
        }
    }
    // 防御性：连接失败也重连
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        L("⚠️ 连接失败: \(error?.localizedDescription ?? "?")，3 秒后重试。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startSearching() }
    }
    func retryScan() { startSearching() }
    fileprivate func didDiscover(_ p: CBPeripheral, rssi: Int) {
        // 第一个匹配的就停止扫描、连接
        cm.stopScan(); scanning = false
        lastFoundName = p.name ?? "?"
        lastRSSI = rssi
        L("📡 发现 \(p.name ?? "遥控器") (RSSI \(rssi)dBm)，正在连接…")
        dev = p; p.delegate = proxy; capsSent = false; cm.connect(p, options: nil)
    }
    fileprivate func didConnect(_ p: CBPeripheral) { remoteConnected = true; p.discoverServices([ATVV]) }
    fileprivate func didDisconnect() {
        remoteConnected = false; handshakeReady = false; streaming = false
        // 自动重连：先看是否系统配对，再扫描
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startSearching() }
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
            if f == 0x04 { voiceButton(down: true) }
            else if f == 0x00 { voiceButton(down: false) }
        }
    }
    private func voiceButton(down: Bool) {
        let v = config.voice
        // BLE 通道也标记语音键状态：与 HID 报告双保险，谁先到谁立标记，确保原生 F5 被吞
        voiceHidDown = down
        lastHidKeycodeAt[HIDMap.voiceKeycode] = ProcessInfo.processInfo.systemUptime
        if down {
            if blackholeFound && !blackholeSelectedAsInput { selectBlackHoleAsSystemInput() }
            codec.reset(); dsp.reset(); streaming = true
            micStreaming = config.voiceStartsMic && blackholeFound && blackholeSelectedAsInput
            voicePacketCount = 0; voiceBytesReceived = 0; voiceFailure = ""
            if v.keycode >= KeyNames.kSpecialBase { startSpecial(v.keycode) }
            // The remote's own F5 is now an actual Apple Globe/Fn HID event.
            // Never add a synthetic Fn on top of it: WeChat IME rejects that
            // synthetic event and it would also create duplicate transitions.
            else if v.keycode != 0x3F && v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: true, cmd: v.cmd, shift: v.shift, opt: v.opt, ctrl: v.ctrl) }
            if !handshakeReady {
                voiceFailure = "ATVV 尚未握手完成"
                sendATVVCaps(force: true)
            } else if config.voiceStartsMic && !micStreaming {
                voiceFailure = "BlackHole 未就绪，音频只做接收诊断，不会转发"
            }
            L("🎤 语音键按下 → \(v.display)\(micStreaming ? " + 麦克风转发" : "")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.streaming, self.voicePacketCount == 0 else { return }
                self.voiceFailure = "未收到音频帧，正在重试 ATVV 握手"
                self.L("⚠️ \(self.voiceFailure)")
                self.sendATVVCaps(force: true)
            }
        } else {
            streaming = false; micStreaming = false
            if v.keycode >= KeyNames.kSpecialBase { stopSpecial(v.keycode) }
            else if v.keycode != 0x3F && v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: false, cmd: false) }
            L("语音键松开")
        }
    }

    // ---------- HID reading ----------
    private func setupHID() {
        guard hidMgr == nil else { return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x2717] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let openRes = IOHIDManagerOpen(mgr, 0)
        guard openRes == kIOReturnSuccess else {
            L("⚠️ IOHIDManagerOpen 失败: \(openRes)（输入监控权限未授权？）")
            return
        }
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            L("⚠️ IOHID 未发现小米遥控器（Vendor 0x2717），稍后自动重试")
            // 没找到设备时不持久化 hidMgr，让定时器可以重试
            return
        }
        inputMonitoringOK = true
        L("✅ HID 找到 \(set.count) 个小米设备")
        for dvc in set {
            let rsize = (IOHIDDeviceGetProperty(dvc, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
            _ = IOHIDDeviceOpen(dvc, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(rsize,8)); hidBufs.append(buf)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(dvc, buf, max(rsize,8), { context, _, _, _, _, report, len in
                guard let context = context, len > 0 else { return }
                let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: Int(len)))
                MainActor.assumeIsolated { me.handleHIDReport(bytes) }
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(dvc, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        hidMgr = mgr
        if hidMgr != nil { flashKey(label: "✓ 遥控器就绪", mapping: "可以开始按键") }
    }

    /// Xiaomi remotes expose slightly different HID report layouts by model.  Rather
    /// than relying on one fixed byte offset, find known usages anywhere in a report.
    /// A report containing no known usage is the release report for the active key.
    private func handleHIDReport(_ bytes: [UInt8]) {
        let known = Set(config.buttons.map { UInt8(truncatingIfNeeded: $0.usage) } + [HIDMap.voiceUsage])
        let candidates = bytes.filter { known.contains($0) && $0 != 0 }
        if let usage = candidates.last {
            hidReport(usage: usage)
        } else if bytes.allSatisfy({ $0 == 0 }) || (bytes.count > 1 && bytes.dropFirst().allSatisfy({ $0 == 0 })) {
            hidReport(usage: 0)
        } else {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            L("未识别的 HID 报告: \(hex)")
        }
    }

    private func hidReport(usage: UInt8) {
        let now = ProcessInfo.processInfo.systemUptime
        if usage == 0x00 {
            longPressTimer?.invalidate(); longPressTimer = nil
            deleteRepeatTimer?.invalidate(); deleteRepeatTimer = nil
            if voiceHidDown { voiceHidDown = false; lastHidKeycodeAt[HIDMap.voiceKeycode] = now }
            if let t = downTarget {
                if t.longPressKeycode != nil {
                    if !longPressFired { tapMapping(t) }
                } else if t.keycode >= KeyNames.kSpecialBase { stopSpecial(t.keycode) }
                else if t.keycode != KeyNames.kNone { postKey(CGKeyCode(t.keycode), down: false, cmd: false) }
            }
            downButtonUsage = 0; downTarget = nil; longPressFired = false
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
        if m.keycode == KeyNames.kNone { downButtonUsage = Int(usage); downTarget = nil; return }
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
        if Int(usage) == 0xF1 && m.keycode == 0x33 { startDeleteRepeat() }
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

    private func startDeleteRepeat() {
        deleteRepeatTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self, self.downButtonUsage == 0xF1 else { return }
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downButtonUsage == 0xF1 else { return }
                    self.postKey(0x33, down: true, cmd: false)
                    self.postKey(0x33, down: false, cmd: false)
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
    // called from tap thread — keep it cheap & thread-safe-ish (dictionary read)
    nonisolated func shouldSuppress(_ kc: CGKeyCode) -> Bool {
        // suppress if the remote produced this keycode within the last 120ms AND that button is mapped to something other than "keep original"
        var suppress = false
        MainActor.assumeIsolated {
            let now = ProcessInfo.processInfo.systemUptime
            // With the device-level mapping active, F5 has become the genuine
            // Apple Globe/Fn HID event and must reach the input method.  Until
            // the mapping becomes available, keep swallowing F5 so it cannot
            // trigger macOS's native dictation shortcut.
            if kc == HIDMap.voiceKeycode {
                suppress = !hardwareGlobeReady && (voiceHidDown || (lastHidKeycodeAt[kc].map { now - $0 < 0.12 } ?? false))
                if !suppress { L("⚠️ F5 事件到达时语音键标记未立，漏过一次（请反馈）") }
                return
            }
            if let ts = lastHidKeycodeAt[kc], now - ts < 0.12 {
                // find which usage produced this keycode
                if let usage = HIDMap.usageToKeycode.first(where: { $0.value == kc })?.key,
                   let m = config.buttons.first(where: { $0.usage == Int(usage) }),
                   m.keycode != KeyNames.kNone {
                    suppress = true
                }
            }
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
        case KeyNames.kScreenshotAndLock:
            // Save a full-screen screenshot first; lock shortly afterwards so the
            // screenshot reflects the current coding context rather than the lock UI.
            postKey(0x14, down: true, cmd: true, shift: true, opt: false, ctrl: false)
            postKey(0x14, down: false, cmd: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.lockScreen() }
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

    // ---------- synthesize keys ----------
    private let evSrc = CGEventSource(stateID: .hidSystemState)
    func postKey(_ code: CGKeyCode, down: Bool, cmd: Bool, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) {
        guard AXIsProcessTrusted() else {
            if code == 0x3F && down { L("❌ Fn 未发送：需要在系统设置中允许 MiVibeBoard 的辅助功能权限") }
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
        let keywords = ["小米蓝牙","遥控","语音","xiaomi","mi tv","mitv","mi remote","miremote","aibao"]
        guard keywords.contains(where: { name.contains($0) }) else { return }
        Task { @MainActor in e?.didDiscover(p, rssi: RSSI.intValue) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { Task { @MainActor in e?.didServices(p) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) { Task { @MainActor in e?.didChars(p, s) } }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didNotify(p, ch) } }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didWrite(p, ch, error: error) } }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didValue(p, ch) } }
}

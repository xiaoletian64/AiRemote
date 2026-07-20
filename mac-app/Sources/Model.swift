import Foundation
import CoreGraphics

enum KeyNames {
    // macOS virtual keycode -> label (for display of recorded keys)
    static let map: [Int: String] = [
        0x24:"Return", 0x30:"Tab", 0x31:"Space", 0x33:"Delete", 0x35:"Esc",
        0x7E:"↑", 0x7D:"↓", 0x7B:"←", 0x7C:"→",
        0x36:"右⌘", 0x37:"左⌘", 0x38:"⇧", 0x3C:"右⇧", 0x3A:"⌥", 0x3D:"右⌥",
        0x3B:"⌃", 0x3E:"右⌃", 0x39:"Caps", 0x3F:"Fn",
        0x7A:"F1",0x78:"F2",0x63:"F3",0x76:"F4",0x60:"F5",0x61:"F6",0x62:"F7",
        0x64:"F8",0x65:"F9",0x6D:"F10",0x67:"F11",0x6F:"F12",
        0x73:"Home",0x77:"End",0x74:"PgUp",0x79:"PgDn",0x75:"⌦",
        0x00:"A",0x0B:"B",0x08:"C",0x02:"D",0x0E:"E",0x03:"F",0x05:"G",0x04:"H",
        0x22:"I",0x26:"J",0x28:"K",0x25:"L",0x2E:"M",0x2D:"N",0x1F:"O",0x23:"P",
        0x0C:"Q",0x0F:"R",0x01:"S",0x11:"T",0x20:"U",0x09:"V",0x0D:"W",0x07:"X",
        0x10:"Y",0x06:"Z",
        0x12:"1",0x13:"2",0x14:"3",0x15:"4",0x17:"5",0x16:"6",0x1A:"7",0x1C:"8",
        0x19:"9",0x1D:"0",0x1B:"-",0x18:"=",0x21:"[",0x1E:"]",0x2A:"\\",
        0x29:";",0x27:"'",0x2B:",",0x2F:".",0x2C:"/",0x32:"`",
    ]
    // 特殊动作（鼠标/滚轮）：占用 0x10000 以上的伪键码
    static let kSpecialBase = 0x10000
    static let kMouseUp = 0x10001, kMouseDown = 0x10002, kMouseLeft = 0x10003, kMouseRight = 0x10004
    static let kMouseClick = 0x10005, kMouseRClick = 0x10006
    static let kScrollUp = 0x10007, kScrollDown = 0x10008
    static let kLockScreen = 0x10009, kScreenshotAndLock = 0x1000A, kShutdownConfirm = 0x1000B, kInterrupt = 0x1000C, kShowDesktop = 0x1000D, kOpenNotes = 0x1000E
    static let specials: [(name: String, code: Int)] = [
        ("鼠标 ↑", kMouseUp), ("鼠标 ↓", kMouseDown), ("鼠标 ←", kMouseLeft), ("鼠标 →", kMouseRight),
        ("鼠标左键", kMouseClick), ("鼠标右键", kMouseRClick),
        ("滚轮 ↑", kScrollUp), ("滚轮 ↓", kScrollDown),
        ("显示桌面（主页）", kShowDesktop),
        ("打开备忘录", kOpenNotes),
        ("锁定屏幕", kLockScreen), ("截屏后锁屏", kScreenshotAndLock), ("关机（确认）", kShutdownConfirm),
        ("中断当前终端（⌃C）", kInterrupt),
    ]
    static func label(keycode: Int, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) -> String {
        if keycode == kNone { return "（不映射 / 保持原键）" }
        if keycode >= kSpecialBase {
            return specials.first(where: { $0.code == keycode })?.name ?? String(format:"特殊0x%x", keycode)
        }
        let base = map[keycode] ?? String(format:"键码0x%02x", keycode)
        var c = cmd, s = shift, o = opt, t = ctrl
        switch keycode {   // 修饰键自身的 flag 不重复显示
        case 0x36,0x37: c = false
        case 0x38,0x3C: s = false
        case 0x3A,0x3D: o = false
        case 0x3B,0x3E: t = false
        default: break
        }
        var p = ""
        if t { p += "⌃" }; if o { p += "⌥" }; if s { p += "⇧" }; if c { p += "⌘" }
        return p + base
    }
    static let kNone = 0xFFFF
}

enum HIDMap {
    // Remote HID usage -> macOS keycode macOS also generates (for suppression).
    // Some models emit a keyboard-array report, while others emit a compact
    // byte report; Engine normalizes both forms before consulting this table.
    //
    // 注意：这张表只决定"要不要吞掉 macOS 收到的同源原始按键事件"，与按键最终映射成
    // 什么动作（Config.buttons）解耦。保持原样的键（keycode == kNone）不进表，让原始事件
    // 照常透传给系统；映射成动作的键必须进表，否则会和合成事件同时触发。
    static let usageToKeycode: [UInt8: CGKeyCode] = [
        0x52:0x7E, 0x51:0x7D, 0x50:0x7B, 0x4F:0x7C,  // 方向键
        0x28:0x24,                                      // OK → Return
        0x4A:0x73,                                      // Home → Home 键码（仅用于抑制；实际动作由 Config 给）
        0x35:0x32,                                      // TV 键
        0x65:0x6E,                                      // Menu
        // 补全：Power/Menu 此前缺失，导致映射动作与系统电源框/菜单同时触发
        0x66:0x7F,                                      // Power（macOS 没有 Power 虚拟键码；0x7F 仅作抑制占位）
        // Back(0xF1) 默认映射成 Delete(0x33)，Back 的 HID 也需要吞掉原始事件，避免双触发
        0xF1:0x33,
        // 音量±保持原样（不进抑制表）—— macOS 蓝牙 HID 音量键即便保留也常不生效，
        // 真正修好属另一个特性；这里至少保证不被误吞。
    ]
    // 语音键除 BLE 语音流外还会发一个 HID F5（usage 0x3E）；Globe 模式下 macOS 把 F5 当系统
    // 听写 🎤 键必须吞掉；Left-Control 模式下 F5 被设备层重映射成 LeftControl，macOS 不再看到 F5。
    static let voiceUsage: UInt8 = 0x3E
    static let voiceKeycode: CGKeyCode = 0x60   // F5
}

enum XiaomiRemoteHIDParser {
    /// 小米遥控器在野外至少有三种报告形态：
    ///   1) 紧凑 vendor 报告：单字节 usage（旧固件）
    ///   2) 报告 ID + 小端 UInt16 usage 数组（Keyboard 页 0x07，主流形态）
    ///   3) Consumer Control 页(0x0C) 报告：Power=0x30 / Menu=0x40 / Volume+=0xE9 / Volume-=0xEA
    /// 本解析器在所有对齐偏移上扫描 UInt16 usage，命中 known 集合；同时把 Consumer 页
    /// 的常见键翻译成内部统一 usage，让上层一套映射表通用。
    ///
    /// 解析失败时返回 nil，调用方负责打印诊断 hex + 每个非零字节，便于补 usage 表。
    static func usage(in bytes: [UInt8], known: Set<UInt8>) -> UInt8? {
        guard !bytes.isEmpty else { return nil }

        // 先按 UInt16 完整匹配扫描（优先级最高，避免把 report header 当键）
        var matches: [UInt8] = []
        // 起始偏移遍历 0/1，覆盖"有/无 report id"两种布局
        for offset in 0...min(1, max(0, bytes.count - 2)) {
            var index = offset
            while index + 1 < bytes.count {
                let lo = bytes[index], hi = bytes[index + 1]
                let value = UInt16(lo) | (UInt16(hi) << 8)
                // Keyboard 页(0x07) usage：hi==0x07 时 lo 是 usage；lo 单字节也可能是 compact 报告
                if hi == 0x07, known.contains(lo), lo != 0 {
                    matches.append(lo)
                } else if value <= UInt16(UInt8.max), let usage = UInt8(exactly: value), known.contains(usage), usage != 0 {
                    matches.append(usage)
                }
                index += 2
            }
        }
        if let usage = matches.last { return usage }

        // Consumer Control 页(0x0C) 翻译：value 高字节=page，低字节=usage
        var consumerMatch: UInt8?
        for offset in 0...min(1, max(0, bytes.count - 2)) {
            var index = offset
            while index + 1 < bytes.count {
                let lo = bytes[index], hi = bytes[index + 1]
                if hi == 0x0C {   // Consumer 页
                    if let mapped = Self.consumerToInternal[lo] {
                        consumerMatch = mapped
                    }
                }
                index += 2
            }
        }
        if let usage = consumerMatch, known.contains(usage) { return usage }

        // 兜底：旧固件单字节 vendor 报告（取最后一个非零的已知 usage）
        if let usage = bytes.reversed().first(where: { known.contains($0) && $0 != 0 }) {
            return usage
        }
        return nil
    }

    /// Consumer Control(0x0C) usage -> 内部统一 usage（与 Config.known 对齐）
    private static let consumerToInternal: [UInt8: UInt8] = [
        0x30: 0x66,   // Power
        0x40: 0x65,   // Menu
        0x45: 0x28,   // OK / Play→Enter（部分遥控器 OK 走 Consumer）
        0xE9: 0x80,   // Volume Up
        0xEA: 0x81,   // Volume Down
        0xB3: 0x52,   // Fast Forward → 兜底当 上
        0xB4: 0x51,   // Rewind → 兜底当 下
    ]

    static func isRelease(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 == 0 } || (bytes.count > 1 && bytes.dropFirst().allSatisfy { $0 == 0 })
    }

    /// 诊断辅助：把原始报告里每个非零字节/双字节格式化成字符串，方便日志定位未识别按键。
    static func describe(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        var pairs: [String] = []
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            let v = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            if v != 0 { pairs.append(String(format: "[%d]=0x%04X", i, v)) }
        }
        return hex + "  " + pairs.joined(separator: " ")
    }
}

struct ButtonMapping: Identifiable, Codable {
    var usage: Int          // HID usage byte; -1 = voice button
    var name: String        // physical button name
    var keycode: Int        // target macOS keycode; 0xFFFF = keep original
    var cmd: Bool
    var shift: Bool
    var opt: Bool
    var ctrl: Bool
    /// nil means this button has no distinct long-press action.
    var longPressKeycode: Int?
    var id: Int { usage }

    init(usage: Int, name: String, keycode: Int = 0xFFFF, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false, longPressKeycode: Int? = nil) {
        self.usage = usage; self.name = name; self.keycode = keycode
        self.cmd = cmd; self.shift = shift; self.opt = opt; self.ctrl = ctrl
        self.longPressKeycode = longPressKeycode
    }
    var display: String { KeyNames.label(keycode: keycode, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl) }
}

/// 语音键映射模式。
/// - globe: 把遥控器 F5 在 HID 层重映射成 Apple Globe/Fn，微信输入法等可识别（系统听写原语）
/// - leftControl: 重映射成左 Control 修饰键，用于 Ctrl 组合快捷键；不触发系统听写
enum VoiceMode: String, Codable, CaseIterable {
    case globe
    case leftControl
    var label: String {
        switch self {
        case .globe:       return "地球 / Fn（系统听写）"
        case .leftControl: return "左 Control（修饰键）"
        }
    }
    var detail: String {
        switch self {
        case .globe:       return "微信输入法等可识别，用于语音听写。会触发 macOS 原生 Fn 行为。"
        case .leftControl: return "作为左 Control 修饰键，配合其它键发 Ctrl 组合。不会触发系统听写。"
        }
    }
}

struct Config: Codable {
    var buttons: [ButtonMapping]
    var voice: ButtonMapping       // usage = -1
    var voiceStartsMic: Bool
    /// 语音键 HID 重映射目标。旧配置没有该字段时解码失败会回落到默认值。
    var voiceMode: VoiceMode = .globe

    // 自定义解码：voiceMode 是新字段，旧 config.json 缺失时回落到 .globe，避免整体解码失败
    // 导致用户已录制的快捷键全部丢失。
    enum CodingKeys: String, CodingKey {
        case buttons, voice, voiceStartsMic, voiceMode
    }
    init(buttons: [ButtonMapping], voice: ButtonMapping, voiceStartsMic: Bool, voiceMode: VoiceMode = .globe) {
        self.buttons = buttons; self.voice = voice
        self.voiceStartsMic = voiceStartsMic; self.voiceMode = voiceMode
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.buttons = try c.decode([ButtonMapping].self, forKey: .buttons)
        self.voice = try c.decode(ButtonMapping.self, forKey: .voice)
        self.voiceStartsMic = try c.decode(Bool.self, forKey: .voiceStartsMic)
        // 兼容旧配置：缺失或无法识别时保持默认 .globe，不破坏已有快捷键
        self.voiceMode = (try? c.decode(VoiceMode.self, forKey: .voiceMode)) ?? .globe
    }

    static let known: [(usage: Int, name: String)] = [
        (0x52, "方向 上"), (0x51, "方向 下"), (0x50, "方向 左"), (0x4F, "方向 右"),
        (0x28, "确认 OK"), (0xF1, "返回 Back"), (0x4A, "主页 Home"),
        (0x65, "菜单 Menu"), (0x35, "TV 键"), (0x66, "电源 Power"),
        (0x80, "音量 +"), (0x81, "音量 −"),
    ]
    // sensible defaults (keycodes) — 开箱即用：方向键、Enter、Esc、Tab、空格
    static let defaultTarget: [Int: (Int,Bool,Bool,Bool,Bool)] = [
        0x52:(0x7E,false,false,false,false),  // ↑
        0x51:(0x7D,false,false,false,false),  // ↓
        0x50:(0x7B,false,false,false,false),  // ←
        0x4F:(0x7C,false,false,false,false),  // →
        0x28:(0x24,false,false,false,false),  // OK → Enter
        0xF1:(0x33,false,false,false,false),  // Back → Delete（按住连续删除）
        0x4A:(KeyNames.kOpenNotes,false,false,false,false),   // Home → 打开备忘录
        0x65:(0x35,false,false,false,false),  // Menu → Esc
        0x66:(KeyNames.kLockScreen,false,false,false,false), // Power → 仅锁屏
        // 0x35 TV 键、0x66 电源、0x80/0x81 音量 ± 保持原键（不拦截）
        // macOS 自带的音量调节和电源弹窗即可用
    ]
    static var defaultConfig: Config {
        let btns = known.map { k -> ButtonMapping in
            if let t = defaultTarget[k.usage] {
                return ButtonMapping(usage: k.usage, name: k.name, keycode: t.0, cmd: t.1, shift: t.2, opt: t.3, ctrl: t.4,
                                     longPressKeycode: k.usage == 0x66 ? KeyNames.kShutdownConfirm
                                                : (k.usage == 0x65 ? KeyNames.kInterrupt : nil))
            }
            return ButtonMapping(usage: k.usage, name: k.name)
        }
        return Config(buttons: btns,
                      voice: ButtonMapping(usage: -1, name: "语音键", keycode: 0x3F, cmd: false),
                      voiceStartsMic: true,
                      voiceMode: .globe)
    }
    mutating func mergeKnown() {
        for k in Config.known {
            if let i = buttons.firstIndex(where: { $0.usage == k.usage }) {
                buttons[i].name = k.name
            } else {
                buttons.append(ButtonMapping(usage: k.usage, name: k.name))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: Config.known.enumerated().map { ($1.usage, $0) })
        buttons.sort { (order[$0.usage] ?? 999) < (order[$1.usage] ?? 999) }
    }
}

final class ConfigStore {
    static let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/MiVibeBoard")
    static let path = (dir as NSString).appendingPathComponent("config.json")
    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config.defaultConfig
        }
        cfg.mergeKnown()
        // 语音键的"按一下发什么键"已不再用 config.voice.keycode 表达——两种模式都走 HID 设备层
        // 重映射。这里只保证 voice 条目存在且 usage=-1，voiceMode 由用户在 UI 选择并保留。
        cfg.voice = ButtonMapping(usage: -1, name: "语音键", keycode: 0x3F, cmd: false)
        // Upgrade original defaults created before the Mac-only control scheme.
        // This runs once per install so later user changes in the mapping UI stay intact.
        let defaultsVersionKey = "mappingDefaultsVersion"
        if UserDefaults.standard.integer(forKey: defaultsVersionKey) < 6 {
            func installDefault(_ usage: Int, keycode: Int, cmd: Bool = false, longPress: Int? = nil) {
                guard let i = cfg.buttons.firstIndex(where: { $0.usage == usage }) else { return }
                cfg.buttons[i].keycode = keycode
                cfg.buttons[i].cmd = cmd
                cfg.buttons[i].shift = false
                cfg.buttons[i].opt = false
                cfg.buttons[i].ctrl = false
                cfg.buttons[i].longPressKeycode = longPress
            }
            installDefault(0xF1, keycode: 0x33)                         // Back → Delete
            installDefault(0x4A, keycode: KeyNames.kOpenNotes)          // Home → 打开备忘录（短按即打开）
            installDefault(0x65, keycode: 0x35, longPress: KeyNames.kInterrupt) // Menu → Esc / ⌃C
            installDefault(0x66, keycode: KeyNames.kLockScreen, longPress: KeyNames.kShutdownConfirm)
            // v6：Home 改为短按直接打开备忘录（原来短按是 ⌘V 粘贴）。
            UserDefaults.standard.set(6, forKey: defaultsVersionKey)
            save(cfg)
        }
        // Keep the original Menu → Esc default usable for configurations saved
        // before long-press support was introduced.
        if let menu = cfg.buttons.firstIndex(where: { $0.usage == 0x65 }),
           cfg.buttons[menu].keycode == 0x35,
           cfg.buttons[menu].longPressKeycode == nil {
            cfg.buttons[menu].longPressKeycode = KeyNames.kInterrupt
        }
        return cfg
    }
    static func save(_ cfg: Config) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

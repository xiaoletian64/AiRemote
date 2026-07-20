import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Maps the Xiaomi remote's native voice-key HID event (keyboard F5) to one of
/// two targets, depending on the user's chosen VoiceMode:
///   - .globe       → Apple top-case Globe/Fn (系统听写原语，微信输入法等可识别)
///   - .leftControl → Keyboard LeftControl (作为左 Control 修饰键，不触发系统听写)
///
/// Unlike a CGEvent, this is processed by macOS as a real HID modifier, so it
/// is accepted by input methods that ignore synthetic key events.
///
/// The mapping targets the Xiaomi remote keyboard service (VID 0x2717), with
/// known remote product IDs and vendor-name variants accepted. Existing
/// mappings for every other key are retained and the original F5 mapping is
/// restored when the app exits.
final class VoiceGlobeMapper {
    private static let mappingProperty = "UserKeyMapping" as CFString
    private static let voiceF5Usage: UInt64 = 0x0000_0007_0000_003E
    private static let appleGlobeUsage: UInt64 = 0x0000_00FF_0000_0003
    // Keyboard/Keypad page (0x07), LeftControl usage (0xE0)
    private static let leftControlUsage: UInt64 = 0x0000_0007_0000_00E0

    private struct Mapping {
        let source: UInt64
        let destination: UInt64

        init(source: UInt64, destination: UInt64) {
            self.source = source
            self.destination = destination
        }

        init?(property: [String: NSNumber]) {
            guard let source = property["HIDKeyboardModifierMappingSrc"],
                  let destination = property["HIDKeyboardModifierMappingDst"]
            else { return nil }
            self.source = source.uint64Value
            self.destination = destination.uint64Value
        }

        var property: [String: NSNumber] {
            [
                "HIDKeyboardModifierMappingSrc": NSNumber(value: source),
                "HIDKeyboardModifierMappingDst": NSNumber(value: destination),
            ]
        }
    }

    private struct Original {
        /// `nil` is meaningful here: F5 had no mapping before this launch.
        let mapping: Mapping?
    }

    /// The one F5 mapping that existed before this launch, keyed by service.
    private var originals: [UInt64: Original] = [:]
    private(set) var isApplied = false

    @discardableResult
    func apply(_ mode: VoiceMode = .globe) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var matched = 0
        var applied = 0
        let destination: UInt64 = (mode == .leftControl) ? Self.leftControlUsage : Self.appleGlobeUsage

        for service in services where isVoiceRemote(service) {
            matched += 1
            guard let id = registryID(service) else { continue }
            let current = readMappings(service)
            // 仅在首次记录"应用前"的 F5 原始映射；切换模式重入时不清空它，保证退出时能恢复。
            if originals[id] == nil {
                originals[id] = Original(mapping: current.first { $0.source == Self.voiceF5Usage })
            }
            // 先移除我们之前可能写入的目标（避免 Globe/LeftControl 残留），再写入当前模式目标。
            let pruned = current.filter {
                $0.source != Self.voiceF5Usage && $0.destination != destination
            } + [Mapping(source: Self.voiceF5Usage, destination: destination)]
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                pruned.map { $0.property } as CFArray
            ) {
                applied += 1
            }
        }
        isApplied = applied > 0
        return isApplied
    }

    func restore() {
        guard !originals.isEmpty else { isApplied = false; return }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        for service in services where isVoiceRemote(service) {
            guard let id = registryID(service), let original = originals[id] else { continue }
            let current = readMappings(service).filter { $0.source != Self.voiceF5Usage }
            let restored = original.mapping.map { current + [$0] } ?? current
            _ = IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                restored.map { $0.property } as CFArray
            )
        }
        originals.removeAll()
        isApplied = false
    }

    /// 判断 HID 服务是否来自"语音遥控器"。不再锁死小米 VID：联想 XiaoxinM2Pro（VID 0x17EF）
    /// 等其它厂商的语音遥控器也走同一套 ATVV/F5 机制，需要同等对待。
    /// 安全性由调用方保证：只对匹配设备写 F5 重映射，不影响其它键盘。
    private func isVoiceRemote(_ service: IOHIDServiceClient) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber
        let name = (IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
        // 已知语音遥控器厂商 VID
        let knownVendors: Set<Int> = [
            0x2717,   // 小米（RC003 / Remote 2 Pro 等）
            0x17EF,   // 联想（XiaoxinM2Pro BT 等）
        ]
        // 已知产品名关键字（兜底：VID 不在表里但名字像遥控器）
        let nameKeywords = ["遥控", "remote", "mitv", "mi tv", "xiaomi tv", "xiaoxin", "m2pro", "aibao", "语音"]
        if let v = vendor?.intValue, knownVendors.contains(v) { return true }
        if let p = product?.intValue, p == 0x32B8 { return true }   // 小米 RC003 PID
        return nameKeywords.contains { name.contains($0) }
    }

    private func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private func readMappings(_ service: IOHIDServiceClient) -> [Mapping] {
        let raw = IOHIDServiceClientCopyProperty(service, Self.mappingProperty) as? [[String: NSNumber]] ?? []
        return raw.compactMap(Mapping.init(property:))
    }
}

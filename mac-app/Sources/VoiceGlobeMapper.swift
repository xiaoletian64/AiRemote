import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Maps the Xiaomi remote's native voice-key HID event (keyboard F5) to the
/// Apple top-case Globe/Fn usage.  Unlike a CGEvent, this is processed by macOS
/// as a real HID modifier and is therefore accepted by input methods such as
/// WeChat IME.
///
/// The mapping is restricted to Xiaomi VID 0x2717 / PID 0x32B8.  Existing
/// mappings for every other key are retained and the original F5 mapping is
/// restored when the app exits.
final class VoiceGlobeMapper {
    private static let mappingProperty = "UserKeyMapping" as CFString
    private static let voiceF5Usage: UInt64 = 0x0000_0007_0000_003E
    private static let appleGlobeUsage: UInt64 = 0x0000_00FF_0000_0003

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
    func apply() -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var matched = 0
        var applied = 0

        for service in services where isXiaomiRemote(service) {
            matched += 1
            guard let id = registryID(service) else { continue }
            let current = readMappings(service)
            if originals[id] == nil {
                originals[id] = Original(mapping: current.first { $0.source == Self.voiceF5Usage })
            }
            let desired = current.filter { $0.source != Self.voiceF5Usage } + [
                Mapping(source: Self.voiceF5Usage, destination: Self.appleGlobeUsage)
            ]
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                desired.map { $0.property } as CFArray
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
        for service in services where isXiaomiRemote(service) {
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

    private func isXiaomiRemote(_ service: IOHIDServiceClient) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber
        guard vendor?.intValue == 0x2717 else { return false }
        // RC003 / Remote 2 Pro is 0x32B8. Other Xiaomi BLE remotes have varied
        // product IDs, but advertise a remote-shaped product name. Keep the
        // established PID as a fallback for firmware that omits Product text.
        if product?.intValue == 0x32B8 { return true }
        let name = (IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
        return ["遥控", "remote", "mitv", "mi tv", "xiaomi tv"].contains { name.contains($0) }
    }

    private func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private func readMappings(_ service: IOHIDServiceClient) -> [Mapping] {
        let raw = IOHIDServiceClientCopyProperty(service, Self.mappingProperty) as? [[String: NSNumber]] ?? []
        return raw.compactMap(Mapping.init(property:))
    }
}

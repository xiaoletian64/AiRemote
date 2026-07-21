import Foundation

enum RemoteDeviceFilter {
    static let supportedVIDs: Set<Int> = [0x2717, 0x17EF]
    static func isEligible(vid: Int, pid: Int, product: String) -> Bool {
        guard supportedVIDs.contains(vid) else { return false }
        let name = product.lowercased()
        return ["遥控", "remote", "xiaomi", "mi tv", "mitv", "xiaoxin", "m2pro", "aibao", "语音"]
            .contains { name.contains($0) }
    }
}

struct BackHoldEvidence {
    private(set) var firstDownAt: TimeInterval?
    private(set) var reportCount = 0
    mutating func observeDown(at time: TimeInterval) {
        if firstDownAt == nil { firstDownAt = time }
        reportCount += 1
    }
    var isReady: Bool { reportCount >= 3 }
    func isConfirmed(at time: TimeInterval) -> Bool {
        guard let firstDownAt else { return false }
        return isReady && time - firstDownAt >= 0.4
    }
    mutating func reset() { firstDownAt = nil; reportCount = 0 }
}

struct RingScrollEvent: Equatable {
    let lines: Int32
}

struct RingScrollDecoder {
    private let minimumFrames = 3
    private let maxFrameGap: TimeInterval = 0.08
    private let idleReset: TimeInterval = 5.0
    private var axis: Int?
    private var sign: Int?
    private var frames = 0
    private var lastAt: TimeInterval?

    mutating func reset() {
        axis = nil; sign = nil; frames = 0; lastAt = nil
    }

    mutating func consume(_ bytes: [UInt8], at time: TimeInterval) -> RingScrollEvent? {
        guard bytes.count == 7, bytes[0] == 0x03 else { return nil }
        // 空闲超时复位（5s 无帧视为新一轮校准）
        if let last = lastAt, time - last > idleReset { reset() }

        // 解析三个候选字节位（X / Y / wheel）为有符号值，挑绝对值最大的作为本轮主导位移
        let values = [
            Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)),
            Int(Int16(bitPattern: UInt16(bytes[4]) | UInt16(bytes[5]) << 8)),
            Int(Int8(bitPattern: bytes[6]))
        ]
        guard let candidate = values.enumerated().max(by: { abs($0.element) < abs($1.element) }),
              abs(candidate.element) > 0 else {
            lastAt = time   // 全零帧也更新时间，避免 idleReset 误判
            return nil
        }
        let candidateAxis = candidate.offset
        let candidateSign = candidate.element < 0 ? -1 : 1

        // 帧间隔超过 80ms 视为序列中断，重置计数（保留当前帧作为新序列首帧）
        if let last = lastAt, time - last > maxFrameGap {
            axis = candidateAxis; sign = candidateSign; frames = 1
            lastAt = time
            return nil
        }
        lastAt = time

        // 同一字节位、同一方向才累计；否则切换为新序列首帧
        if axis == candidateAxis && sign == candidateSign {
            frames += 1
        } else {
            axis = candidateAxis; sign = candidateSign; frames = 1
        }
        // 连续 ≥3 帧稳定才发滚动；每次最多 6 行，避免页面失控
        guard frames >= minimumFrames else { return nil }
        return RingScrollEvent(lines: Int32(candidateSign * min(6, max(1, abs(candidate.element)))))
    }
}

/// A fixed-size, zero-overhead byte buffer. Emulation hot paths index raw pointers
/// instead of Swift arrays so there are no bounds, uniqueness or exclusivity checks.
public final class ByteBuffer {
    public let pointer: UnsafeMutablePointer<UInt8>
    public let count: Int

    public init(count: Int, fill: UInt8 = 0) {
        self.count = count
        pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(count, 1))
        pointer.initialize(repeating: fill, count: max(count, 1))
    }

    public convenience init<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        self.init(count: bytes.count)
        var i = 0
        for b in bytes { pointer[i] = b; i += 1 }
    }

    deinit { pointer.deallocate() }

    @inline(__always) public subscript(i: Int) -> UInt8 {
        get { pointer[i] }
        set { pointer[i] = newValue }
    }

    public func fill(_ value: UInt8) {
        pointer.update(repeating: value, count: count)
    }

    public var bytes: [UInt8] { Array(UnsafeBufferPointer(start: pointer, count: count)) }

    public func copy(from source: UnsafePointer<UInt8>, count n: Int) {
        pointer.update(from: source, count: min(n, count))
    }
}

/// Power-on contents of work RAM. Real hardware is effectively random; deterministic
/// patterns keep replays, netplay and achievements reproducible.
public enum RAMInitPattern: UInt8, Sendable, CaseIterable {
    case zeros = 0
    case ones = 1
    case alternating = 2   // $00 x4, $FF x4, a common power-on pattern
    case random = 3
}

extension ByteBuffer {
    func initialize(pattern: RAMInitPattern, seed: UInt64 = 0x5EED_1234_ABCD_0001) {
        switch pattern {
        case .zeros: fill(0)
        case .ones: fill(0xFF)
        case .alternating:
            for i in 0..<count { pointer[i] = (i & 4) == 0 ? 0x00 : 0xFF }
        case .random:
            var s = seed
            for i in 0..<count {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17
                pointer[i] = UInt8(truncatingIfNeeded: s)
            }
        }
    }
}

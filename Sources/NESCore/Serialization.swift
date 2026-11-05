/// Errors raised when restoring a save state.
public enum StateError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(UInt32)
    case wrongGame
    case truncated
    case corrupt(String)

    public var description: String {
        switch self {
        case .badMagic: return "Not a Bismuth save state"
        case .unsupportedVersion(let v): return "Unsupported save state version \(v)"
        case .wrongGame: return "Save state belongs to a different game"
        case .truncated: return "Save state is truncated"
        case .corrupt(let what): return "Save state is corrupt (\(what))"
        }
    }
}

/// Little-endian binary writer used for save states.
public struct StateWriter {
    public private(set) var data: [UInt8] = []

    public init(capacity: Int = 64 * 1024) { data.reserveCapacity(capacity) }

    public mutating func write(_ v: UInt8) { data.append(v) }
    public mutating func write(_ v: Bool) { data.append(v ? 1 : 0) }
    public mutating func write(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    public mutating func write(_ v: UInt32) {
        for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
    }
    public mutating func write(_ v: UInt64) {
        for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }
    public mutating func write(_ v: Int) { write(UInt64(bitPattern: Int64(v))) }
    public mutating func write(_ buffer: ByteBuffer) {
        write(UInt32(buffer.count))
        data.append(contentsOf: UnsafeBufferPointer(start: buffer.pointer, count: buffer.count))
    }
    public mutating func write(bytes: UnsafePointer<UInt8>, count: Int) {
        write(UInt32(count))
        data.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
    }
    public mutating func write(_ values: [Int]) {
        write(UInt32(values.count))
        for v in values { write(v) }
    }
}

/// Little-endian binary reader used for save states.
public struct StateReader {
    let data: [UInt8]
    public private(set) var offset = 0

    public init(_ data: [UInt8]) { self.data = data }

    mutating func skip(_ n: Int) { offset = min(offset + n, data.count) }

    @inline(__always) mutating func need(_ n: Int) throws {
        if offset + n > data.count { throw StateError.truncated }
    }

    public mutating func readU8() throws -> UInt8 {
        try need(1); defer { offset += 1 }; return data[offset]
    }
    public mutating func readBool() throws -> Bool { try readU8() != 0 }
    public mutating func readU16() throws -> UInt16 {
        try need(2); defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    public mutating func readU32() throws -> UInt32 {
        try need(4); defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        return v
    }
    public mutating func readU64() throws -> UInt64 {
        try need(8); defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
        return v
    }
    public mutating func readInt() throws -> Int { Int(Int64(bitPattern: try readU64())) }

    public mutating func read(into buffer: ByteBuffer) throws {
        let n = Int(try readU32())
        guard n == buffer.count else { throw StateError.corrupt("buffer size \(n) != \(buffer.count)") }
        try need(n)
        data.withUnsafeBufferPointer { src in
            buffer.pointer.update(from: src.baseAddress! + offset, count: n)
        }
        offset += n
    }
    public mutating func read(into pointer: UnsafeMutablePointer<UInt8>, count: Int) throws {
        let n = Int(try readU32())
        guard n == count else { throw StateError.corrupt("block size \(n) != \(count)") }
        try need(n)
        data.withUnsafeBufferPointer { src in
            pointer.update(from: src.baseAddress! + offset, count: n)
        }
        offset += n
    }
    public mutating func readIntArray() throws -> [Int] {
        let n = Int(try readU32())
        guard n <= 4096 else { throw StateError.corrupt("array length") }
        var out = [Int](); out.reserveCapacity(n)
        for _ in 0..<n { out.append(try readInt()) }
        return out
    }
}

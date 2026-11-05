/// A single decoded cheat.
public struct Cheat: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Substitutes the value the CPU reads (Game Genie style); optional compare byte.
        case readPatch(compare: UInt8?)
        /// Writes the value into RAM every frame (Pro Action Replay style).
        case freeze
    }

    public var address: Int
    public var value: UInt8
    public var kind: Kind

    public init(address: Int, value: UInt8, kind: Kind) {
        self.address = address; self.value = value; self.kind = kind
    }

    public var description: String {
        switch kind {
        case .readPatch(let c?): return format4(address) + "?" + hex2(c) + ":" + hex2(value)
        case .readPatch(nil): return format4(address) + ":" + hex2(value) + " (patch)"
        case .freeze: return format4(address) + ":" + hex2(value)
        }
    }
}

private func format4(_ v: Int) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 4 - s.count)) + s
}
private func hex2(_ v: UInt8) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return s.count < 2 ? "0" + s : s
}

public enum CheatError: Error, Equatable {
    case invalidCode(String)
}

/// Game Genie and raw-address cheats.
public final class CheatEngine {
    public private(set) var cheats: [Cheat] = []
    var patches: [Int: (value: UInt8, compare: Int)] = [:]   // compare -1 = unconditional

    public init() {}

    public var isEmpty: Bool { cheats.isEmpty }

    /// Adds one or more codes separated by `+`, `,`, `;` or whitespace.
    /// Accepts 6/8-letter Game Genie codes, `AAAA:VV`, `AAAA?CC:VV` and `AAAA:VV:CC`.
    public func add(_ codes: String) throws {
        let parts = codes.split(whereSeparator: { "+,; \n\t".contains($0) }).map(String.init)
        var decoded = [Cheat]()
        for part in parts where !part.isEmpty {
            guard let cheat = CheatEngine.decode(part) else { throw CheatError.invalidCode(part) }
            decoded.append(cheat)
        }
        cheats += decoded
        rebuild()
    }

    public func removeAll() {
        cheats.removeAll()
        rebuild()
    }

    func rebuild() {
        patches.removeAll()
        for c in cheats {
            if case .readPatch(let compare) = c.kind {
                patches[c.address] = (c.value, compare.map { Int($0) } ?? -1)
            }
        }
    }

    @inline(__always)
    func patch(address: Int, value: UInt8) -> UInt8 {
        guard let p = patches[address] else { return value }
        if p.compare < 0 || Int(value) == p.compare { return p.value }
        return value
    }

    var freezes: [Cheat] { cheats.filter { $0.kind == .freeze } }

    public static func decode(_ raw: String) -> Cheat? {
        let code = raw.uppercased()
        if code.count == 6 || code.count == 8, code.allSatisfy({ gameGenieLetters.contains($0) }) {
            return decodeGameGenie(code)
        }
        // AAAA?CC:VV
        if let q = code.firstIndex(of: "?"), let colon = code.firstIndex(of: ":"), q < colon {
            guard let addr = Int(code[code.startIndex..<q], radix: 16),
                  let cmp = UInt8(code[code.index(after: q)..<colon], radix: 16),
                  let val = UInt8(code[code.index(after: colon)...], radix: 16) else { return nil }
            return Cheat(address: addr & 0xFFFF, value: val, kind: .readPatch(compare: cmp))
        }
        let fields = code.split(separator: ":")
        if fields.count == 2 || fields.count == 3 {
            guard let addr = Int(fields[0], radix: 16), let val = UInt8(fields[1], radix: 16) else { return nil }
            let a = addr & 0xFFFF
            if fields.count == 3 {
                guard let cmp = UInt8(fields[2], radix: 16) else { return nil }
                return Cheat(address: a, value: val, kind: .readPatch(compare: cmp))
            }
            return Cheat(address: a, value: val, kind: a >= 0x8000 ? .readPatch(compare: nil) : .freeze)
        }
        return nil
    }

    static let gameGenieLetters: [Character] = Array("APZLGITYEOXUKSVN")

    public static func decodeGameGenie(_ code: String) -> Cheat? {
        let n = code.uppercased().compactMap { c in gameGenieLetters.firstIndex(of: c) }
        guard n.count == code.count, n.count == 6 || n.count == 8 else { return nil }
        let address = 0x8000 | ((n[3] & 7) << 12) | ((n[5] & 7) << 8) | ((n[4] & 8) << 8)
            | ((n[2] & 7) << 4) | ((n[1] & 8) << 4) | (n[4] & 7) | (n[3] & 8)
        if n.count == 6 {
            let value = ((n[1] & 7) << 4) | ((n[0] & 8) << 4) | (n[0] & 7) | (n[5] & 8)
            return Cheat(address: address, value: UInt8(value), kind: .readPatch(compare: nil))
        }
        let value = ((n[1] & 7) << 4) | ((n[0] & 8) << 4) | (n[0] & 7) | (n[7] & 8)
        let compare = ((n[7] & 7) << 4) | ((n[6] & 8) << 4) | (n[6] & 7) | (n[5] & 8)
        return Cheat(address: address, value: UInt8(value), kind: .readPatch(compare: UInt8(compare)))
    }
}

@testable import NESCore

/// Builds tiny NROM images for tests: `program` is placed at $C000 (mirrored at $8000).
enum TestROM {
    static func make(program: [UInt8], nmi: [UInt8] = [0x40], irq: [UInt8] = [0x40],
                     chr: [UInt8]? = nil, mapper: Int = 0, prgBanks: Int = 1, mirroring: UInt8 = 1) -> [UInt8] {
        var prg = [UInt8](repeating: 0xEA, count: 16 * 1024 * prgBanks)
        let base = prg.count - 0x4000   // last 16KB maps to $C000
        for (i, b) in program.enumerated() { prg[base + i] = b }
        // NMI handler at $F000, IRQ handler at $F800
        for (i, b) in nmi.enumerated() { prg[base + 0x3000 + i] = b }
        for (i, b) in irq.enumerated() { prg[base + 0x3800 + i] = b }
        let end = prg.count
        prg[end - 6] = 0x00; prg[end - 5] = 0xF0   // NMI  -> $F000
        prg[end - 4] = 0x00; prg[end - 3] = 0xC0   // RESET -> $C000
        prg[end - 2] = 0x00; prg[end - 1] = 0xF8   // IRQ  -> $F800
        let chrData = chr ?? [UInt8](repeating: 0, count: 8192)
        var header: [UInt8] = [0x4E, 0x45, 0x53, 0x1A, UInt8(prgBanks), UInt8(chrData.count / 8192),
                               UInt8((mapper & 0x0F) << 4) | mirroring, UInt8(mapper & 0xF0), 0, 0, 0, 0, 0, 0, 0, 0]
        if chrData.isEmpty { header[5] = 0 }
        return header + prg + chrData
    }

    static func console(_ program: [UInt8], nmi: [UInt8] = [0x40], irq: [UInt8] = [0x40]) throws -> NESConsole {
        try NESConsole(rom: make(program: program, nmi: nmi, irq: irq))
    }
}

extension NESConsole {
    /// Runs until the CPU reaches `address` (or gives up after `limit` instructions).
    @discardableResult
    func run(until address: UInt16, limit: Int = 100_000) -> Bool {
        for _ in 0..<limit {
            if cpu.pc == address { return true }
            cpu.step()
        }
        return false
    }
}

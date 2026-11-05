/// Mapper 4: MMC3 / MMC6 (TxROM, HKROM). Subclassed for TxSROM (118) and TQROM (119).
class MMC3: Mapper {
    var bankSelect = 0
    var regs = [0, 2, 4, 5, 6, 7, 0, 1]
    var irqLatch = 0
    var irqCounter = 0
    var irqReload = false
    var irqEnabled = false
    var lastA12 = false
    var a12LowSince: UInt64 = 0
    /// MMC3A / Sharp revisions: no IRQ when the counter is reloaded with 0.
    var oldIRQBehavior: Bool { cartridge.submapper == 4 }

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        needsPPUAddressNotifications = true
        apply()
    }

    override func reset(hard: Bool) {
        if hard {
            bankSelect = 0
            regs = [0, 2, 4, 5, 6, 7, 0, 1]
            irqLatch = 0; irqCounter = 0; irqReload = false; irqEnabled = false
            irqLine = false
        }
        apply()
    }

    func apply() {
        applyPRG()
        applyCHR()
    }

    func applyPRG() {
        if (bankSelect & 0x40) == 0 {
            setPRG8k(0, regs[6])
            setPRG8k(2, -2)
        } else {
            setPRG8k(0, -2)
            setPRG8k(2, regs[6])
        }
        setPRG8k(1, regs[7])
        setPRG8k(3, -1)
    }

    /// 1KB CHR bank number for each of the eight PPU windows.
    func chrBank(forSlot slot: Int) -> Int {
        let inverted = (bankSelect & 0x80) != 0
        let s = inverted ? slot ^ 4 : slot
        switch s {
        case 0: return regs[0] & 0xFE
        case 1: return regs[0] | 1
        case 2: return regs[1] & 0xFE
        case 3: return regs[1] | 1
        default: return regs[s - 2]
        }
    }

    func applyCHR() {
        for slot in 0..<8 { setCHR1k(slot, chrBank(forSlot: slot)) }
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        let v = Int(value)
        switch (address & 0xE000, address & 1) {
        case (0x8000, 0):
            bankSelect = v
            apply()
        case (0x8000, _):
            regs[bankSelect & 7] = v
            apply()
        case (0xA000, 0):
            writeMirroring(value)
        case (0xA000, _):
            // PRG-RAM protect. Ignored: MMC6 games (StarTropics) use different semantics
            // and no licensed MMC3 game depends on the protection.
            break
        case (0xC000, 0):
            irqLatch = v
        case (0xC000, _):
            irqCounter = 0
            irqReload = true
        case (0xE000, 0):
            irqEnabled = false
            irqLine = false
        default:
            irqEnabled = true
        }
    }

    func writeMirroring(_ value: UInt8) {
        if cartridge.mirroring != .fourScreen {
            setMirroring((value & 1) != 0 ? .horizontal : .vertical)
        }
    }

    override func ppuAddressChanged(_ address: Int, ppuCycle: UInt64) {
        let a12 = (address & 0x1000) != 0
        if a12 {
            if !lastA12 && ppuCycle &- a12LowSince >= 10 { clockIRQ() }
        } else if lastA12 {
            a12LowSince = ppuCycle
        }
        lastA12 = a12
    }

    func clockIRQ() {
        let previous = irqCounter
        if irqCounter == 0 || irqReload {
            irqCounter = irqLatch
        } else {
            irqCounter -= 1
        }
        // Old MMC3A boards only fire when the counter counts down to 0 or was explicitly reloaded.
        if irqCounter == 0 && irqEnabled && (!oldIRQBehavior || previous != 0 || irqReload) {
            irqLine = true
        }
        irqReload = false
    }

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w)
        w.write(regs)
        w.write([bankSelect, irqLatch, irqCounter])
        w.write(irqReload); w.write(irqEnabled); w.write(lastA12); w.write(a12LowSince)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        regs = try r.readIntArray()
        let v = try r.readIntArray()
        guard regs.count == 8, v.count == 3 else { throw StateError.corrupt("MMC3") }
        bankSelect = v[0]; irqLatch = v[1]; irqCounter = v[2]
        irqReload = try r.readBool(); irqEnabled = try r.readBool(); lastA12 = try r.readBool()
        a12LowSince = try r.readU64()
    }
}

/// Mapper 118: TxSROM: nametables are selected by bit 7 of the CHR bank registers.
final class TxSROM: MMC3 {
    override func applyCHR() {
        super.applyCHR()
        let inverted = (bankSelect & 0x80) != 0
        if inverted {
            for i in 0..<4 { setNametable(i, page: (regs[2 + i] >> 7) & 1) }
        } else {
            setNametable(0, page: (regs[0] >> 7) & 1)
            setNametable(1, page: (regs[0] >> 7) & 1)
            setNametable(2, page: (regs[1] >> 7) & 1)
            setNametable(3, page: (regs[1] >> 7) & 1)
        }
    }

    override func writeMirroring(_ value: UInt8) {}
}

/// Mapper 119: TQROM: CHR banks with bit 6 set address 8KB of CHR-RAM.
final class TQROM: MMC3 {
    let chrRAM = ByteBuffer(count: 0x2000)
    var useRAM = [Bool](repeating: false, count: 8)
    var ramOffsets = [Int](repeating: 0, count: 8)

    override func applyCHR() {
        super.applyCHR()
        for slot in 0..<8 {
            let bank = chrBank(forSlot: slot)
            useRAM[slot] = (bank & 0x40) != 0
            ramOffsets[slot] = (bank & 0x07) * 0x400
        }
    }

    override func readPPU(_ address: Int) -> UInt8 {
        if address < 0x2000 {
            let slot = address >> 10
            if useRAM[slot] { return chrRAM[ramOffsets[slot] + (address & 0x3FF)] }
        }
        return super.readPPU(address)
    }

    override func writePPU(_ address: Int, _ value: UInt8) {
        if address < 0x2000 {
            let slot = address >> 10
            if useRAM[slot] { chrRAM[ramOffsets[slot] + (address & 0x3FF)] = value }
            return
        }
        super.writePPU(address, value)
    }

    override func saveState(_ w: inout StateWriter) { super.saveState(&w); w.write(chrRAM) }
    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r); try r.read(into: chrRAM); applyCHR()
    }
}

/// Mapper 1: MMC1 (SxROM: SNROM, SOROM, SUROM, SXROM...).
final class MMC1: Mapper {
    var shift = 0
    var shiftCount = 0
    var control = 0x0C
    var chr0 = 0, chr1 = 0, prgReg = 0
    var lastWriteCycle: UInt64 = .max

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        apply()
    }

    override func reset(hard: Bool) {
        shift = 0; shiftCount = 0
        control |= 0x0C
        if hard { chr0 = 0; chr1 = 0; prgReg = 0 }
        apply()
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        // The MMC1 ignores writes on consecutive CPU cycles (RMW instructions; Bill & Ted relies on it).
        let cycle = cpuCycle()
        defer { lastWriteCycle = cycle }
        if lastWriteCycle != .max && cycle == lastWriteCycle &+ 1 { return }

        if (value & 0x80) != 0 {
            shift = 0; shiftCount = 0
            control |= 0x0C
            apply()
            return
        }
        shift |= Int(value & 1) << shiftCount
        shiftCount += 1
        guard shiftCount == 5 else { return }
        let v = shift
        shift = 0; shiftCount = 0
        switch address & 0xE000 {
        case 0x8000: control = v
        case 0xA000: chr0 = v
        case 0xC000: chr1 = v
        default: prgReg = v
        }
        apply()
    }

    func apply() {
        if cartridge.mirroring != .fourScreen {
            switch control & 0x03 {
            case 0: setMirroring(.singleScreenA)
            case 1: setMirroring(.singleScreenB)
            case 2: setMirroring(.vertical)
            default: setMirroring(.horizontal)
            }
        }

        // SUROM/SXROM: CHR bit 4 selects the 256KB PRG half.
        let outer = prg.count > 256 * 1024 ? (chr0 & 0x10) : 0
        let bank = (prgReg & 0x0F) | outer
        switch (control >> 2) & 0x03 {
        case 0, 1:
            setPRG32k((bank & ~1) >> 1)
        case 2:
            setPRG16k(0, outer)
            setPRG16k(1, bank)
        default:
            setPRG16k(0, bank)
            setPRG16k(1, (outer | 0x0F))
        }

        if (control & 0x10) != 0 {
            setCHR4k(0, chr0)
            setCHR4k(1, chr1)
        } else {
            setCHR8k(chr0 >> 1)
        }

        // SOROM/SXROM PRG-RAM banking through the CHR register.
        if prgRAM.count >= 0x8000 {
            setPRGRAM8k((chr0 >> 2) & 0x03)
        } else if prgRAM.count >= 0x4000 {
            setPRGRAM8k((chr0 >> 3) & 0x01)
        }
        // MMC1B+: bit 4 of the PRG register disables PRG-RAM.
        prgRAMEnabled = (prgReg & 0x10) == 0 || cartridge.submapper == 5
    }

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w)
        w.write([shift, shiftCount, control, chr0, chr1, prgReg])
        w.write(lastWriteCycle)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        let v = try r.readIntArray()
        guard v.count == 6 else { throw StateError.corrupt("MMC1") }
        shift = v[0]; shiftCount = v[1]; control = v[2]; chr0 = v[3]; chr1 = v[4]; prgReg = v[5]
        lastWriteCycle = try r.readU64()
    }
}

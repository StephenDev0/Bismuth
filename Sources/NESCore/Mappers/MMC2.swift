/// Mapper 9 (MMC2, PxROM: Punch-Out!!) and mapper 10 (MMC4, FxROM).
/// CHR banks are switched by latches that trip when the PPU fetches tiles $FD / $FE.
final class MMC2: Mapper {
    var isMMC4: Bool { cartridge.mapperID == 10 }
    var chrRegs = [0, 0, 0, 0]   // $0000 FD, $0000 FE, $1000 FD, $1000 FE
    var latch0 = 1, latch1 = 1   // 0 = FD, 1 = FE

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        if isMMC4 {
            setPRG16k(0, 0)
            setPRG16k(1, -1)
        } else {
            setPRG8k(0, 0)
            setPRG8k(1, -3)
            setPRG8k(2, -2)
            setPRG8k(3, -1)
        }
        applyCHR()
    }

    func applyCHR() {
        setCHR4k(0, chrRegs[latch0])
        setCHR4k(1, chrRegs[2 + latch1])
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        let v = Int(value & 0x1F)
        switch address & 0xF000 {
        case 0xA000:
            if isMMC4 { setPRG16k(0, Int(value & 0x0F)) } else { setPRG8k(0, Int(value & 0x0F)) }
        case 0xB000: chrRegs[0] = v; applyCHR()
        case 0xC000: chrRegs[1] = v; applyCHR()
        case 0xD000: chrRegs[2] = v; applyCHR()
        case 0xE000: chrRegs[3] = v; applyCHR()
        case 0xF000:
            if cartridge.mirroring != .fourScreen { setMirroring((value & 1) != 0 ? .horizontal : .vertical) }
        default: break
        }
    }

    override func readPPU(_ address: Int) -> UInt8 {
        let value = super.readPPU(address)
        if address < 0x2000 {
            // The bank switch takes effect after the triggering fetch.
            if address < 0x1000 {
                if isMMC4 {
                    if (address & 0xFFF8) == 0x0FD8 { latch0 = 0; applyCHR() }
                    else if (address & 0xFFF8) == 0x0FE8 { latch0 = 1; applyCHR() }
                } else {
                    if address == 0x0FD8 { latch0 = 0; applyCHR() }
                    else if address == 0x0FE8 { latch0 = 1; applyCHR() }
                }
            } else {
                if (address & 0xFFF8) == 0x1FD8 { latch1 = 0; applyCHR() }
                else if (address & 0xFFF8) == 0x1FE8 { latch1 = 1; applyCHR() }
            }
        }
        return value
    }

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w); w.write(chrRegs); w.write(latch0); w.write(latch1)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        chrRegs = try r.readIntArray()
        guard chrRegs.count == 4 else { throw StateError.corrupt("MMC2") }
        latch0 = try r.readInt() & 1; latch1 = try r.readInt() & 1
    }
}

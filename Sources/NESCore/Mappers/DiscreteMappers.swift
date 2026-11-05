// Discrete-logic boards: a latch or two and nothing else.

/// Mapper 0: NROM.
final class NROM: Mapper {
    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        setPRG16k(0, 0)
        setPRG16k(1, -1)
        setCHR8k(0)
    }
}

/// Mapper 2: UxROM (UNROM/UOROM). Also mapper 94 (UN1ROM) and 180 (UNROM, fixed first bank).
final class UxROM: Mapper {
    var bank = 0

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        apply()
    }

    func apply() {
        switch cartridge.mapperID {
        case 180:
            setPRG16k(0, 0)
            setPRG16k(1, bank)
        default:
            setPRG16k(0, bank)
            setPRG16k(1, -1)
        }
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        var v = value
        if cartridge.submapper == 2 { v &= readPRG(address) }   // bus conflicts
        bank = cartridge.mapperID == 94 ? Int(v >> 2) & 0x07 : Int(v)
        apply()
    }

    override func saveState(_ w: inout StateWriter) { super.saveState(&w); w.write(bank) }
    override func loadState(_ r: inout StateReader) throws { try super.loadState(&r); bank = try r.readInt() }
}

/// Mapper 3: CNROM (also 185 without copy protection checks).
final class CNROM: Mapper {
    override func writeRegister(_ address: Int, _ value: UInt8) {
        var v = value
        if cartridge.submapper == 2 { v &= readPRG(address) }
        setCHR8k(Int(v))
    }
}

/// Mapper 7: AxROM.
final class AxROM: Mapper {
    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        setMirroring(.singleScreenA)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        setPRG32k(Int(value & 0x0F))
        setMirroring((value & 0x10) != 0 ? .singleScreenB : .singleScreenA)
    }
}

/// Mapper 34: BNROM and NINA-001 (distinguished by CHR size).
final class BNROM: Mapper {
    var isNINA: Bool { cartridge.chr.count > 0x2000 }

    override func writeCPU(_ address: Int, _ value: UInt8) {
        if isNINA {
            switch address {
            case 0x7FFD: setPRG32k(Int(value & 1))
            case 0x7FFE: setCHR4k(0, Int(value & 0x0F))
            case 0x7FFF: setCHR4k(1, Int(value & 0x0F))
            default: break
            }
            if address >= 0x6000 && address < 0x8000 { writeRAM(address, value) }
        } else if address >= 0x8000 {
            setPRG32k(Int(value))
        } else if address >= 0x6000 {
            writeRAM(address, value)
        }
    }
}

/// Mapper 66: GxROM / MxROM.
final class GxROM: Mapper {
    override func writeRegister(_ address: Int, _ value: UInt8) {
        setPRG32k(Int(value >> 4) & 0x03)
        setCHR8k(Int(value & 0x03))
    }
}

/// Mapper 11: Color Dreams.
final class ColorDreams: Mapper {
    override func writeRegister(_ address: Int, _ value: UInt8) {
        setPRG32k(Int(value & 0x03))
        setCHR8k(Int(value >> 4))
    }
}

/// Mapper 13: CPROM (16KB CHR-RAM, upper 4KB switchable).
final class CPROM: Mapper {
    override class var minimumCHRRAM: Int { 0x4000 }

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        setCHR4k(0, 0)
        setCHR4k(1, 0)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        setCHR4k(1, Int(value & 0x03))
    }
}

/// Mapper 71: Camerica / Codemasters BF909x.
final class Camerica: Mapper {
    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        setPRG16k(0, 0)
        setPRG16k(1, -1)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        if address >= 0xC000 {
            setPRG16k(0, Int(value))
        } else if address >= 0x9000 && address < 0xA000 {
            // Fire Hawk: one-screen mirroring control.
            setMirroring((value & 0x10) != 0 ? .singleScreenB : .singleScreenA)
        }
    }
}

/// Mapper 79 / 113: NINA-003/006 (AVE). Registers live at $4100-$5FFF.
final class NINA03: Mapper {
    override func writeLow(_ address: Int, _ value: UInt8) {
        guard (address & 0xE100) == 0x4100 else { return }
        if cartridge.mapperID == 113 {
            setPRG32k(Int(value >> 3) & 0x07)
            setCHR8k(Int(value & 0x07) | Int(value >> 3) & 0x08)
            setMirroring((value & 0x80) != 0 ? .vertical : .horizontal)
        } else {
            setPRG32k(Int(value >> 3) & 0x01)
            setCHR8k(Int(value & 0x07))
        }
    }
}

/// Mapper 87: Jaleco/Konami CHR latch at $6000-$7FFF.
final class Mapper87: Mapper {
    override class var alwaysHasPRGRAM: Bool { false }

    override func writeCPU(_ address: Int, _ value: UInt8) {
        if address >= 0x6000 && address < 0x8000 {
            setCHR8k(Int((value & 1) << 1 | (value >> 1) & 1))
        }
    }

    override func readCPU(_ address: Int, openBus: UInt8) -> UInt8 {
        address >= 0x8000 ? readPRG(address) : openBus
    }
}

/// Mapper 140: Jaleco JF-11/JF-14.
final class Mapper140: Mapper {
    override class var alwaysHasPRGRAM: Bool { false }

    override func writeCPU(_ address: Int, _ value: UInt8) {
        if address >= 0x6000 && address < 0x8000 {
            setPRG32k(Int(value >> 4) & 0x03)
            setCHR8k(Int(value & 0x0F))
        }
    }

    override func readCPU(_ address: Int, openBus: UInt8) -> UInt8 {
        address >= 0x8000 ? readPRG(address) : openBus
    }
}

/// Mapper 232: Camerica Quattro multicarts.
final class Quattro: Mapper {
    var block = 0, page = 0

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        apply()
    }

    func apply() {
        setPRG16k(0, block * 4 + page)
        setPRG16k(1, block * 4 + 3)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        if address < 0xC000 {
            block = Int(value >> 3) & 0x03
        } else {
            page = Int(value & 0x03)
        }
        apply()
    }

    override func saveState(_ w: inout StateWriter) { super.saveState(&w); w.write(block); w.write(page) }
    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r); block = try r.readInt(); page = try r.readInt()
    }
}

/// Mapper 75: Konami VRC1.
final class VRC1: Mapper {
    var chrLow = [0, 0], chrHigh = [0, 0]

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        setPRG8k(3, -1)
    }

    func applyCHR() {
        setCHR4k(0, chrHigh[0] << 4 | chrLow[0])
        setCHR4k(1, chrHigh[1] << 4 | chrLow[1])
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        let v = Int(value)
        switch address & 0xF000 {
        case 0x8000: setPRG8k(0, v & 0x0F)
        case 0x9000:
            if cartridge.mirroring != .fourScreen { setMirroring((v & 1) != 0 ? .horizontal : .vertical) }
            chrHigh[0] = (v >> 1) & 1
            chrHigh[1] = (v >> 2) & 1
            applyCHR()
        case 0xA000: setPRG8k(1, v & 0x0F)
        case 0xC000: setPRG8k(2, v & 0x0F)
        case 0xE000: chrLow[0] = v & 0x0F; applyCHR()
        case 0xF000: chrLow[1] = v & 0x0F; applyCHR()
        default: break
        }
    }

    override func saveState(_ w: inout StateWriter) { super.saveState(&w); w.write(chrLow); w.write(chrHigh) }
    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r); chrLow = try r.readIntArray(); chrHigh = try r.readIntArray()
        guard chrLow.count == 2, chrHigh.count == 2 else { throw StateError.corrupt("VRC1") }
    }
}

/// Mapper 206: Namco 108 / DxROM (MMC3 predecessor without IRQ or mirroring control).
final class Namco108: Mapper {
    var select = 0
    var regs = [Int](repeating: 0, count: 8)

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        apply()
    }

    func apply() {
        setCHR2k(0, regs[0] >> 1)
        setCHR2k(1, regs[1] >> 1)
        for i in 0..<4 { setCHR1k(4 + i, regs[2 + i]) }
        setPRG8k(0, regs[6] & 0x0F)
        setPRG8k(1, regs[7] & 0x0F)
        setPRG8k(2, -2)
        setPRG8k(3, -1)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        guard address < 0xA000 else { return }
        if (address & 1) == 0 {
            select = Int(value & 0x07)
        } else {
            regs[select] = Int(value & 0x3F)
            apply()
        }
    }

    override func saveState(_ w: inout StateWriter) { super.saveState(&w); w.write(select); w.write(regs) }
    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r); select = try r.readInt(); regs = try r.readIntArray()
        guard regs.count == 8 else { throw StateError.corrupt("Namco108") }
    }
}

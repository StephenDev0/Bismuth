/// Mapper 5: Nintendo MMC5 (ExROM: Castlevania III, Just Breed, Uncharted Waters, Koei titles).
final class MMC5: Mapper {
    var prgMode = 3
    var chrMode = 3
    var ramProtect1 = 0, ramProtect2 = 0
    var exRAMMode = 0
    var ntMapping = 0
    var fillTile = 0, fillAttribute = 0
    var prgRegs = [0, 0, 0, 0, 0xFF]     // $5113-$5117
    var chrA = [Int](repeating: 0, count: 8)   // $5120-$5127
    var chrB = [Int](repeating: 0, count: 4)   // $5128-$512B
    var chrUpper = 0
    var lastCHRWriteB = false
    var irqCompare = 0
    var irqEnabled = false
    var irqPending = false
    var inFrame = false
    var scanlineCounter = 0
    var multiplicand = 0xFF, multiplier = 0xFF
    let exRAM = ByteBuffer(count: 0x400)

    // Scanline detection
    var lastPPUAddress = -1
    var matchCount = 0
    var idleCycles = 0
    var lastExAttribute = 0

    // PRG windows: each 8KB slot points into ROM or RAM.
    var slotIsRAM = [false, false, false, false, false]   // $6000, $8000, $A000, $C000, $E000
    var slotOffset = [0, 0, 0, 0, 0]

    // Audio: two pulses (no sweep) and raw PCM.
    var pulse1 = PulseChannel(isFirst: false)
    var pulse2 = PulseChannel(isFirst: false)
    var pcm = 0
    var frameDivider = 0

    override class var minimumCHRRAM: Int { 0x2000 }

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        needsCPUClock = true
        hasExpansionAudio = true
        pulse1.hasSweep = false
        pulse2.hasSweep = false
        applyPRG()
        applyCHR()
    }

    var ramBankCount: Int { max(prgRAM.count / 0x2000, 1) }

    func applyPRG() {
        func setSlot(_ slot: Int, _ reg: Int, sizeIn8k: Int, forceROM: Bool = false) {
            // slot: 1..4 for $8000.. windows; sizes in 8KB units.
            let value = prgRegs[reg]
            let isROM = forceROM || (value & 0x80) != 0
            var bank = value & 0x7F
            bank &= ~(sizeIn8k - 1)
            for i in 0..<sizeIn8k {
                let s = slot + i
                if isROM {
                    slotIsRAM[s] = false
                    slotOffset[s] = ((bank + i) % prgBankCount8k) * 0x2000
                } else {
                    slotIsRAM[s] = true
                    slotOffset[s] = (((bank + i) & 0x07) % ramBankCount) * 0x2000
                }
            }
        }
        // $6000 is always RAM.
        slotIsRAM[0] = true
        slotOffset[0] = ((prgRegs[0] & 0x07) % ramBankCount) * 0x2000
        switch prgMode {
        case 0:
            setSlot(1, 4, sizeIn8k: 4, forceROM: true)
        case 1:
            setSlot(1, 2, sizeIn8k: 2)
            setSlot(3, 4, sizeIn8k: 2, forceROM: true)
        case 2:
            setSlot(1, 2, sizeIn8k: 2)
            setSlot(3, 3, sizeIn8k: 1)
            setSlot(4, 4, sizeIn8k: 1, forceROM: true)
        default:
            setSlot(1, 1, sizeIn8k: 1)
            setSlot(2, 2, sizeIn8k: 1)
            setSlot(3, 3, sizeIn8k: 1)
            setSlot(4, 4, sizeIn8k: 1, forceROM: true)
        }
    }

    /// Selects CHR banks for sprites (set A) or background (set B).
    func applyCHR(useB: Bool? = nil) {
        let b = useB ?? (ppuLargeSprites ? false : lastCHRWriteB)
        if b {
            switch chrMode {
            case 0: setCHR8k(chrB[3])
            case 1: setCHR4k(0, chrB[3]); setCHR4k(1, chrB[3])
            case 2: setCHR2k(0, chrB[1]); setCHR2k(1, chrB[3]); setCHR2k(2, chrB[1]); setCHR2k(3, chrB[3])
            default: for i in 0..<8 { setCHR1k(i, chrB[i & 3]) }
            }
        } else {
            switch chrMode {
            case 0: setCHR8k(chrA[7])
            case 1: setCHR4k(0, chrA[3]); setCHR4k(1, chrA[7])
            case 2: for i in 0..<4 { setCHR2k(i, chrA[i * 2 + 1]) }
            default: for i in 0..<8 { setCHR1k(i, chrA[i]) }
            }
        }
    }

    // MARK: CPU

    override func readCPU(_ address: Int, openBus: UInt8) -> UInt8 {
        switch address {
        case 0x5204:
            var v: UInt8 = 0
            if irqPending { v |= 0x80 }
            if inFrame { v |= 0x40 }
            irqPending = false
            irqLine = false
            return v
        case 0x5205: return UInt8((multiplicand * multiplier) & 0xFF)
        case 0x5206: return UInt8((multiplicand * multiplier) >> 8)
        case 0x5C00...0x5FFF:
            return exRAMMode >= 2 ? exRAM[address - 0x5C00] : openBus
        case 0x6000...0xFFFF:
            if address == 0xFFFA || address == 0xFFFB {
                inFrame = false
                lastPPUAddress = -1
            }
            let slot = (address - 0x6000) >> 13
            let offset = slotOffset[slot] + (address & 0x1FFF)
            return slotIsRAM[slot] ? prgRAM[offset & (prgRAM.count - 1)] : prg[offset]
        default:
            return openBus
        }
    }

    override func peekCPU(_ address: Int) -> UInt8 {
        switch address {
        case 0x5C00...0x5FFF: return exRAM[address - 0x5C00]
        case 0x6000...0xFFFF:
            let slot = (address - 0x6000) >> 13
            let offset = slotOffset[slot] + (address & 0x1FFF)
            return slotIsRAM[slot] ? prgRAM[offset & (prgRAM.count - 1)] : prg[offset]
        default: return 0
        }
    }

    override func writeCPU(_ address: Int, _ value: UInt8) {
        let v = Int(value)
        switch address {
        case 0x5000...0x5003: pulse1.write(address & 3, value)
        case 0x5004...0x5007: pulse2.write(address & 3, value)
        case 0x5011: pcm = v
        case 0x5015:
            pulse1.length.setEnabled((v & 1) != 0)
            pulse2.length.setEnabled((v & 2) != 0)
        case 0x5100: prgMode = v & 3; applyPRG()
        case 0x5101: chrMode = v & 3; applyCHR()
        case 0x5102: ramProtect1 = v & 3
        case 0x5103: ramProtect2 = v & 3
        case 0x5104: exRAMMode = v & 3
        case 0x5105:
            ntMapping = v
        case 0x5106: fillTile = v
        case 0x5107: fillAttribute = v & 3
        case 0x5113...0x5117:
            prgRegs[address - 0x5113] = v
            applyPRG()
        case 0x5120...0x5127:
            chrA[address - 0x5120] = v | (chrUpper << 8)
            lastCHRWriteB = false
            applyCHR()
        case 0x5128...0x512B:
            chrB[address - 0x5128] = v | (chrUpper << 8)
            lastCHRWriteB = true
            applyCHR()
        case 0x5130: chrUpper = v & 3
        case 0x5203: irqCompare = v
        case 0x5204:
            irqEnabled = (v & 0x80) != 0
            irqLine = irqEnabled && irqPending
        case 0x5205: multiplicand = v
        case 0x5206: multiplier = v
        case 0x5C00...0x5FFF:
            if exRAMMode == 2 || (exRAMMode < 2 && inFrame) {
                exRAM[address - 0x5C00] = value
            } else if exRAMMode < 2 {
                exRAM[address - 0x5C00] = 0
            }
        case 0x6000...0xFFFF:
            let slot = (address - 0x6000) >> 13
            if slotIsRAM[slot] && ramProtect1 == 2 && ramProtect2 == 1 {
                prgRAM[(slotOffset[slot] + (address & 0x1FFF)) & (prgRAM.count - 1)] = value
            }
        default:
            break
        }
    }

    // MARK: PPU

    override func readPPU(_ address: Int) -> UInt8 {
        idleCycles = 0
        if address >= 0x2000 {
            detectScanline(address)
            let offset = address & 0x3FF
            let isAttribute = offset >= 0x3C0
            if exRAMMode == 1 && !ppuFetchingSprites && isAttribute && ppuRenderingEnabled {
                let pal = (lastExAttribute >> 6) & 3
                return UInt8(pal | pal << 2 | pal << 4 | pal << 6)
            }
            let nt = (address >> 10) & 3
            let value: UInt8
            switch (ntMapping >> (nt * 2)) & 3 {
            case 0: value = vram[offset]
            case 1: value = vram[0x400 + offset]
            case 2: value = exRAMMode <= 1 ? exRAM[offset] : 0
            default:
                value = isAttribute ? UInt8(fillAttribute | fillAttribute << 2 | fillAttribute << 4 | fillAttribute << 6)
                    : UInt8(fillTile)
            }
            if exRAMMode == 1 && !ppuFetchingSprites && !isAttribute {
                lastExAttribute = Int(exRAM[offset])
            }
            return value
        }
        lastPPUAddress = -1
        matchCount = 0
        if ppuRenderingEnabled {
            if exRAMMode == 1 && !ppuFetchingSprites {
                let bank = (lastExAttribute & 0x3F) | (chrUpper << 6)
                return chr[(bank * 0x1000 + (address & 0xFFF)) % chr.count]
            }
            if ppuLargeSprites {
                applyCHR(useB: !ppuFetchingSprites)
            }
        }
        return super.readPPU(address)
    }

    override func writePPU(_ address: Int, _ value: UInt8) {
        if address >= 0x2000 {
            let offset = address & 0x3FF
            let nt = (address >> 10) & 3
            switch (ntMapping >> (nt * 2)) & 3 {
            case 0: vram[offset] = value
            case 1: vram[0x400 + offset] = value
            case 2: if exRAMMode <= 1 { exRAM[offset] = value }
            default: break
            }
            return
        }
        super.writePPU(address, value)
    }

    /// The MMC5 counts scanlines by spotting three consecutive fetches of the same nametable address.
    func detectScanline(_ address: Int) {
        if address == lastPPUAddress {
            matchCount += 1
            if matchCount == 2 {
                if !inFrame {
                    inFrame = true
                    scanlineCounter = 0
                } else {
                    scanlineCounter += 1
                    if scanlineCounter == irqCompare {
                        irqPending = true
                        if irqEnabled { irqLine = true }
                    }
                }
                if !ppuLargeSprites { applyCHR() }
            }
        } else {
            matchCount = 0
        }
        lastPPUAddress = address
    }

    override func clockCPU() {
        // No PPU reads for a few cycles means rendering stopped (vblank or disabled).
        idleCycles += 1
        if idleCycles > 3 && inFrame {
            inFrame = false
            lastPPUAddress = -1
        }
        pulse1.clockTimer()
        pulse2.clockTimer()
        // The MMC5 clocks its envelopes / length counters from a fixed 240Hz divider.
        frameDivider += 1
        if frameDivider >= 7457 {
            frameDivider = 0
            pulse1.envelope.clock(); pulse2.envelope.clock()
            pulse1.length.clock(); pulse2.length.clock()
        }
    }

    override func audioSample() -> Float {
        let p = pulse1.output + pulse2.output
        return APU.pulseTable[min(p, 30)] + Float(pcm) * 0.0006
    }

    // MARK: State

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w)
        w.write([prgMode, chrMode, ramProtect1, ramProtect2, exRAMMode, ntMapping, fillTile, fillAttribute,
                 chrUpper, irqCompare, scanlineCounter, multiplicand, multiplier, lastPPUAddress, matchCount,
                 idleCycles, lastExAttribute, pcm, frameDivider])
        w.write(prgRegs); w.write(chrA); w.write(chrB); w.write(slotOffset)
        w.write(slotIsRAM.map { $0 ? 1 : 0 })
        w.write(lastCHRWriteB); w.write(irqEnabled); w.write(irqPending); w.write(inFrame)
        w.write(exRAM)
        pulse1.save(&w); pulse2.save(&w)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        let v = try r.readIntArray()
        guard v.count == 19 else { throw StateError.corrupt("MMC5") }
        prgMode = v[0]; chrMode = v[1]; ramProtect1 = v[2]; ramProtect2 = v[3]; exRAMMode = v[4]
        ntMapping = v[5]; fillTile = v[6]; fillAttribute = v[7]; chrUpper = v[8]; irqCompare = v[9]
        scanlineCounter = v[10]; multiplicand = v[11]; multiplier = v[12]; lastPPUAddress = v[13]
        matchCount = v[14]; idleCycles = v[15]; lastExAttribute = v[16]; pcm = v[17]; frameDivider = v[18]
        prgRegs = try r.readIntArray(); chrA = try r.readIntArray(); chrB = try r.readIntArray()
        slotOffset = try r.readIntArray()
        slotIsRAM = try r.readIntArray().map { $0 != 0 }
        guard prgRegs.count == 5, chrA.count == 8, chrB.count == 4, slotOffset.count == 5, slotIsRAM.count == 5 else {
            throw StateError.corrupt("MMC5 banks")
        }
        lastCHRWriteB = try r.readBool(); irqEnabled = try r.readBool(); irqPending = try r.readBool()
        inFrame = try r.readBool()
        try r.read(into: exRAM)
        try pulse1.load(&r); try pulse2.load(&r)
        applyPRG()
    }
}

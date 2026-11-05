#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The IRQ counter shared by VRC4, VRC6 and VRC7.
struct VRCIRQ {
    var latch = 0
    var counter = 0
    var prescaler = 341
    var enabled = false
    var enableAfterAck = false
    var cycleMode = false
    var pending = false

    mutating func writeControl(_ v: UInt8) {
        enableAfterAck = (v & 1) != 0
        enabled = (v & 2) != 0
        cycleMode = (v & 4) != 0
        if enabled {
            counter = latch
            prescaler = 341
        }
        pending = false
    }

    mutating func acknowledge() {
        enabled = enableAfterAck
        pending = false
    }

    /// One CPU cycle.
    mutating func clock() {
        guard enabled else { return }
        if cycleMode {
            tick()
        } else {
            prescaler -= 3
            if prescaler <= 0 {
                prescaler += 341
                tick()
            }
        }
    }

    mutating func tick() {
        if counter == 0xFF {
            counter = latch
            pending = true
        } else {
            counter += 1
        }
    }

    func save(_ w: inout StateWriter) {
        w.write([latch, counter, prescaler])
        w.write(enabled); w.write(enableAfterAck); w.write(cycleMode); w.write(pending)
    }

    mutating func load(_ r: inout StateReader) throws {
        let v = try r.readIntArray()
        guard v.count == 3 else { throw StateError.corrupt("VRC IRQ") }
        latch = v[0]; counter = v[1]; prescaler = v[2]
        enabled = try r.readBool(); enableAfterAck = try r.readBool()
        cycleMode = try r.readBool(); pending = try r.readBool()
    }
}

/// Mappers 21, 22, 23, 25: Konami VRC2 / VRC4. The board variants differ only in which
/// CPU address lines drive the register select pins, so both candidate lines are OR-ed.
final class VRC24: Mapper {
    var prg0 = 0, prg1 = 0
    var prgSwap = false
    var chrRegs = [Int](repeating: 0, count: 8)
    var irq = VRCIRQ()
    var isVRC2a: Bool { cartridge.mapperID == 22 }

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        needsCPUClock = !isVRC2a
        apply()
    }

    /// Returns the register index 0-3 within a $x000 group.
    func registerIndex(_ address: Int) -> Int {
        let a0: Int, a1: Int
        switch cartridge.mapperID {
        case 21:
            a0 = ((address >> 1) | (address >> 6)) & 1
            a1 = ((address >> 2) | (address >> 7)) & 1
        case 22:
            a0 = (address >> 1) & 1
            a1 = address & 1
        case 23:
            a0 = (address | (address >> 2)) & 1
            a1 = ((address >> 1) | (address >> 3)) & 1
        default: // 25
            a0 = ((address >> 1) | (address >> 3)) & 1
            a1 = (address | (address >> 2)) & 1
        }
        return a1 << 1 | a0
    }

    func apply() {
        if prgSwap {
            setPRG8k(0, -2)
            setPRG8k(2, prg0)
        } else {
            setPRG8k(0, prg0)
            setPRG8k(2, -2)
        }
        setPRG8k(1, prg1)
        setPRG8k(3, -1)
        for i in 0..<8 { setCHR1k(i, isVRC2a ? chrRegs[i] >> 1 : chrRegs[i]) }
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        let reg = registerIndex(address)
        let v = Int(value)
        switch address & 0xF000 {
        case 0x8000:
            prg0 = v & 0x1F
        case 0x9000:
            if reg == 0 || (isVRC2a && reg == 1) {
                guard cartridge.mirroring != .fourScreen else { break }
                if isVRC2a || cartridge.mapperID == 23 && cartridge.submapper == 3 {
                    setMirroring((v & 1) != 0 ? .horizontal : .vertical)
                } else {
                    switch v & 3 {
                    case 0: setMirroring(.vertical)
                    case 1: setMirroring(.horizontal)
                    case 2: setMirroring(.singleScreenA)
                    default: setMirroring(.singleScreenB)
                    }
                }
            } else if reg == 2 && !isVRC2a {
                prgSwap = (v & 2) != 0
            }
        case 0xA000:
            prg1 = v & 0x1F
        case 0xB000, 0xC000, 0xD000, 0xE000:
            let bank = ((address & 0xF000) - 0xB000) / 0x1000 * 2 + (reg >> 1)
            if (reg & 1) == 0 {
                chrRegs[bank] = (chrRegs[bank] & ~0x0F) | (v & 0x0F)
            } else {
                chrRegs[bank] = (chrRegs[bank] & 0x0F) | ((v & 0x1F) << 4)
            }
        case 0xF000:
            guard !isVRC2a else { break }
            switch reg {
            case 0: irq.latch = (irq.latch & 0xF0) | (v & 0x0F)
            case 1: irq.latch = (irq.latch & 0x0F) | ((v & 0x0F) << 4)
            case 2: irq.writeControl(value); irqLine = false
            default: irq.acknowledge(); irqLine = false
            }
        default: break
        }
        apply()
    }

    override func clockCPU() {
        irq.clock()
        if irq.pending { irqLine = true }
    }

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w)
        w.write([prg0, prg1]); w.write(prgSwap); w.write(chrRegs); irq.save(&w)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        let p = try r.readIntArray()
        guard p.count == 2 else { throw StateError.corrupt("VRC2/4") }
        prg0 = p[0]; prg1 = p[1]
        prgSwap = try r.readBool()
        chrRegs = try r.readIntArray()
        guard chrRegs.count == 8 else { throw StateError.corrupt("VRC2/4 CHR") }
        try irq.load(&r)
    }
}

/// Mappers 24 / 26: Konami VRC6 (Akumajou Densetsu, Madara, Esper Dream 2) with expansion audio.
final class VRC6: Mapper {
    var chrRegs = [Int](repeating: 0, count: 8)
    var irq = VRCIRQ()

    // Audio
    struct Pulse {
        var volume = 0, duty = 0, mode = false
        var period = 0, enabled = false
        var timer = 0, step = 15
        mutating func clock(halt: Bool, shift: Int) {
            guard enabled && !halt else { return }
            if timer <= 0 {
                timer = (period >> shift)
                step = (step - 1) & 0x0F
            } else {
                timer -= 1
            }
        }
        var output: Int { enabled && (mode || step <= duty) ? volume : 0 }
    }
    struct Saw {
        var rate = 0, period = 0, enabled = false
        var timer = 0, step = 0, accumulator = 0
        mutating func clock(halt: Bool, shift: Int) {
            guard enabled && !halt else { return }
            if timer <= 0 {
                timer = (period >> shift)
                step += 1
                if step >= 14 {
                    step = 0
                    accumulator = 0
                } else if (step & 1) == 0 {
                    accumulator = (accumulator + rate) & 0xFF
                }
            } else {
                timer -= 1
            }
        }
        var output: Int { enabled ? accumulator >> 3 : 0 }
    }
    var pulse1 = Pulse(), pulse2 = Pulse(), saw = Saw()
    var haltAudio = false
    var freqShift = 0

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        needsCPUClock = true
        hasExpansionAudio = true
        setPRG16k(0, 0)
        setPRG8k(2, 0)
        setPRG8k(3, -1)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        var a = address & 0xF003
        if cartridge.mapperID == 26 { a = (a & 0xF000) | ((a & 1) << 1) | ((a & 2) >> 1) }
        let v = Int(value)
        switch a {
        case 0x8000...0x8003: setPRG16k(0, v & 0x0F)
        case 0x9000: pulse1.mode = (v & 0x80) != 0; pulse1.duty = (v >> 4) & 7; pulse1.volume = v & 0x0F
        case 0x9001: pulse1.period = (pulse1.period & 0xF00) | v
        case 0x9002: pulse1.period = (pulse1.period & 0xFF) | ((v & 0x0F) << 8); pulse1.enabled = (v & 0x80) != 0
            if !pulse1.enabled { pulse1.step = 15 }
        case 0x9003:
            haltAudio = (v & 1) != 0
            freqShift = (v & 4) != 0 ? 8 : ((v & 2) != 0 ? 4 : 0)
        case 0xA000: pulse2.mode = (v & 0x80) != 0; pulse2.duty = (v >> 4) & 7; pulse2.volume = v & 0x0F
        case 0xA001: pulse2.period = (pulse2.period & 0xF00) | v
        case 0xA002: pulse2.period = (pulse2.period & 0xFF) | ((v & 0x0F) << 8); pulse2.enabled = (v & 0x80) != 0
            if !pulse2.enabled { pulse2.step = 15 }
        case 0xB000: saw.rate = v & 0x3F
        case 0xB001: saw.period = (saw.period & 0xF00) | v
        case 0xB002: saw.period = (saw.period & 0xFF) | ((v & 0x0F) << 8); saw.enabled = (v & 0x80) != 0
            if !saw.enabled { saw.accumulator = 0; saw.step = 0 }
        case 0xB003:
            if cartridge.mirroring != .fourScreen {
                switch (v >> 2) & 3 {
                case 0: setMirroring(.vertical)
                case 1: setMirroring(.horizontal)
                case 2: setMirroring(.singleScreenA)
                default: setMirroring(.singleScreenB)
                }
            }
            prgRAMEnabled = (v & 0x80) != 0
        case 0xC000...0xC003: setPRG8k(2, v & 0x1F)
        case 0xD000...0xD003: chrRegs[a & 3] = v; setCHR1k(a & 3, v)
        case 0xE000...0xE003: chrRegs[4 + (a & 3)] = v; setCHR1k(4 + (a & 3), v)
        case 0xF000: irq.latch = v
        case 0xF001: irq.writeControl(value); irqLine = false
        case 0xF002: irq.acknowledge(); irqLine = false
        default: break
        }
    }

    override func clockCPU() {
        irq.clock()
        if irq.pending { irqLine = true }
        pulse1.clock(halt: haltAudio, shift: freqShift)
        pulse2.clock(halt: haltAudio, shift: freqShift)
        saw.clock(halt: haltAudio, shift: freqShift)
    }

    override func audioSample() -> Float {
        // Max 15+15+31 = 61; scale so one pulse matches an APU pulse at full volume.
        Float(pulse1.output + pulse2.output + saw.output) * 0.0098
    }

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w)
        w.write(chrRegs); irq.save(&w)
        for p in [pulse1, pulse2] {
            w.write([p.volume, p.duty, p.period, p.timer, p.step]); w.write(p.mode); w.write(p.enabled)
        }
        w.write([saw.rate, saw.period, saw.timer, saw.step, saw.accumulator]); w.write(saw.enabled)
        w.write(haltAudio); w.write(freqShift)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        chrRegs = try r.readIntArray()
        guard chrRegs.count == 8 else { throw StateError.corrupt("VRC6") }
        try irq.load(&r)
        var pulses = [Pulse]()
        for _ in 0..<2 {
            let v = try r.readIntArray()
            guard v.count == 5 else { throw StateError.corrupt("VRC6 pulse") }
            var p = Pulse()
            p.volume = v[0]; p.duty = v[1]; p.period = v[2]; p.timer = v[3]; p.step = v[4]
            p.mode = try r.readBool(); p.enabled = try r.readBool()
            pulses.append(p)
        }
        pulse1 = pulses[0]; pulse2 = pulses[1]
        let s = try r.readIntArray()
        guard s.count == 5 else { throw StateError.corrupt("VRC6 saw") }
        saw.rate = s[0]; saw.period = s[1]; saw.timer = s[2]; saw.step = s[3]; saw.accumulator = s[4]
        saw.enabled = try r.readBool()
        haltAudio = try r.readBool(); freqShift = try r.readInt()
    }
}

/// Mapper 69: Sunsoft FME-7 / 5A / 5B (Batman: Return of the Joker, Gimmick!).
final class FME7: Mapper {
    var command = 0
    var chrRegs = [Int](repeating: 0, count: 8)
    var prgRegs = [0, 0, 0, 0]   // $6000, $8000, $A000, $C000
    var ramSelected = false
    var irqEnabled = false
    var counterEnabled = false
    var irqCounter = 0

    // Sunsoft 5B (YM2149-compatible) tone channels.
    var audioRegister = 0
    var tonePeriod = [0, 0, 0]
    var toneTimer = [0, 0, 0]
    var toneOutput = [false, false, false]
    var toneVolume = [0, 0, 0]
    var toneDisabled = [true, true, true]
    var audioDivider = 0
    static let volumeTable: [Float] = (0..<16).map { v in
        v == 0 ? 0 : Float(pow(2, Double(v - 15) * 0.5)) * 0.12   // YM2149 DAC: ~3 dB per step
    }

    required init(cartridge: Cartridge) {
        super.init(cartridge: cartridge)
        needsCPUClock = true
        hasExpansionAudio = true
        apply()
    }

    func apply() {
        for i in 0..<8 { setCHR1k(i, chrRegs[i]) }
        setPRG8k(0, prgRegs[1])
        setPRG8k(1, prgRegs[2])
        setPRG8k(2, prgRegs[3])
        setPRG8k(3, -1)
        ramSelected = (prgRegs[0] & 0x40) != 0
        prgRAMEnabled = (prgRegs[0] & 0x80) != 0
        setPRGRAM8k(prgRegs[0] & 0x3F)
    }

    override func readCPU(_ address: Int, openBus: UInt8) -> UInt8 {
        if address >= 0x6000 && address < 0x8000 && !ramSelected {
            let count = prgBankCount8k
            let bank = (prgRegs[0] & 0x3F) % count
            return prg[bank * 0x2000 + (address & 0x1FFF)]
        }
        return super.readCPU(address, openBus: openBus)
    }

    override func writeCPU(_ address: Int, _ value: UInt8) {
        if address >= 0x6000 && address < 0x8000 {
            if ramSelected { writeRAM(address, value) }
            return
        }
        super.writeCPU(address, value)
    }

    override func writeRegister(_ address: Int, _ value: UInt8) {
        let v = Int(value)
        switch address & 0xE000 {
        case 0x8000:
            command = v & 0x0F
        case 0xA000:
            switch command {
            case 0...7: chrRegs[command] = v
            case 8...11: prgRegs[command - 8] = command == 8 ? v : v & 0x3F
            case 12:
                switch v & 3 {
                case 0: setMirroring(.vertical)
                case 1: setMirroring(.horizontal)
                case 2: setMirroring(.singleScreenA)
                default: setMirroring(.singleScreenB)
                }
            case 13:
                irqEnabled = (v & 1) != 0
                counterEnabled = (v & 0x80) != 0
                irqLine = false
            case 14: irqCounter = (irqCounter & 0xFF00) | v
            default: irqCounter = (irqCounter & 0x00FF) | (v << 8)
            }
            apply()
        case 0xC000:
            audioRegister = v & 0x0F
        default: // 0xE000
            writeAudio(v)
        }
    }

    func writeAudio(_ v: Int) {
        switch audioRegister {
        case 0, 2, 4:
            let ch = audioRegister / 2
            tonePeriod[ch] = (tonePeriod[ch] & 0xF00) | v
        case 1, 3, 5:
            let ch = audioRegister / 2
            tonePeriod[ch] = (tonePeriod[ch] & 0xFF) | ((v & 0x0F) << 8)
        case 7:
            for ch in 0..<3 { toneDisabled[ch] = (v >> ch) & 1 != 0 }
        case 8, 9, 10:
            toneVolume[audioRegister - 8] = v & 0x0F
        default: break
        }
    }

    override func clockCPU() {
        if counterEnabled {
            irqCounter = (irqCounter - 1) & 0xFFFF
            if irqCounter == 0xFFFF && irqEnabled { irqLine = true }
        }
        // The 5B divides the CPU clock by 16 for its tone generators.
        audioDivider += 1
        if audioDivider >= 16 {
            audioDivider = 0
            for ch in 0..<3 {
                toneTimer[ch] += 1
                if toneTimer[ch] >= max(tonePeriod[ch], 1) {
                    toneTimer[ch] = 0
                    toneOutput[ch].toggle()
                }
            }
        }
    }

    override func audioSample() -> Float {
        var sum: Float = 0
        for ch in 0..<3 where !toneDisabled[ch] && toneOutput[ch] {
            sum += FME7.volumeTable[toneVolume[ch]]
        }
        return sum
    }

    override func saveState(_ w: inout StateWriter) {
        super.saveState(&w)
        w.write(command); w.write(chrRegs); w.write(prgRegs)
        w.write(irqEnabled); w.write(counterEnabled); w.write(irqCounter)
        w.write(audioRegister); w.write(tonePeriod); w.write(toneTimer); w.write(toneVolume)
        w.write(toneOutput.map { $0 ? 1 : 0 }); w.write(toneDisabled.map { $0 ? 1 : 0 }); w.write(audioDivider)
    }

    override func loadState(_ r: inout StateReader) throws {
        try super.loadState(&r)
        command = try r.readInt(); chrRegs = try r.readIntArray(); prgRegs = try r.readIntArray()
        irqEnabled = try r.readBool(); counterEnabled = try r.readBool(); irqCounter = try r.readInt()
        audioRegister = try r.readInt(); tonePeriod = try r.readIntArray(); toneTimer = try r.readIntArray()
        toneVolume = try r.readIntArray()
        toneOutput = try r.readIntArray().map { $0 != 0 }
        toneDisabled = try r.readIntArray().map { $0 != 0 }
        audioDivider = try r.readInt()
        guard chrRegs.count == 8, prgRegs.count == 4, tonePeriod.count == 3, toneTimer.count == 3,
              toneVolume.count == 3, toneOutput.count == 3, toneDisabled.count == 3 else {
            throw StateError.corrupt("FME-7")
        }
        apply()
    }
}


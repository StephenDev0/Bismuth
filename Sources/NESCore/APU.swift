let lengthTable: [UInt8] = [
    10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
    12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
]

struct Envelope {
    var start = false
    var loop = false
    var constant = false
    var volume = 0
    var divider = 0
    var decay = 0

    mutating func clock() {
        if start {
            start = false
            decay = 15
            divider = volume
        } else if divider == 0 {
            divider = volume
            if decay > 0 { decay -= 1 } else if loop { decay = 15 }
        } else {
            divider -= 1
        }
    }

    var output: Int { constant ? volume : decay }
}

struct LengthCounter {
    var enabled = false
    var halt = false
    var counter = 0

    mutating func load(_ index: UInt8) {
        if enabled { counter = Int(lengthTable[Int(index >> 3)]) }
    }

    mutating func clock() {
        if counter > 0 && !halt { counter -= 1 }
    }

    mutating func setEnabled(_ e: Bool) {
        enabled = e
        if !e { counter = 0 }
    }
}

/// Square wave channel (also reused by the MMC5).
struct PulseChannel {
    /// Duty sequences, one bit per step (step 0 = bit 7).
    static let dutyBits: (Int, Int, Int, Int) = (0b0100_0000, 0b0110_0000, 0b0111_1000, 0b1001_1111)
    let isFirst: Bool
    var envelope = Envelope()
    var length = LengthCounter()
    var dutyMode = 0
    var dutyStep = 0
    var period = 0
    var timer = 0
    var sweepEnabled = false
    var sweepPeriod = 0
    var sweepNegate = false
    var sweepShift = 0
    var sweepDivider = 0
    var sweepReload = false
    var hasSweep = true

    init(isFirst: Bool) { self.isFirst = isFirst }

    mutating func write(_ reg: Int, _ v: UInt8) {
        switch reg {
        case 0:
            dutyMode = Int(v >> 6)
            length.halt = (v & 0x20) != 0
            envelope.loop = length.halt
            envelope.constant = (v & 0x10) != 0
            envelope.volume = Int(v & 0x0F)
        case 1:
            sweepEnabled = (v & 0x80) != 0
            sweepPeriod = Int(v >> 4) & 7
            sweepNegate = (v & 0x08) != 0
            sweepShift = Int(v & 7)
            sweepReload = true
        case 2:
            period = (period & 0x700) | Int(v)
        default:
            period = (period & 0xFF) | (Int(v & 7) << 8)
            length.load(v)
            envelope.start = true
            dutyStep = 0
        }
    }

    var sweepTarget: Int {
        let change = period >> sweepShift
        if sweepNegate { return period - change - (isFirst ? 1 : 0) }
        return period + change
    }

    var muted: Bool { period < 8 || (hasSweep && !sweepNegate && sweepTarget > 0x7FF) }

    /// One CPU cycle. The pulse timer runs at half the CPU clock.
    @inline(__always)
    mutating func clockTimer() {
        if timer == 0 {
            timer = (period + 1) * 2 - 1
            dutyStep = (dutyStep + 1) & 7
        } else {
            timer -= 1
        }
    }

    mutating func clockSweep() {
        guard hasSweep else { return }
        if sweepDivider == 0 && sweepEnabled && sweepShift > 0 && !muted {
            let target = sweepTarget
            if target >= 0 { period = target }
        }
        if sweepDivider == 0 || sweepReload {
            sweepDivider = sweepPeriod
            sweepReload = false
        } else {
            sweepDivider -= 1
        }
    }

    var output: Int {
        let bits: Int
        switch dutyMode {
        case 0: bits = PulseChannel.dutyBits.0
        case 1: bits = PulseChannel.dutyBits.1
        case 2: bits = PulseChannel.dutyBits.2
        default: bits = PulseChannel.dutyBits.3
        }
        if length.counter == 0 || muted || (bits >> (7 - dutyStep)) & 1 == 0 { return 0 }
        return envelope.output
    }

    func save(_ w: inout StateWriter) {
        w.write([envelope.volume, envelope.divider, envelope.decay, length.counter, dutyMode, dutyStep,
                 period, timer, sweepPeriod, sweepShift, sweepDivider])
        w.write(envelope.start); w.write(envelope.loop); w.write(envelope.constant)
        w.write(length.enabled); w.write(length.halt)
        w.write(sweepEnabled); w.write(sweepNegate); w.write(sweepReload)
    }

    mutating func load(_ r: inout StateReader) throws {
        let v = try r.readIntArray()
        guard v.count == 11 else { throw StateError.corrupt("pulse") }
        envelope.volume = v[0]; envelope.divider = v[1]; envelope.decay = v[2]; length.counter = v[3]
        dutyMode = v[4] & 3; dutyStep = v[5] & 7; period = v[6]; timer = v[7]
        sweepPeriod = v[8]; sweepShift = v[9]; sweepDivider = v[10]
        envelope.start = try r.readBool(); envelope.loop = try r.readBool(); envelope.constant = try r.readBool()
        length.enabled = try r.readBool(); length.halt = try r.readBool()
        sweepEnabled = try r.readBool(); sweepNegate = try r.readBool(); sweepReload = try r.readBool()
    }
}

struct TriangleChannel {
    static let sequence: [Int] = [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
                                  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    var length = LengthCounter()
    var control = false
    var linearReloadValue = 0
    var linearCounter = 0
    var linearReload = false
    var period = 0
    var timer = 0
    var step = 0

    mutating func write(_ reg: Int, _ v: UInt8) {
        switch reg {
        case 0:
            control = (v & 0x80) != 0
            length.halt = control
            linearReloadValue = Int(v & 0x7F)
        case 2:
            period = (period & 0x700) | Int(v)
        case 3:
            period = (period & 0xFF) | (Int(v & 7) << 8)
            length.load(v)
            linearReload = true
        default:
            break
        }
    }

    mutating func clockLinear() {
        if linearReload {
            linearCounter = linearReloadValue
        } else if linearCounter > 0 {
            linearCounter -= 1
        }
        if !control { linearReload = false }
    }

    @inline(__always)
    mutating func clockTimer() {
        if timer == 0 {
            timer = period
            // Ultrasonic periods are inaudible; holding the step avoids a DC pop.
            if length.counter > 0 && linearCounter > 0 && period >= 2 {
                step = (step + 1) & 31
            }
        } else {
            timer -= 1
        }
    }

    var output: Int { TriangleChannel.sequence[step] }

    func save(_ w: inout StateWriter) {
        w.write([length.counter, linearReloadValue, linearCounter, period, timer, step])
        w.write(length.enabled); w.write(length.halt); w.write(control); w.write(linearReload)
    }

    mutating func load(_ r: inout StateReader) throws {
        let v = try r.readIntArray()
        guard v.count == 6 else { throw StateError.corrupt("triangle") }
        length.counter = v[0]; linearReloadValue = v[1]; linearCounter = v[2]; period = v[3]; timer = v[4]; step = v[5] & 31
        length.enabled = try r.readBool(); length.halt = try r.readBool()
        control = try r.readBool(); linearReload = try r.readBool()
    }
}

struct NoiseChannel {
    static let ntscPeriods = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068]
    static let palPeriods = [4, 8, 14, 30, 60, 88, 118, 148, 188, 236, 354, 472, 708, 944, 1890, 3778]
    var envelope = Envelope()
    var length = LengthCounter()
    var mode = false
    var period = 4
    var timer = 0
    var shift = 1
    var pal = false

    mutating func write(_ reg: Int, _ v: UInt8) {
        switch reg {
        case 0:
            length.halt = (v & 0x20) != 0
            envelope.loop = length.halt
            envelope.constant = (v & 0x10) != 0
            envelope.volume = Int(v & 0x0F)
        case 2:
            mode = (v & 0x80) != 0
            period = (pal ? NoiseChannel.palPeriods : NoiseChannel.ntscPeriods)[Int(v & 0x0F)]
        case 3:
            length.load(v)
            envelope.start = true
        default:
            break
        }
    }

    @inline(__always)
    mutating func clockTimer() {
        if timer == 0 {
            timer = period - 1
            let feedback = (shift & 1) ^ ((mode ? shift >> 6 : shift >> 1) & 1)
            shift = (shift >> 1) | (feedback << 14)
        } else {
            timer -= 1
        }
    }

    var output: Int { (length.counter == 0 || (shift & 1) != 0) ? 0 : envelope.output }

    func save(_ w: inout StateWriter) {
        w.write([envelope.volume, envelope.divider, envelope.decay, length.counter, period, timer, shift])
        w.write(envelope.start); w.write(envelope.loop); w.write(envelope.constant)
        w.write(length.enabled); w.write(length.halt); w.write(mode)
    }

    mutating func load(_ r: inout StateReader) throws {
        let v = try r.readIntArray()
        guard v.count == 7 else { throw StateError.corrupt("noise") }
        envelope.volume = v[0]; envelope.divider = v[1]; envelope.decay = v[2]; length.counter = v[3]
        period = max(v[4], 1); timer = v[5]; shift = v[6]
        envelope.start = try r.readBool(); envelope.loop = try r.readBool(); envelope.constant = try r.readBool()
        length.enabled = try r.readBool(); length.halt = try r.readBool(); mode = try r.readBool()
    }
}

/// 2A03 / 2A07 audio processing unit.
public final class APU {
    static let dmcNTSC = [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54]
    static let dmcPAL = [398, 354, 316, 298, 276, 236, 210, 198, 176, 148, 132, 118, 98, 78, 66, 50]
    static let frameStepsNTSC: [[Int]] = [[7457, 14913, 22371, 29828, 29829, 29830], [7457, 14913, 22371, 29829, 37281, 37282]]
    static let frameStepsPAL: [[Int]] = [[8313, 16627, 24939, 33252, 33253, 33254], [8313, 16627, 24939, 33253, 41565, 41566]]
    // 0 = none, 1 = quarter, 2 = half (quarter + half)
    static let frameActions: [[Int]] = [[1, 2, 1, 0, 2, 0], [1, 2, 1, 0, 2, 0]]
    static let pulseTable: [Float] = (0..<31).map { $0 == 0 ? 0 : Float(95.52 / (8128.0 / Double($0) + 100.0)) }
    static let tndTable: [Float] = (0..<203).map { $0 == 0 ? 0 : Float(163.67 / (24329.0 / Double($0) + 100.0)) }

    let mapper: Mapper
    /// Set when the DMC wants a sample byte; the CPU services it and clears the flag.
    var dmcDMARequest = false
    let pulseLUT: UnsafeMutablePointer<Float>
    let tndLUT: UnsafeMutablePointer<Float>
    let hasExpansionAudio: Bool
    var nextFrameEvent = 0
    let region: Region
    let frameSteps: [[Int]]
    let dmcRates: [Int]

    var pulse1 = PulseChannel(isFirst: true)
    var pulse2 = PulseChannel(isFirst: false)
    var triangle = TriangleChannel()
    var noise = NoiseChannel()

    // DMC
    var dmcIRQEnabled = false
    var dmcLoop = false
    var dmcPeriod = 428
    var dmcTimer = 0
    var dmcOutput = 0
    var dmcSampleAddress = 0xC000
    var dmcSampleLength = 1
    var dmcCurrentAddress = 0xC000
    var dmcBytesRemaining = 0
    var dmcBuffer = 0
    var dmcBufferEmpty = true
    var dmcShift = 0
    var dmcBitsRemaining = 8
    var dmcSilence = true
    var dmcStartDelay = 0

    // Frame counter
    var frameMode = 0
    var frameCycle = 0
    var frameStep = 0
    var frameIRQInhibit = false
    var frameIRQ = false
    var dmcIRQ = false
    var pendingFrameWrite = -1
    var frameWriteDelay = 0
    var cycle: UInt64 = 0

    // Output
    public var sampleRate: Double {
        didSet {
            blip.configure(clockRate: region.cpuClockRate, sampleRate: sampleRate)
            configureFilters()
        }
    }
    let blip: BlipBuffer
    var lastAmplitude: Float = 0
    var hp1 = HighPass(), hp2 = HighPass(), lp = LowPass()
    /// Output filter chain. `.authentic` models the NES's analog stage (90 Hz and 440 Hz high-pass,
    /// 14 kHz low-pass); `.clean` only removes DC, for a brighter sound.
    public var filter: AudioFilter = .authentic {
        didSet { configureFilters() }
    }
    /// Interleaved stereo Int16 samples produced since the last drain.
    public internal(set) var samples: [Int16] = []
    public var volume: Float = 1.0
    /// Per-channel mute mask: bit0 pulse1, bit1 pulse2, bit2 triangle, bit3 noise, bit4 DMC, bit5 expansion.
    public var channelMask = 0x3F

    var irq: Bool { frameIRQ || dmcIRQ }

    init(region: Region, mapper: Mapper, sampleRate: Double = 48_000) {
        self.region = region
        self.mapper = mapper
        hasExpansionAudio = mapper.hasExpansionAudio
        pulseLUT = .allocate(capacity: APU.pulseTable.count)
        pulseLUT.initialize(from: APU.pulseTable, count: APU.pulseTable.count)
        tndLUT = .allocate(capacity: APU.tndTable.count)
        tndLUT.initialize(from: APU.tndTable, count: APU.tndTable.count)
        self.sampleRate = sampleRate
        blip = BlipBuffer(clockRate: region.cpuClockRate, sampleRate: sampleRate)
        frameSteps = region == .ntsc ? APU.frameStepsNTSC : APU.frameStepsPAL
        dmcRates = region == .ntsc ? APU.dmcNTSC : APU.dmcPAL
        noise.pal = region != .ntsc
        dmcPeriod = dmcRates[0]
        configureFilters()
        samples.reserveCapacity(4096)
        nextFrameEvent = frameSteps[0][0]
    }

    deinit {
        pulseLUT.deallocate()
        tndLUT.deallocate()
    }

    func configureFilters() {
        let rate = Float(sampleRate)
        switch filter {
        case .authentic:
            hp1 = HighPass(cutoff: 90, sampleRate: rate)
            hp2 = HighPass(cutoff: 440, sampleRate: rate)
            lp = LowPass(cutoff: 14_000, sampleRate: rate)
        case .clean:
            hp1 = HighPass(cutoff: 20, sampleRate: rate)
            hp2 = HighPass()
            lp = LowPass()
        }
    }

    func reset(hard: Bool) {
        write(0x4015, 0)
        frameIRQ = false
        dmcIRQ = false
        if hard {
            pulse1 = PulseChannel(isFirst: true)
            pulse2 = PulseChannel(isFirst: false)
            triangle = TriangleChannel()
            noise = NoiseChannel()
            noise.pal = region != .ntsc
            noise.period = (noise.pal ? NoiseChannel.palPeriods : NoiseChannel.ntscPeriods)[0]
            dmcOutput = 0
            frameIRQInhibit = false
            frameMode = 0
        }
        dmcPeriod = dmcRates[0]
        dmcTimer = dmcPeriod
        dmcBitsRemaining = 8
        dmcSilence = true
        // The frame counter behaves as if $4017 were written shortly before the first instruction.
        pendingFrameWrite = hard ? 0 : (frameMode << 7) | (frameIRQInhibit ? 0x40 : 0)
        frameWriteDelay = 3
        frameCycle = 0
        frameStep = 0
        nextFrameEvent = frameSteps[frameMode][0]
    }

    // MARK: - Registers

    func readStatus() -> UInt8 {
        var v: UInt8 = 0
        if pulse1.length.counter > 0 { v |= 0x01 }
        if pulse2.length.counter > 0 { v |= 0x02 }
        if triangle.length.counter > 0 { v |= 0x04 }
        if noise.length.counter > 0 { v |= 0x08 }
        if dmcBytesRemaining > 0 { v |= 0x10 }
        if frameIRQ { v |= 0x40 }
        if dmcIRQ { v |= 0x80 }
        frameIRQ = false
        return v
    }

    func peekStatus() -> UInt8 {
        var v: UInt8 = 0
        if pulse1.length.counter > 0 { v |= 0x01 }
        if pulse2.length.counter > 0 { v |= 0x02 }
        if triangle.length.counter > 0 { v |= 0x04 }
        if noise.length.counter > 0 { v |= 0x08 }
        if dmcBytesRemaining > 0 { v |= 0x10 }
        if frameIRQ { v |= 0x40 }
        if dmcIRQ { v |= 0x80 }
        return v
    }

    func write(_ address: Int, _ value: UInt8) {
        switch address {
        case 0x4000...0x4003: pulse1.write(address & 3, value)
        case 0x4004...0x4007: pulse2.write(address & 3, value)
        case 0x4008...0x400B: triangle.write(address & 3, value)
        case 0x400C...0x400F: noise.write(address & 3, value)
        case 0x4010:
            dmcIRQEnabled = (value & 0x80) != 0
            dmcLoop = (value & 0x40) != 0
            dmcPeriod = dmcRates[Int(value & 0x0F)]
            if !dmcIRQEnabled { dmcIRQ = false }
        case 0x4011:
            dmcOutput = Int(value & 0x7F)
        case 0x4012:
            dmcSampleAddress = 0xC000 | (Int(value) << 6)
        case 0x4013:
            dmcSampleLength = (Int(value) << 4) | 1
        case 0x4015:
            pulse1.length.setEnabled((value & 0x01) != 0)
            pulse2.length.setEnabled((value & 0x02) != 0)
            triangle.length.setEnabled((value & 0x04) != 0)
            noise.length.setEnabled((value & 0x08) != 0)
            dmcIRQ = false
            if (value & 0x10) == 0 {
                dmcBytesRemaining = 0
            } else if dmcBytesRemaining == 0 {
                dmcCurrentAddress = dmcSampleAddress
                dmcBytesRemaining = dmcSampleLength
                // The DMA starts 2-3 cycles after the write, depending on CPU parity.
                dmcStartDelay = (cycle & 1) == 0 ? 2 : 3
            }
        case 0x4017:
            pendingFrameWrite = Int(value)
            // The write takes effect 3 or 4 CPU cycles later depending on APU cycle parity.
            frameWriteDelay = (cycle & 1) == 0 ? 3 : 4
            frameIRQInhibit = (value & 0x40) != 0
            if frameIRQInhibit { frameIRQ = false }
        default:
            break
        }
    }

    // MARK: - Clocking

    @inline(__always)
    func clock() {
        cycle &+= 1
        clockFrameCounter()

        pulse1.clockTimer()
        pulse2.clockTimer()
        triangle.clockTimer()
        noise.clockTimer()
        clockDMC()

        mix()
    }

    @inline(__always)
    func clockFrameCounter() {
        if pendingFrameWrite >= 0 {
            frameWriteDelay -= 1
            if frameWriteDelay <= 0 {
                frameMode = (pendingFrameWrite & 0x80) != 0 ? 1 : 0
                frameCycle = 0
                frameStep = 0
                nextFrameEvent = frameSteps[frameMode][0]
                pendingFrameWrite = -1
                if frameMode == 1 {
                    quarterFrame()
                    halfFrame()
                }
            }
        }
        frameCycle += 1
        if frameCycle == nextFrameEvent {
            switch APU.frameActions[frameMode][frameStep] {
            case 1: quarterFrame()
            case 2: quarterFrame(); halfFrame()
            default: break
            }
            if frameMode == 0 && frameStep >= 3 && !frameIRQInhibit {
                frameIRQ = true
            }
            frameStep += 1
            if frameStep == 6 {
                frameStep = 0
                frameCycle = 0
            }
            nextFrameEvent = frameSteps[frameMode][frameStep]
        }
    }

    func quarterFrame() {
        pulse1.envelope.clock()
        pulse2.envelope.clock()
        noise.envelope.clock()
        triangle.clockLinear()
    }

    func halfFrame() {
        pulse1.length.clock()
        pulse2.length.clock()
        triangle.length.clock()
        noise.length.clock()
        pulse1.clockSweep()
        pulse2.clockSweep()
    }

    @inline(__always)
    func clockDMC() {
        if dmcStartDelay > 0 {
            dmcStartDelay -= 1
            if dmcStartDelay == 0 && dmcBufferEmpty && dmcBytesRemaining > 0 {
                dmcDMARequest = true
            }
        }
        if dmcTimer > 0 {
            dmcTimer -= 1
            return
        }
        dmcTimer = dmcPeriod - 1
        if !dmcSilence {
            if (dmcShift & 1) != 0 {
                if dmcOutput <= 125 { dmcOutput += 2 }
            } else if dmcOutput >= 2 {
                dmcOutput -= 2
            }
        }
        dmcShift >>= 1
        dmcBitsRemaining -= 1
        if dmcBitsRemaining == 0 {
            dmcBitsRemaining = 8
            if dmcBufferEmpty {
                dmcSilence = true
            } else {
                dmcSilence = false
                dmcShift = dmcBuffer
                dmcBufferEmpty = true
                if dmcBytesRemaining > 0 { dmcDMARequest = true }
            }
        }
    }

    /// Address the next DMC DMA will read.
    var dmcDMAAddress: Int { dmcCurrentAddress }

    /// Completes a DMC DMA fetch.
    func setDMCBuffer(_ value: UInt8) {
        guard dmcBytesRemaining > 0 else { return }
        dmcBuffer = Int(value)
        dmcBufferEmpty = false
        dmcCurrentAddress = dmcCurrentAddress == 0xFFFF ? 0x8000 : dmcCurrentAddress + 1
        dmcBytesRemaining -= 1
        if dmcBytesRemaining == 0 {
            if dmcLoop {
                dmcCurrentAddress = dmcSampleAddress
                dmcBytesRemaining = dmcSampleLength
            } else if dmcIRQEnabled {
                dmcIRQ = true
            }
        }
    }

    // MARK: - Mixing

    @inline(__always)
    func mix() {
        let m = channelMask
        let p = ((m & 1) != 0 ? pulse1.output : 0) + ((m & 2) != 0 ? pulse2.output : 0)
        let tnd = 3 * ((m & 4) != 0 ? triangle.output : 0) + 2 * ((m & 8) != 0 ? noise.output : 0)
            + ((m & 16) != 0 ? dmcOutput : 0)
        var s = pulseLUT[p] + tndLUT[tnd]
        if hasExpansionAudio && (m & 32) != 0 { s += mapper.audioSample() }
        if s != lastAmplitude {
            blip.addDelta(s - lastAmplitude)
            lastAmplitude = s
        }
        blip.advance()
        if blip.available >= 1024 { flushAudio() }
    }

    /// Moves finished band-limited samples through the output filters into `samples`.
    func flushAudio() {
        let gain = 1.8 * volume * 32767
        blip.read { value in
            var out = hp1.process(value)
            out = hp2.process(out)
            out = lp.process(out)
            var scaled = out * gain
            if scaled > 32767 { scaled = 32767 } else if scaled < -32768 { scaled = -32768 }
            let sample = Int16(scaled)
            samples.append(sample)
            samples.append(sample)
        }
    }

    public func drainSamples() -> [Int16] {
        flushAudio()
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }

    // MARK: - Save states

    func saveState(_ w: inout StateWriter) {
        pulse1.save(&w); pulse2.save(&w); triangle.save(&w); noise.save(&w)
        w.write([dmcPeriod, dmcTimer, dmcOutput, dmcSampleAddress, dmcSampleLength, dmcCurrentAddress,
                 dmcBytesRemaining, dmcBuffer, dmcShift, dmcBitsRemaining, dmcStartDelay,
                 frameMode, frameCycle, frameStep, pendingFrameWrite, frameWriteDelay])
        w.write(dmcIRQEnabled); w.write(dmcLoop); w.write(dmcBufferEmpty); w.write(dmcSilence)
        w.write(frameIRQInhibit); w.write(frameIRQ); w.write(dmcIRQ)
        w.write(cycle)
    }

    func loadState(_ r: inout StateReader) throws {
        try pulse1.load(&r); try pulse2.load(&r); try triangle.load(&r); try noise.load(&r)
        let v = try r.readIntArray()
        guard v.count == 16 else { throw StateError.corrupt("APU") }
        dmcPeriod = max(v[0], 1); dmcTimer = v[1]; dmcOutput = v[2] & 0x7F; dmcSampleAddress = v[3]
        dmcSampleLength = v[4]; dmcCurrentAddress = v[5]; dmcBytesRemaining = v[6]; dmcBuffer = v[7]
        dmcShift = v[8]; dmcBitsRemaining = max(v[9], 1); dmcStartDelay = v[10]
        frameMode = v[11] & 1; frameCycle = v[12]; frameStep = min(max(v[13], 0), 5)
        nextFrameEvent = frameSteps[frameMode][frameStep]
        pendingFrameWrite = v[14]; frameWriteDelay = v[15]
        dmcIRQEnabled = try r.readBool(); dmcLoop = try r.readBool(); dmcBufferEmpty = try r.readBool()
        dmcSilence = try r.readBool(); frameIRQInhibit = try r.readBool(); frameIRQ = try r.readBool()
        dmcIRQ = try r.readBool()
        cycle = try r.readU64()
        samples.removeAll(keepingCapacity: true)
        blip.clear()
        lastAmplitude = 0
        hp1 = HighPass(); hp2 = HighPass(); lp = LowPass()
        configureFilters()
    }
}

public enum AudioFilter: Sendable, Equatable {
    case authentic, clean
}

/// First-order high-pass filter.
struct HighPass {
    var alpha: Float = 1
    var prevIn: Float = 0
    var prevOut: Float = 0

    init() {}
    init(cutoff: Float, sampleRate: Float) {
        let rc = 1 / (2 * Float.pi * cutoff)
        let dt = 1 / sampleRate
        alpha = rc / (rc + dt)
    }

    mutating func process(_ x: Float) -> Float {
        let y = alpha * (prevOut + x - prevIn)
        prevIn = x
        prevOut = y
        return y
    }
}

/// First-order low-pass filter.
struct LowPass {
    var alpha: Float = 1
    var prev: Float = 0

    init() {}
    init(cutoff: Float, sampleRate: Float) {
        let rc = 1 / (2 * Float.pi * cutoff)
        let dt = 1 / sampleRate
        alpha = dt / (rc + dt)
    }

    mutating func process(_ x: Float) -> Float {
        prev += alpha * (x - prev)
        return prev
    }
}

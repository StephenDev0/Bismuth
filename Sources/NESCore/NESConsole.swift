/// A complete NES / Famicom.
///
/// ```swift
/// let nes = try NESConsole(rom: romBytes)
/// nes.setButtons([.start], player: 0)
/// nes.runFrame()
/// nes.renderARGB(into: pixels)          // or hand `frameBuffer` to NESMetal
/// let audio = nes.drainAudio()          // interleaved stereo Int16
/// ```
public final class NESConsole {
    public let cartridge: Cartridge
    public let region: Region
    public private(set) var cpu: CPU
    public private(set) var ppu: PPU
    public private(set) var apu: APU
    public private(set) var mapper: Mapper
    public let input = InputPorts()
    public let cheats = CheatEngine()

    public var palette: NESPalette {
        didSet { input.setPalette(palette) }
    }
    public var ramInitPattern: RAMInitPattern

    /// Removes the 8-sprites-per-scanline limit (less flicker, not hardware accurate).
    public var unlimitedSprites: Bool {
        get { ppu.unlimitedSprites }
        set { ppu.unlimitedSprites = newValue }
    }

    public var sampleRate: Double {
        get { apu.sampleRate }
        set { apu.sampleRate = newValue; apu.configureFilters() }
    }

    /// Frames emulated since power-on.
    public var frameCount: UInt64 { ppu.frameCount }

    public init(cartridge: Cartridge, region: Region? = nil, sampleRate: Double = 48_000,
                palette: NESPalette? = nil, ramInitPattern: RAMInitPattern = .zeros) throws {
        self.cartridge = cartridge
        let region = region ?? cartridge.region ?? .ntsc
        self.region = region
        self.ramInitPattern = ramInitPattern
        self.palette = palette ?? (region == .ntsc ? .composite : .compositePAL)
        let mapper = try MapperFactory.make(for: cartridge)
        let ppu = PPU(region: region, mapper: mapper)
        let apu = APU(region: region, mapper: mapper, sampleRate: sampleRate)
        let cpu = CPU(region: region, ppu: ppu, apu: apu, mapper: mapper, input: input)
        self.mapper = mapper
        self.cpu = cpu
        self.ppu = ppu
        self.apu = apu
        wire()
        powerOn()
    }

    public convenience init(rom: [UInt8], region: Region? = nil, sampleRate: Double = 48_000,
                            palette: NESPalette? = nil, ramInitPattern: RAMInitPattern = .zeros) throws {
        try self.init(cartridge: Cartridge(data: rom), region: region, sampleRate: sampleRate,
                      palette: palette, ramInitPattern: ramInitPattern)
    }

    private func wire() {
        input.ppu = ppu
        input.setPalette(palette)
        mapper.cpuCycle = { [unowned cpu] in cpu.cycleCount }
    }

    private func powerOn() {
        cpu.ram.initialize(pattern: ramInitPattern)
        mapper.reset(hard: true)
        ppu.reset(hard: true)
        apu.reset(hard: true)
        cpu.powerOn()
    }

    // MARK: - Control

    /// Presses the reset button.
    public func reset() {
        mapper.reset(hard: false)
        ppu.reset(hard: false)
        apu.reset(hard: false)
        cpu.reset()
    }

    /// Turns the console off and on again. Battery-backed RAM survives.
    public func powerCycle() {
        let battery = mapper.batteryRAM?.bytes
        let newMapper = (try? MapperFactory.make(for: cartridge)) ?? mapper
        if let battery, let ram = newMapper.batteryRAM {
            battery.withUnsafeBufferPointer { ram.copy(from: $0.baseAddress!, count: $0.count) }
        }
        let newPPU = PPU(region: region, mapper: newMapper)
        let newAPU = APU(region: region, mapper: newMapper, sampleRate: apu.sampleRate)
        let newCPU = CPU(region: region, ppu: newPPU, apu: newAPU, mapper: newMapper, input: input)
        newAPU.volume = apu.volume
        newAPU.filter = apu.filter
        newAPU.channelMask = apu.channelMask
        newPPU.unlimitedSprites = ppu.unlimitedSprites
        mapper = newMapper; cpu = newCPU; ppu = newPPU; apu = newAPU
        wire()
        powerOn()
    }

    /// Emulates until the PPU finishes the next frame (~1/60 s of NES time).
    public func runFrame() {
        applyFreezes()
        ppu.frameReady = false
        let cpu = self.cpu, ppu = self.ppu
        while !ppu.frameReady {
            cpu.step()
        }
    }

    /// Emulates `count` CPU instructions (debugging and tests).
    public func step(instructions count: Int = 1) {
        for _ in 0..<count { cpu.step() }
    }

    private func applyFreezes() {
        guard !cheats.isEmpty else {
            cpu.cheats = nil
            return
        }
        cpu.cheats = cheats.patches.isEmpty ? nil : cheats
        for c in cheats.freezes {
            if c.address < 0x2000 {
                cpu.ram[c.address & 0x7FF] = c.value
            } else if c.address >= 0x6000 && c.address < 0x8000 {
                mapper.writeRAM(c.address, c.value)
            }
        }
    }

    // MARK: - Input

    public func setButtons(_ buttons: NESButtons, player: Int) {
        input.setButtons(buttons, player: player)
    }

    /// Plugs a device into port 0 (player 1) or 1 (player 2).
    public func setDevice(_ device: InputDevice, port: Int) {
        guard port == 0 || port == 1 else { return }
        input.devices[port] = device
    }

    /// Updates a Zapper's aim (NES pixels) and trigger.
    public func setZapper(port: Int, x: Int, y: Int, trigger: Bool, offscreen: Bool = false) {
        guard port == 0 || port == 1 else { return }
        input.zappers[port] = ZapperState(x: x, y: y, trigger: trigger, offscreen: offscreen)
    }

    // MARK: - Video

    /// 256x240 PPU pixel values (colour index | emphasis << 6).
    public var frameBuffer: UnsafePointer<UInt16> { UnsafePointer(ppu.frameBuffer) }

    /// Converts the frame to 0xAARRGGBB (also valid as libretro XRGB8888).
    /// - Parameters:
    ///   - pitch: destination row length in pixels.
    ///   - cropTop/Bottom/Left/Right: overscan to drop, in pixels.
    public func renderARGB(into destination: UnsafeMutablePointer<UInt32>, pitch: Int = 256,
                           cropTop: Int = 0, cropBottom: Int = 0, cropLeft: Int = 0, cropRight: Int = 0) {
        palette.argb.withUnsafeBufferPointer { lut in
            let lutBase = lut.baseAddress!
            let src = ppu.frameBuffer
            let w = 256 - cropLeft - cropRight
            for row in 0..<(240 - cropTop - cropBottom) {
                let s = src + (row + cropTop) * 256 + cropLeft
                let d = destination + row * pitch
                for x in 0..<w { d[x] = lutBase[Int(s[x] & 0x1FF)] }
            }
        }
    }

    /// Converts the frame to RGBA bytes (R,G,B,A order), 256*240*4 bytes.
    public func renderRGBA() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 256 * 240 * 4)
        let lut = palette.argb
        for i in 0..<(256 * 240) {
            let c = lut[Int(ppu.frameBuffer[i] & 0x1FF)]
            out[i * 4] = UInt8((c >> 16) & 0xFF)
            out[i * 4 + 1] = UInt8((c >> 8) & 0xFF)
            out[i * 4 + 2] = UInt8(c & 0xFF)
            out[i * 4 + 3] = 0xFF
        }
        return out
    }

    // MARK: - Audio

    /// Interleaved stereo 16-bit samples produced since the last call.
    public func drainAudio() -> [Int16] { apu.drainSamples() }

    /// Calls `body` with the pending samples without copying, then clears them.
    public func withAudio(_ body: (UnsafeBufferPointer<Int16>) -> Void) {
        apu.flushAudio()
        apu.samples.withUnsafeBufferPointer(body)
        apu.samples.removeAll(keepingCapacity: true)
    }

    /// Output filter chain (see `AudioFilter`).
    public var audioFilter: AudioFilter {
        get { apu.filter }
        set { apu.filter = newValue }
    }

    public var volume: Float {
        get { apu.volume }
        set { apu.volume = newValue }
    }

    // MARK: - Memory

    /// The 2KB of console work RAM ($0000-$07FF).
    public var systemRAM: ByteBuffer { cpu.ram }

    /// Battery-backed cartridge RAM (what frontends store as .srm / .sav), if any.
    public var batteryRAM: ByteBuffer? { mapper.batteryRAM }

    /// Cartridge work RAM mapped at $6000-$7FFF (battery backed or not), if the board has any.
    public var cartridgeRAM: ByteBuffer? { mapper.hasPRGRAM ? mapper.prgRAM : nil }

    /// Reads the CPU address space without triggering any side effects.
    public func peek(_ address: UInt16) -> UInt8 { cpu.peek(address) }

    /// Writes CPU work RAM or cartridge RAM directly (debuggers, cheat search).
    public func poke(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        if a < 0x2000 {
            cpu.ram[a & 0x7FF] = value
        } else if a >= 0x6000 && a < 0x8000 {
            mapper.writeRAM(a, value)
        }
    }

    // MARK: - Save states

    static let stateMagic: [UInt8] = Array("BSMT".utf8)   // "Bismuth state"
    static let stateVersion: UInt32 = 1

    public func saveState() -> [UInt8] {
        var w = StateWriter(capacity: 32 * 1024 + mapper.prgRAM.count + mapper.chr.count)
        for b in NESConsole.stateMagic { w.write(b) }
        w.write(NESConsole.stateVersion)
        w.write(cartridge.crc32)
        w.write(region.rawValue)
        cpu.saveState(&w)
        ppu.saveState(&w)
        apu.saveState(&w)
        mapper.saveState(&w)
        input.saveState(&w)
        return w.data
    }

    public func loadState(_ data: [UInt8]) throws {
        var r = StateReader(data)
        for b in NESConsole.stateMagic { guard try r.readU8() == b else { throw StateError.badMagic } }
        let version = try r.readU32()
        guard version == NESConsole.stateVersion else { throw StateError.unsupportedVersion(version) }
        guard try r.readU32() == cartridge.crc32 else { throw StateError.wrongGame }
        guard try r.readU8() == region.rawValue else { throw StateError.corrupt("region") }
        // Restore into a scratch copy first so a corrupt state never leaves the console half-loaded.
        let backup = saveState()
        do {
            try cpu.loadState(&r)
            try ppu.loadState(&r)
            try apu.loadState(&r)
            try mapper.loadState(&r)
            try input.loadState(&r)
        } catch {
            var restore = StateReader(backup)
            restore.skip(4 + 4 + 4 + 1)
            try? cpu.loadState(&restore)
            try? ppu.loadState(&restore)
            try? apu.loadState(&restore)
            try? mapper.loadState(&restore)
            try? input.loadState(&restore)
            throw error
        }
    }
}

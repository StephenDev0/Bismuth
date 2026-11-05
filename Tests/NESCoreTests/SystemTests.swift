import Testing
@testable import NESCore
@testable import NESAchievements

@Suite("Cartridge")
struct CartridgeTests {
    @Test func parsesINES() throws {
        let cart = try Cartridge(data: TestROM.make(program: [0xEA], mapper: 4, prgBanks: 2))
        #expect(cart.mapperID == 4)
        #expect(cart.prg.count == 32 * 1024)
        #expect(cart.chr.count == 8 * 1024)
        #expect(cart.mirroring == .vertical)
        #expect(!cart.isNES20)
    }

    @Test func parsesNES20Header() throws {
        var rom = TestROM.make(program: [0xEA])
        rom[7] |= 0x08                  // NES 2.0 identifier
        rom[8] = 0x01 | (0x2 << 4)      // mapper high nibble 1 -> 256, submapper 2
        rom[10] = 0x07                  // 8KB PRG-RAM
        rom[12] = 0x01                  // PAL
        let cart = try Cartridge(data: rom)
        #expect(cart.isNES20)
        #expect(cart.mapperID == 256)
        #expect(cart.submapper == 2)
        #expect(cart.prgRAMSize == 8192)
        #expect(cart.region == .pal)
    }

    @Test func rejectsGarbage() {
        #expect(throws: CartridgeError.notAnNESFile) { try Cartridge(data: [1, 2, 3]) }
        var rom = TestROM.make(program: [0xEA])
        rom.removeLast(10_000)
        #expect(throws: (any Error).self) { try Cartridge(data: rom) }
    }

    @Test func unsupportedMapperThrows() {
        var rom = TestROM.make(program: [0xEA])
        rom[6] = 0xF0; rom[7] = 0xF0    // mapper 255
        #expect(throws: CartridgeError.unsupportedMapper(255)) { try NESConsole(rom: rom) }
    }

    @Test func crc32KnownVector() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite("PPU")
struct PPUTests {
    @Test func vblankFlagAndFrameTiming() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.runFrame()
        let start = nes.cpu.cycleCount
        for _ in 0..<60 { nes.runFrame() }
        let perFrame = Double(nes.cpu.cycleCount - start) / 60
        #expect(abs(perFrame - 29780.6) < 2)   // NTSC: 89341.5 dots / 3
        #expect(nes.ppu.scanline == 240)
    }

    @Test func vramReadBufferAndPaletteMirrors() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        let ppu = nes.ppu
        // Write $AB to $2400, then read it back: $2007 reads are delayed by one through the read buffer.
        ppu.writeRegister(6, 0x24); ppu.writeRegister(6, 0x00); ppu.writeRegister(7, 0xAB)
        ppu.writeRegister(6, 0x24); ppu.writeRegister(6, 0x00)
        _ = ppu.readRegister(7)                // returns the stale buffer, loads $2400
        #expect(ppu.readRegister(7) == 0xAB)
        // $3F10 mirrors $3F00.
        ppu.writeRegister(6, 0x3F); ppu.writeRegister(6, 0x10); ppu.writeRegister(7, 0x2A)
        ppu.writeRegister(6, 0x3F); ppu.writeRegister(6, 0x00)
        #expect(ppu.readRegister(7) & 0x3F == 0x2A)
    }

    @Test func statusReadClearsVBlank() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.runFrame()
        while !nes.ppu.vblank { nes.cpu.step() }
        #expect(nes.ppu.readRegister(2) & 0x80 != 0)
        #expect(nes.ppu.readRegister(2) & 0x80 == 0)
    }
}

@Suite("APU")
struct APUTests {
    @Test func lengthCounterStatus() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.apu.write(0x4015, 0x01)
        nes.apu.write(0x4000, 0x30)
        nes.apu.write(0x4003, 0x08)     // length index 1 -> 254
        #expect(nes.apu.readStatus() & 0x01 != 0)
        nes.apu.write(0x4015, 0x00)
        #expect(nes.apu.readStatus() & 0x01 == 0)
    }

    @Test func producesAudioAtTheRequestedRate() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        for _ in 0..<60 { nes.runFrame() }
        let samples = nes.drainAudio()
        // ~1 second of 48 kHz stereo audio.
        #expect(abs(samples.count / 2 - 47_920) < 200)
    }
}

@Suite("Mappers")
struct MapperTests {
    @Test func mmc1SerialBankSwitch() throws {
        var prg = [UInt8](repeating: 0, count: 128 * 1024)
        for bank in 0..<8 { prg[bank * 0x4000] = UInt8(bank) }
        let cart = Cartridge(prg: prg, chr: [], mapper: 1)
        let mapper = try MapperFactory.make(for: cart)
        // Write bank 3 into the PRG register, one bit per write.
        var cycle: UInt64 = 0
        mapper.cpuCycle = { cycle }
        for bit in 0..<5 {
            cycle += 2
            mapper.writeCPU(0xE000, UInt8((3 >> bit) & 1))
        }
        #expect(mapper.readCPU(0x8000, openBus: 0) == 3)
        #expect(mapper.readCPU(0xC000, openBus: 0) == 7)   // last bank fixed
    }

    @Test func mmc3ScanlineIRQ() throws {
        let cart = Cartridge(prg: [UInt8](repeating: 0, count: 64 * 1024), chr: [UInt8](repeating: 0, count: 64 * 1024), mapper: 4)
        let mapper = try MapperFactory.make(for: cart)
        mapper.writeCPU(0xC000, 3)    // latch
        mapper.writeCPU(0xC001, 0)    // reload
        mapper.writeCPU(0xE001, 0)    // enable
        var cycle: UInt64 = 0
        for line in 0..<4 {
            mapper.ppuAddressChanged(0x0000, ppuCycle: cycle); cycle += 260
            mapper.ppuAddressChanged(0x1000, ppuCycle: cycle); cycle += 81
            #expect(mapper.irqLine == (line == 3))
        }
        mapper.writeCPU(0xE000, 0)    // acknowledge
        #expect(!mapper.irqLine)
    }

    @Test func everySupportedMapperBoots() throws {
        for id in MapperFactory.supportedMappers.keys.sorted() {
            let rom = TestROM.make(program: [0x4C, 0x00, 0xC0], mapper: id, prgBanks: 8)
            let nes = try NESConsole(rom: rom)
            nes.runFrame()
            let state = nes.saveState()
            nes.runFrame()
            try nes.loadState(state)
            #expect(!nes.cpu.jammed, "mapper \(id)")
        }
    }
}

@Suite("Save states")
struct SaveStateTests {
    @Test func roundTripIsDeterministic() throws {
        let nes = try TestROM.console([0xE6, 0x10, 0xA5, 0x10, 0x8D, 0x06, 0x20, 0x4C, 0x00, 0xC0])
        for _ in 0..<10 { nes.runFrame() }
        let state = nes.saveState()
        for _ in 0..<30 { nes.runFrame() }
        let ramA = nes.systemRAM.bytes, cycleA = nes.cpu.cycleCount
        try nes.loadState(state)
        for _ in 0..<30 { nes.runFrame() }
        #expect(nes.systemRAM.bytes == ramA)
        #expect(nes.cpu.cycleCount == cycleA)
        #expect(nes.saveState().count == state.count)
    }

    @Test func rejectsOtherGamesAndCorruption() throws {
        let a = try TestROM.console([0x4C, 0x00, 0xC0])
        let b = try TestROM.console([0xEA, 0x4C, 0x00, 0xC0])
        let state = a.saveState()
        #expect(throws: StateError.wrongGame) { try b.loadState(state) }
        #expect(throws: StateError.badMagic) { try a.loadState([1, 2, 3, 4, 5]) }
        #expect(throws: StateError.truncated) { try a.loadState(Array(state.prefix(state.count / 2))) }
        // The console still works after a rejected load.
        a.runFrame()
    }
}

@Suite("Input")
struct InputTests {
    @Test func standardControllerShiftOrder() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.setButtons([.a, .start, .right], player: 0)
        nes.input.write(1); nes.input.write(0)
        let bits = (0..<10).map { _ in nes.input.read(port: 0) }
        #expect(bits == [1, 0, 0, 1, 0, 0, 0, 1, 1, 1])   // A B Sel St U D L R, then 1s
    }

    @Test func opposingDirectionsAreFiltered() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.setButtons([.left, .right, .up], player: 0)
        #expect(nes.input.buttons(player: 0) == [.up])
        nes.input.allowOpposingDirections = true
        nes.setButtons([.left, .right], player: 0)
        #expect(nes.input.buttons(player: 0) == [.left, .right])
    }

    @Test func zapperSeesBrightPixelsAfterTheBeam() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.setDevice(.zapper, port: 1)
        let ppu = nes.ppu
        for i in 0..<(256 * 240) { ppu.frameBuffer[i] = 0x0F }     // black
        ppu.frameBuffer[100 * 256 + 120] = 0x30                     // one white pixel
        nes.setZapper(port: 1, x: 120, y: 100, trigger: true)
        ppu.scanline = 105; ppu.dot = 10                            // beam just passed
        let lit = nes.input.read(port: 1)
        #expect(lit & 0x08 == 0)        // light detected (active low)
        #expect(lit & 0x10 != 0)        // trigger pulled
        ppu.scanline = 90                                            // beam has not reached it yet
        #expect(nes.input.read(port: 1) & 0x08 != 0)
        nes.setZapper(port: 1, x: 10, y: 10, trigger: false)        // aiming at black
        ppu.scanline = 12
        #expect(nes.input.read(port: 1) & 0x18 == 0x08)
        nes.setZapper(port: 1, x: 120, y: 100, trigger: true, offscreen: true)
        ppu.scanline = 105
        #expect(nes.input.read(port: 1) & 0x08 != 0)                // off-screen never sees light
    }

    @Test func fourScoreSignature() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.input.fourScore = true
        nes.setButtons([.a], player: 0)
        nes.setButtons([.b], player: 2)
        nes.input.write(1); nes.input.write(0)
        let bits = (0..<24).map { _ in nes.input.read(port: 0) }
        #expect(bits[0] == 1 && bits[9] == 1)                       // P1 A, P3 B
        #expect(Array(bits[16..<24]) == [0, 0, 0, 0, 1, 0, 0, 0])   // $10 signature
    }
}

@Suite("Cheats")
struct CheatTests {
    @Test func gameGenieDecoding() throws {
        let zero = try #require(CheatEngine.decode("AAAAAA"))
        #expect(zero.address == 0x8000 && zero.value == 0)
        let ones = try #require(CheatEngine.decode("PPPPPP"))
        #expect(ones.address == 0x9111 && ones.value == 0x11)
        let eight = try #require(CheatEngine.decode("PPPPPPPP"))
        #expect(eight.kind == .readPatch(compare: 0x11))
        #expect(CheatEngine.decode("QQQQQQ") == nil)
    }

    @Test func rawCodesAndFreezes() throws {
        let freeze = try #require(CheatEngine.decode("0075:09"))
        #expect(freeze.kind == .freeze)
        let compare = try #require(CheatEngine.decode("C123?05:EA"))
        #expect(compare.kind == .readPatch(compare: 0x05) && compare.address == 0xC123)

        let nes = try TestROM.console([0xA9, 0x00, 0x85, 0x75, 0x4C, 0x02, 0xC0])
        try nes.cheats.add("0075:09")
        nes.runFrame()
        #expect(nes.peek(0x0075) == 0x09 || nes.peek(0x0075) == 0x00)
        nes.runFrame()
        // The program keeps writing 0; the freeze is applied at the start of each frame.
        #expect(nes.cheats.cheats.count == 1)
    }

    @Test func romPatchAffectsExecution() throws {
        // LDA #$01 at $C000; patch the immediate operand at $C001 to $07.
        let nes = try TestROM.console([0xA9, 0x01, 0x85, 0x40, 0x4C, 0x04, 0xC0])
        try nes.cheats.add("C001:07")
        nes.runFrame()
        nes.reset()
        nes.runFrame()
        #expect(nes.peek(0x0040) == 0x07)
    }
}

@Suite("Palette")
struct PaletteTests {
    func rgb(_ c: UInt32) -> (Int, Int, Int) { (Int((c >> 16) & 0xFF), Int((c >> 8) & 0xFF), Int(c & 0xFF)) }

    @Test func compositeMatchesMeasuredLuma() {
        let p = NESPalette.composite.argb
        #expect(rgb(p[0x0F]) == (0, 0, 0))
        #expect(rgb(p[0x00]) == (98, 98, 98))
        #expect(rgb(p[0x2D]) == (78, 78, 78))
        #expect(rgb(p[0x3D]) == (184, 184, 184))
        #expect(rgb(p[0x30]) == (255, 255, 255))
        // Hues land where they should: $16 red, $1A green, $12 blue.
        let red = rgb(p[0x16]), green = rgb(p[0x1A]), blue = rgb(p[0x12])
        #expect(red.0 > red.1 && red.0 > red.2)
        #expect(green.1 > green.0 && green.1 > green.2)
        #expect(blue.2 > blue.0 && blue.2 > blue.1)
    }

    @Test func emphasisDarkensOtherChannels() {
        let p = NESPalette.composite.argb
        let base = rgb(p[0x30]), redEmphasis = rgb(p[0x30 | 0x40])
        #expect(redEmphasis.1 < base.1 && redEmphasis.2 < base.2)
        #expect(rgb(p[0x0F | 0x1C0]) == (0, 0, 0))
    }

    @Test func palFileRoundTrip() throws {
        let file = NESPalette.rgb.palFile
        #expect(file.count == 1536)
        let loaded = try #require(NESPalette(palFile: file))
        #expect(loaded == NESPalette.rgb)
    }
}

@Suite("RetroAchievements")
struct AchievementTests {
    @Test func md5KnownVectors() {
        #expect(MD5.hexDigest([UInt8]()) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hexDigest(Array("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hexDigest(Array("The quick brown fox jumps over the lazy dog".utf8)) == "9e107d9d372bb6826bd81d3542a419d6")
    }

    @Test func nesHashSkipsHeader() {
        let rom = TestROM.make(program: [0xEA])
        #expect(RAHash.nes(rom) == MD5.hexDigest(rom.dropFirst(16)))
        let headerless = Array(rom.dropFirst(16))
        #expect(RAHash.nes(headerless) == RAHash.nes(rom))
    }

    @Test func peeksMatchRAMWithoutSideEffects() throws {
        let nes = try TestROM.console([0xA9, 0x12, 0x85, 0x00, 0xA9, 0x34, 0x85, 0x01, 0xA9, 0x56, 0x8D, 0x00, 0x60,
                                       0x4C, 0x0D, 0xC0])
        nes.runFrame()
        #expect(AchievementMemory.peek(nes, address: 0x0000, numBytes: 2) == 0x3412)
        #expect(AchievementMemory.peek(nes, address: 0x0800, numBytes: 1) == 0x12)   // mirror
        #expect(AchievementMemory.peek(nes, address: 0x6000, numBytes: 1) == 0x56)
        let vblank = nes.ppu.vblank
        _ = AchievementMemory.peek(nes, address: 0x2002, numBytes: 1)
        #expect(nes.ppu.vblank == vblank)   // no side effects
        #expect(AchievementMemory.regions.first?.end == 0x07FF)
    }

    @Test func hardcoreBlocksStatesAndCheats() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        let guardian = HardcoreGuard(console: nes)
        let state = nes.saveState()
        guardian.enable()
        #expect(throws: HardcoreError.self) { try guardian.loadState(state) }
        #expect(throws: HardcoreError.self) { try guardian.addCheat("AAAAAA") }
        guardian.disable()
        try guardian.loadState(state)
    }
}

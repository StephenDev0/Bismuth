/// Base class for cartridge boards.
///
/// Banking is expressed with offset tables: four 8KB CPU windows ($8000-$FFFF), one 8KB
/// PRG-RAM window ($6000-$7FFF), eight 1KB CHR windows ($0000-$1FFF) and four 1KB nametable
/// windows ($2000-$2FFF). Most boards only need to update those tables from `writeRegister`.
open class Mapper {
    public let cartridge: Cartridge

    public let prg: ByteBuffer
    public let chr: ByteBuffer
    public let chrWritable: Bool
    public let prgRAM: ByteBuffer
    public let hasPRGRAM: Bool
    /// CIRAM (2KB) plus 2KB for four-screen boards.
    public let vram: ByteBuffer

    public let prgOffsets = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    public let chrOffsets = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    public let ntOffsets = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    public var prgRAMOffset = 0
    public var prgRAMEnabled = true
    public var prgRAMWritable = true
    public private(set) var mirroring: Mirroring = .horizontal

    /// Mapper IRQ output (active high, level triggered).
    public var irqLine = false

    // Capabilities, read by the console once at load time.
    public var needsCPUClock = false
    public var needsPPUAddressNotifications = false
    public var hasExpansionAudio = false

    /// Set by the console; gives boards access to the CPU cycle counter.
    public internal(set) var cpuCycle: () -> UInt64 = { 0 }

    public var prgBankCount8k: Int { prg.count / 0x2000 }
    public var chrBankCount1k: Int { chr.count / 0x400 }

    public required init(cartridge: Cartridge) {
        self.cartridge = cartridge
        // Pad tiny PRG images so 8KB windows never read past the end.
        var prgData = cartridge.prg
        while prgData.count < 0x2000 { prgData += cartridge.prg }
        let prgPow2 = Mapper.nextPowerOfTwo(prgData.count)
        if prgPow2 != prgData.count {
            // Non power-of-two images: mirror the tail so masking stays valid.
            var padded = prgData
            while padded.count < prgPow2 { padded.append(prgData[padded.count % prgData.count]) }
            prgData = padded
        }
        prg = ByteBuffer(prgData)

        let chrRAMSize = max(cartridge.chrRAMSize, Self.minimumCHRRAM)
        if cartridge.chr.isEmpty {
            chr = ByteBuffer(count: chrRAMSize)
            chrWritable = true
        } else {
            var chrData = cartridge.chr
            while chrData.count < 0x2000 { chrData += cartridge.chr }
            chr = ByteBuffer(chrData)
            chrWritable = false
        }
        hasPRGRAM = cartridge.prgRAMSize > 0 || Self.alwaysHasPRGRAM
        let ramSize = Mapper.nextPowerOfTwo(max(cartridge.prgRAMSize, 0x2000))
        prgRAM = ByteBuffer(count: ramSize)
        vram = ByteBuffer(count: 0x1000)
        for i in 0..<4 { prgOffsets[i] = 0 }
        for i in 0..<8 { chrOffsets[i] = 0 }
        for i in 0..<4 { ntOffsets[i] = 0 }
        if let trainer = cartridge.trainer {
            for (i, b) in trainer.enumerated() { prgRAM[0x1000 + i] = b }
        }
        setMirroring(cartridge.mirroring)
        setPRG32k(0)
        setCHR8k(0)
    }

    deinit {
        prgOffsets.deallocate()
        chrOffsets.deallocate()
        ntOffsets.deallocate()
    }

    /// Minimum CHR-RAM to allocate for boards with CHR-RAM (some need more than 8KB).
    open class var minimumCHRRAM: Int { 0x2000 }
    /// Boards that always provide $6000-$7FFF RAM regardless of the header.
    open class var alwaysHasPRGRAM: Bool { true }

    static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    // MARK: - Lifecycle

    /// Called on power-on (`hard == true`) and on the reset button.
    open func reset(hard: Bool) {}

    // MARK: - CPU bus

    @inline(__always)
    public final func readPRG(_ address: Int) -> UInt8 {
        prg.pointer[prgOffsets[(address >> 13) & 3] &+ (address & 0x1FFF)]
    }

    open func readCPU(_ address: Int, openBus: UInt8) -> UInt8 {
        if address >= 0x8000 {
            return prg.pointer[prgOffsets[(address >> 13) & 3] &+ (address & 0x1FFF)]
        }
        if address >= 0x6000 {
            if hasPRGRAM && prgRAMEnabled {
                return prgRAM.pointer[(prgRAMOffset &+ (address & 0x1FFF)) & (prgRAM.count - 1)]
            }
            return openBus
        }
        return openBus
    }

    open func writeCPU(_ address: Int, _ value: UInt8) {
        if address >= 0x8000 {
            writeRegister(address, value)
        } else if address >= 0x6000 {
            writeRAM(address, value)
        } else {
            writeLow(address, value)
        }
    }

    @inline(__always)
    public final func writeRAM(_ address: Int, _ value: UInt8) {
        if hasPRGRAM && prgRAMEnabled && prgRAMWritable {
            prgRAM.pointer[(prgRAMOffset &+ (address & 0x1FFF)) & (prgRAM.count - 1)] = value
        }
    }

    /// Writes to $8000-$FFFF.
    open func writeRegister(_ address: Int, _ value: UInt8) {}
    /// Writes to $4020-$5FFF.
    open func writeLow(_ address: Int, _ value: UInt8) {}

    /// Side-effect-free read used by debuggers, cheats and RetroAchievements.
    open func peekCPU(_ address: Int) -> UInt8 {
        readCPU(address, openBus: 0)
    }

    // MARK: - PPU bus

    open func readPPU(_ address: Int) -> UInt8 {
        if address < 0x2000 {
            return chr.pointer[chrOffsets[address >> 10] &+ (address & 0x3FF)]
        }
        return vram.pointer[ntOffsets[(address >> 10) & 3] &+ (address & 0x3FF)]
    }

    open func writePPU(_ address: Int, _ value: UInt8) {
        if address < 0x2000 {
            if chrWritable { chr.pointer[chrOffsets[address >> 10] &+ (address & 0x3FF)] = value }
        } else {
            vram.pointer[ntOffsets[(address >> 10) & 3] &+ (address & 0x3FF)] = value
        }
    }

    /// Called with every PPU bus address when `needsPPUAddressNotifications` is set.
    open func ppuAddressChanged(_ address: Int, ppuCycle: UInt64) {}

    /// True while the PPU is fetching sprite patterns (dots 257-320). Used by MMC5.
    public var ppuFetchingSprites = false
    /// True while the PPU renders 8x16 sprites. Used by MMC5.
    public var ppuLargeSprites = false
    /// True while rendering is enabled. Used by MMC5.
    public var ppuRenderingEnabled = false

    // MARK: - Timing / audio

    /// Called once per CPU cycle when `needsCPUClock` is set.
    open func clockCPU() {}

    /// Expansion audio output, roughly on the same scale as one APU pulse channel (0...~0.15).
    open func audioSample() -> Float { 0 }

    // MARK: - Banking helpers

    public final func setPRG8k(_ slot: Int, _ bank: Int) {
        let count = prgBankCount8k
        var b = bank % count
        if b < 0 { b += count }
        prgOffsets[slot & 3] = b * 0x2000
    }

    public final func setPRG16k(_ slot: Int, _ bank: Int) {
        setPRG8k(slot * 2, bank * 2)
        setPRG8k(slot * 2 + 1, bank * 2 + 1)
    }

    public final func setPRG32k(_ bank: Int) {
        for i in 0..<4 { setPRG8k(i, bank * 4 + i) }
    }

    public final func setPRGRAM8k(_ bank: Int) {
        let count = max(prgRAM.count / 0x2000, 1)
        var b = bank % count
        if b < 0 { b += count }
        prgRAMOffset = b * 0x2000
    }

    public final func setCHR1k(_ slot: Int, _ bank: Int) {
        let count = chrBankCount1k
        var b = bank % count
        if b < 0 { b += count }
        chrOffsets[slot & 7] = b * 0x400
    }

    public final func setCHR2k(_ slot: Int, _ bank: Int) {
        setCHR1k(slot * 2, bank * 2)
        setCHR1k(slot * 2 + 1, bank * 2 + 1)
    }

    public final func setCHR4k(_ slot: Int, _ bank: Int) {
        for i in 0..<4 { setCHR1k(slot * 4 + i, bank * 4 + i) }
    }

    public final func setCHR8k(_ bank: Int) {
        for i in 0..<8 { setCHR1k(i, bank * 8 + i) }
    }

    public final func setMirroring(_ m: Mirroring) {
        mirroring = m
        switch m {
        case .horizontal: setNametables(0, 0, 1, 1)
        case .vertical: setNametables(0, 1, 0, 1)
        case .singleScreenA: setNametables(0, 0, 0, 0)
        case .singleScreenB: setNametables(1, 1, 1, 1)
        case .fourScreen: setNametables(0, 1, 2, 3)
        }
    }

    /// Points each nametable at a 1KB page of VRAM (0-1 = CIRAM, 2-3 = four-screen RAM).
    public final func setNametables(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        ntOffsets[0] = a * 0x400
        ntOffsets[1] = b * 0x400
        ntOffsets[2] = c * 0x400
        ntOffsets[3] = d * 0x400
    }

    public final func setNametable(_ index: Int, page: Int) {
        ntOffsets[index & 3] = page * 0x400
    }

    // MARK: - Battery

    /// Battery-backed memory exposed to the frontend (.srm), or nil.
    open var batteryRAM: ByteBuffer? { cartridge.hasBattery ? prgRAM : nil }

    // MARK: - Save states

    open func saveState(_ w: inout StateWriter) {
        w.write(prgRAM)
        if chrWritable { w.write(chr) }
        w.write(vram)
        for i in 0..<4 { w.write(prgOffsets[i]) }
        for i in 0..<8 { w.write(chrOffsets[i]) }
        for i in 0..<4 { w.write(ntOffsets[i]) }
        w.write(prgRAMOffset)
        w.write(prgRAMEnabled)
        w.write(prgRAMWritable)
        w.write(mirroring.rawValue)
        w.write(irqLine)
    }

    open func loadState(_ r: inout StateReader) throws {
        try r.read(into: prgRAM)
        if chrWritable { try r.read(into: chr) }
        try r.read(into: vram)
        for i in 0..<4 { prgOffsets[i] = try Self.checked(r.readInt(), limit: prg.count - 0x2000) }
        for i in 0..<8 { chrOffsets[i] = try Self.checked(r.readInt(), limit: chr.count - 0x400) }
        for i in 0..<4 { ntOffsets[i] = try Self.checked(r.readInt(), limit: vram.count - 0x400) }
        prgRAMOffset = try r.readInt()
        prgRAMEnabled = try r.readBool()
        prgRAMWritable = try r.readBool()
        mirroring = Mirroring(rawValue: try r.readU8()) ?? .horizontal
        irqLine = try r.readBool()
    }

    static func checked(_ v: Int, limit: Int) throws -> Int {
        guard v >= 0 && v <= limit else { throw StateError.corrupt("bank offset") }
        return v
    }
}

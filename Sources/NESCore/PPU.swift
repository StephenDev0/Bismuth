/// Ricoh 2C02 / 2C07 picture processing unit, emulated dot by dot.
///
/// The frame buffer holds 9-bit pixel values: bits 0-5 are the NES colour index, bits 6-8
/// the emphasis bits normalised to R,G,B order. Convert with `NESPalette`.
public final class PPU {
    public static let width = 256
    public static let height = 240

    let region: Region
    let mapper: Mapper
    /// NMI output line (vblank && NMI enabled), sampled by the CPU every cycle.
    var nmiOutput = false

    // Timing
    public internal(set) var scanline = 0
    public internal(set) var dot = 0
    public private(set) var frameCount: UInt64 = 0
    var oddFrame = false
    var masterClock: UInt64 = 0
    var ppuCycle: UInt64 = 0
    let ppuDivider: UInt64
    let preRenderLine: Int
    let vblankLine: Int

    // Registers
    var v = 0, t = 0, fineX = 0
    var w = false
    var ctrl: UInt8 = 0
    var mask: UInt8 = 0
    var vblank = false, sprite0Hit = false, spriteOverflow = false
    var preventVBlank = false
    var readBuffer: UInt8 = 0
    var oamAddr: UInt8 = 0
    var openBus: UInt8 = 0
    var openBusDecay = [Int](repeating: 0, count: 8)

    // Derived control/mask state
    var nmiEnabled = false
    var vramIncrement = 1
    var spritePatternBase = 0
    var bgPatternBase = 0
    var tallSprites = false
    var showBG = false, showSprites = false, showBGLeft = false, showSpritesLeft = false
    var greyscaleMask = 0x3F
    var emphasis = 0
    var renderingEnabled = false

    // Memory
    let palette = ByteBuffer(count: 32)
    let paletteRAM: UnsafeMutablePointer<UInt8>
    let oam = ByteBuffer(count: 256)
    let secondaryOAM = ByteBuffer(count: 32)
    /// 256x240 pixels, see type documentation.
    public let frameBuffer = UnsafeMutablePointer<UInt16>.allocate(capacity: 256 * 240)

    // Background pipeline
    var ntLatch = 0, atLatch = 0, patLoLatch = 0, patHiLatch = 0
    var bgLo = 0, bgHi = 0, atLo = 0, atHi = 0

    // Sprite pipeline: pixels for the next / current line
    var spriteCount = 0
    var nextSprite0 = false
    var lineSprite0 = false
    var spritePatLo = [Int](repeating: 0, count: 8)
    var spritePatHi = [Int](repeating: 0, count: 8)
    /// Per-pixel sprite output for the line being drawn: bits 0-1 colour, 2-3 palette,
    /// bit 5 = behind background, bit 6 = from sprite 0, 0 = transparent.
    let spriteLine = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    let nextSpriteLine = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)

    /// Disable the 8-sprites-per-line limit (removes flicker, not hardware accurate).
    public var unlimitedSprites = false
    var extraSprites = [(y: Int, tile: Int, attr: Int, x: Int)]()

    /// Called when a frame finishes (scanline 240 starts).
    var frameReady = false

    init(region: Region, mapper: Mapper) {
        self.region = region
        self.mapper = mapper
        ppuDivider = region.ppuDivider
        preRenderLine = region.scanlinesPerFrame - 1
        vblankLine = region.vblankScanline
        paletteRAM = palette.pointer
        frameBuffer.initialize(repeating: 0x0F, count: 256 * 240)
        spriteLine.initialize(repeating: 0, count: 256)
        nextSpriteLine.initialize(repeating: 0, count: 256)
        reset(hard: true)
    }

    deinit {
        frameBuffer.deallocate()
        spriteLine.deallocate()
        nextSpriteLine.deallocate()
    }

    func reset(hard: Bool) {
        writeCtrl(0)
        writeMask(0)
        w = false
        readBuffer = 0
        fineX = 0
        t = 0
        if hard {
            v = 0
            vblank = false; sprite0Hit = false; spriteOverflow = false
            oamAddr = 0
            oam.fill(0)
            // Power-up palette commonly observed on 2C02G.
            let initial: [UInt8] = [0x09, 0x01, 0x00, 0x01, 0x00, 0x02, 0x02, 0x0D, 0x08, 0x10, 0x08, 0x24,
                                    0x00, 0x00, 0x04, 0x2C, 0x09, 0x01, 0x34, 0x03, 0x00, 0x04, 0x00, 0x14,
                                    0x08, 0x3A, 0x00, 0x02, 0x00, 0x20, 0x2C, 0x08]
            for (i, b) in initial.enumerated() { palette[i] = b }
            scanline = 0
            dot = 0
            oddFrame = false
        }
    }

    // MARK: - Clocking

    /// Runs the PPU until its master clock reaches `target`.
    @inline(__always)
    func run(until target: UInt64) {
        while masterClock &+ ppuDivider <= target {
            step()
            masterClock &+= ppuDivider
        }
    }

    @inline(__always)
    func step() {
        ppuCycle &+= 1
        if scanline < 240 {
            if renderingEnabled {
                renderDot(visible: true)
            } else if dot >= 1 && dot <= 256 {
                // Rendering disabled: output the backdrop, or the colour at v if it points into palette RAM.
                let color = (v & 0x3F00) == 0x3F00 ? Int(palette[v & 0x1F]) : Int(palette[0])
                frameBuffer[scanline * 256 + dot - 1] = UInt16((color & greyscaleMask) | emphasis)
            }
        } else if scanline == preRenderLine {
            if dot == 1 {
                vblank = false
                sprite0Hit = false
                spriteOverflow = false
                updateNMI()
            }
            if renderingEnabled {
                renderDot(visible: false)
                if dot >= 280 && dot <= 304 {
                    // Copy vertical scroll bits from t to v.
                    v = (v & ~0x7BE0) | (t & 0x7BE0)
                }
            }
        } else if scanline == vblankLine && dot == 1 {
            if !preventVBlank {
                vblank = true
                updateNMI()
            }
            preventVBlank = false
        }

        // Advance.
        if dot == 339 && scanline == preRenderLine && oddFrame && renderingEnabled && region == .ntsc {
            dot = 340   // skip the last dot of the pre-render line on odd frames
        }
        dot += 1
        if dot > 340 {
            dot = 0
            scanline += 1
            if scanline == 240 {
                frameReady = true
                frameCount &+= 1
                decayOpenBus()
            } else if scanline > preRenderLine {
                scanline = 0
                oddFrame.toggle()
            }
        }
    }

    @inline(__always)
    func renderDot(visible: Bool) {
        let d = dot
        if (d >= 2 && d <= 257) || (d >= 322 && d <= 337) {
            bgLo <<= 1; bgHi <<= 1; atLo <<= 1; atHi <<= 1
        }
        // Reloads below only touch the low byte, so drawing before them is safe.
        if visible && d >= 1 && d <= 256 {
            drawPixel(d - 1)
        }

        if (d >= 1 && d <= 256) || (d >= 321 && d <= 336) {
            switch d & 7 {
            case 1:
                if d >= 9 && d != 321 { reloadShifters() }
                ntLatch = Int(ppuBusRead(0x2000 | (v & 0x0FFF)))
            case 3:
                let at = Int(ppuBusRead(0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x38) | ((v >> 2) & 0x07)))
                let shift = ((v >> 4) & 4) | (v & 2)
                atLatch = (at >> shift) & 3
            case 5:
                patLoLatch = Int(ppuBusRead(bgPatternBase | ntLatch << 4 | (v >> 12) & 7))
            case 7:
                patHiLatch = Int(ppuBusRead(bgPatternBase | ntLatch << 4 | 8 | (v >> 12) & 7))
            case 0:
                incrementX()
                if d == 256 { incrementY() }
            default:
                break
            }
        } else if d == 257 {
            reloadShifters()
            v = (v & ~0x041F) | (t & 0x041F)
            if visible { evaluateSprites() } else { spriteCount = 0; nextSprite0 = false }
            mapper.ppuFetchingSprites = true
            fetchSprite(0, phase: 0)
        } else if d > 257 && d <= 320 {
            oamAddr = 0
            let i = (d - 257) >> 3
            fetchSprite(i, phase: (d - 257) & 7)
            if d == 320 {
                mapper.ppuFetchingSprites = false
                buildSpriteLine()
            }
        } else if d == 337 {
            reloadShifters()
            ntLatch = Int(ppuBusRead(0x2000 | (v & 0x0FFF)))
        } else if d == 339 {
            ntLatch = Int(ppuBusRead(0x2000 | (v & 0x0FFF)))
        } else if d == 0 && visible {
            // Swap in the sprite pixels prepared during the previous line.
            swapSpriteLines()
        }
        if d == 0 && !visible {
            // Pre-render line: no sprites appear on line 0.
            spriteLine.update(repeating: 0, count: 256)
            lineSprite0 = false
        }
    }

    @inline(__always)
    func reloadShifters() {
        bgLo = (bgLo & 0xFF00) | patLoLatch
        bgHi = (bgHi & 0xFF00) | patHiLatch
        atLo = (atLo & 0xFF00) | ((atLatch & 1) != 0 ? 0xFF : 0)
        atHi = (atHi & 0xFF00) | ((atLatch & 2) != 0 ? 0xFF : 0)
    }

    @inline(__always)
    func incrementX() {
        if (v & 0x001F) == 31 {
            v &= ~0x001F
            v ^= 0x0400
        } else {
            v += 1
        }
    }

    @inline(__always)
    func incrementY() {
        if (v & 0x7000) != 0x7000 {
            v += 0x1000
        } else {
            v &= ~0x7000
            var y = (v & 0x03E0) >> 5
            if y == 29 {
                y = 0
                v ^= 0x0800
            } else if y == 31 {
                y = 0
            } else {
                y += 1
            }
            v = (v & ~0x03E0) | (y << 5)
        }
    }

    @inline(__always)
    func drawPixel(_ x: Int) {
        var bgPixel = 0, bgPalette = 0
        if showBG && (x >= 8 || showBGLeft) {
            let bit = 15 - fineX
            bgPixel = ((bgHi >> bit) & 1) << 1 | ((bgLo >> bit) & 1)
            bgPalette = ((atHi >> bit) & 1) << 1 | ((atLo >> bit) & 1)
        }
        var color: Int
        let sprite = Int(spriteLine[x])
        if sprite != 0 && showSprites && (x >= 8 || showSpritesLeft) {
            if bgPixel != 0 {
                if (sprite & 0x40) != 0 && x != 255 { sprite0Hit = true }
                color = (sprite & 0x20) != 0 ? (bgPalette << 2 | bgPixel) : (0x10 | (sprite & 0x0F))
            } else {
                color = 0x10 | (sprite & 0x0F)
            }
        } else {
            color = bgPixel != 0 ? (bgPalette << 2 | bgPixel) : 0
        }
        frameBuffer[scanline &* 256 &+ x] = UInt16((Int(paletteRAM[color]) & greyscaleMask) | emphasis)
    }

    // MARK: - Sprites

    func evaluateSprites() {
        let height = tallSprites ? 16 : 8
        let line = scanline
        var count = 0
        var n = 0
        nextSprite0 = false
        secondaryOAM.fill(0xFF)
        extraSprites.removeAll(keepingCapacity: true)
        while n < 64 {
            let y = Int(oam[n * 4])
            let row = line - y
            if row >= 0 && row < height {
                if count < 8 {
                    if n == 0 { nextSprite0 = true }
                    for k in 0..<4 { secondaryOAM[count * 4 + k] = oam[n * 4 + k] }
                    count += 1
                } else {
                    if unlimitedSprites {
                        extraSprites.append((y, Int(oam[n * 4 + 1]), Int(oam[n * 4 + 2]), Int(oam[n * 4 + 3])))
                    } else {
                        break
                    }
                }
            }
            n += 1
        }
        spriteCount = count
        // Hardware overflow check, including the diagonal OAM read bug.
        if count == 8 {
            var m = 0
            var i = 0
            // Find the first sprite index after the eighth match.
            var found = 0
            while i < 64 {
                let row = line - Int(oam[i * 4])
                if row >= 0 && row < height { found += 1; if found == 8 { i += 1; break } }
                i += 1
            }
            while i < 64 {
                let row = line - Int(oam[(i * 4 + m) & 0xFF])
                if row >= 0 && row < height {
                    spriteOverflow = true
                    break
                }
                i += 1
                m = (m + 1) & 3
            }
        }
    }

    func spritePatternAddress(tile: Int, row: Int, attr: Int) -> Int {
        let height = tallSprites ? 16 : 8
        var r = row
        if (attr & 0x80) != 0 { r = height - 1 - r }
        if tallSprites {
            let base = (tile & 1) != 0 ? 0x1000 : 0
            var t = tile & 0xFE
            if r >= 8 { t += 1; r -= 8 }
            return base | t << 4 | r
        }
        return spritePatternBase | tile << 4 | r
    }

    @inline(__always)
    func fetchSprite(_ i: Int, phase: Int) {
        switch phase {
        case 0, 2:
            _ = ppuBusRead(0x2000 | (v & 0x0FFF))   // garbage nametable fetches
        case 4, 6:
            let addr: Int
            if i < spriteCount {
                let y = Int(secondaryOAM[i * 4])
                let tile = Int(secondaryOAM[i * 4 + 1])
                let attr = Int(secondaryOAM[i * 4 + 2])
                addr = spritePatternAddress(tile: tile, row: scanline == preRenderLine ? 0 : scanline - y, attr: attr)
            } else {
                // Empty slots fetch tile $FF.
                addr = tallSprites ? 0x1FE0 : (spritePatternBase | 0xFF0)
            }
            let value = Int(ppuBusRead(addr + (phase == 6 ? 8 : 0)))
            if phase == 4 { spritePatLo[i] = value } else { spritePatHi[i] = value }
        default:
            break
        }
    }

    func buildSpriteLine() {
        nextSpriteLine.update(repeating: 0, count: 256)
        for i in 0..<spriteCount {
            let attr = Int(secondaryOAM[i * 4 + 2])
            let x0 = Int(secondaryOAM[i * 4 + 3])
            plotSprite(lo: spritePatLo[i], hi: spritePatHi[i], attr: attr, x0: x0, isSprite0: i == 0 && nextSprite0)
        }
        if unlimitedSprites {
            for s in extraSprites {
                let addr = spritePatternAddress(tile: s.tile, row: scanline - s.y, attr: s.attr)
                plotSprite(lo: Int(mapper.readPPU(addr)), hi: Int(mapper.readPPU(addr + 8)), attr: s.attr, x0: s.x, isSprite0: false)
            }
        }
    }

    @inline(__always)
    func plotSprite(lo: Int, hi: Int, attr: Int, x0: Int, isSprite0: Bool) {
        let flipH = (attr & 0x40) != 0
        let meta = UInt8((attr & 3) << 2 | ((attr & 0x20) != 0 ? 0x20 : 0) | (isSprite0 ? 0x40 : 0))
        for px in 0..<8 {
            let x = x0 + px
            if x > 255 { break }
            if nextSpriteLine[x] != 0 { continue }   // lower OAM index wins
            let bit = flipH ? px : 7 - px
            let c = ((hi >> bit) & 1) << 1 | ((lo >> bit) & 1)
            if c != 0 { nextSpriteLine[x] = meta | UInt8(c) }
        }
    }

    @inline(__always)
    func swapSpriteLines() {
        spriteLine.update(from: nextSpriteLine, count: 256)
        lineSprite0 = nextSprite0
    }

    // MARK: - PPU bus

    @inline(__always)
    func ppuBusRead(_ address: Int) -> UInt8 {
        if mapper.needsPPUAddressNotifications { mapper.ppuAddressChanged(address, ppuCycle: ppuCycle) }
        return mapper.readPPU(address)
    }

    @inline(__always)
    func paletteIndex(_ address: Int) -> Int {
        var i = address & 0x1F
        if (i & 0x13) == 0x10 { i &= ~0x10 }
        return i
    }

    // MARK: - CPU-facing registers

    func readRegister(_ reg: Int) -> UInt8 {
        switch reg {
        case 2:
            let value = (vblank ? 0x80 : 0) | (sprite0Hit ? 0x40 : 0) | (spriteOverflow ? 0x20 : 0)
            let result = UInt8(value) | (openBus & 0x1F)
            vblank = false
            w = false
            updateNMI()
            if scanline == vblankLine && dot == 0 {
                // Reading one dot before vblank suppresses the flag and the NMI.
                preventVBlank = true
            }
            refreshOpenBus(result, mask: 0xE0)
            return result
        case 4:
            var value: UInt8
            if scanline < 240 && renderingEnabled && dot >= 1 && dot <= 64 {
                value = 0xFF   // secondary OAM clear reads $FF
            } else {
                value = oam[Int(oamAddr)]
                if (oamAddr & 3) == 2 { value &= 0xE3 }
            }
            refreshOpenBus(value, mask: 0xFF)
            return value
        case 7:
            var result: UInt8
            let addr = v & 0x3FFF
            if addr >= 0x3F00 {
                result = (palette[paletteIndex(addr)] & UInt8(greyscaleMask)) | (openBus & 0xC0)
                readBuffer = mapper.readPPU(addr - 0x1000)   // nametable "underneath" the palette
                refreshOpenBus(result, mask: 0x3F)
            } else {
                result = readBuffer
                readBuffer = mapper.readPPU(addr >= 0x3000 ? addr - 0x1000 : addr)
                refreshOpenBus(result, mask: 0xFF)
            }
            incrementVRAMAddress()
            return result
        default:
            return openBus
        }
    }

    func writeRegister(_ reg: Int, _ value: UInt8) {
        refreshOpenBus(value, mask: 0xFF)
        switch reg {
        case 0:
            writeCtrl(value)
            t = (t & ~0x0C00) | (Int(value & 0x03) << 10)
        case 1:
            writeMask(value)
        case 3:
            oamAddr = value
        case 4:
            if (scanline < 240 || scanline == preRenderLine) && renderingEnabled {
                oamAddr &+= 4   // writes during rendering only bump the high bits
            } else {
                oam[Int(oamAddr)] = value
                oamAddr &+= 1
            }
        case 5:
            if !w {
                t = (t & ~0x001F) | Int(value >> 3)
                fineX = Int(value & 7)
            } else {
                t = (t & ~0x73E0) | (Int(value & 0x07) << 12) | (Int(value & 0xF8) << 2)
            }
            w.toggle()
        case 6:
            if !w {
                t = (t & 0x00FF) | (Int(value & 0x3F) << 8)
            } else {
                t = (t & 0x7F00) | Int(value)
                v = t
                if mapper.needsPPUAddressNotifications { mapper.ppuAddressChanged(v & 0x3FFF, ppuCycle: ppuCycle) }
            }
            w.toggle()
        case 7:
            let addr = v & 0x3FFF
            if addr >= 0x3F00 {
                palette[paletteIndex(addr)] = value & 0x3F
            } else {
                mapper.writePPU(addr >= 0x3000 ? addr - 0x1000 : addr, value)
            }
            incrementVRAMAddress()
        default:
            break
        }
    }

    func writeCtrl(_ value: UInt8) {
        ctrl = value
        vramIncrement = (value & 0x04) != 0 ? 32 : 1
        spritePatternBase = (value & 0x08) != 0 ? 0x1000 : 0
        bgPatternBase = (value & 0x10) != 0 ? 0x1000 : 0
        tallSprites = (value & 0x20) != 0
        mapper.ppuLargeSprites = tallSprites
        nmiEnabled = (value & 0x80) != 0
        updateNMI()
    }

    func writeMask(_ value: UInt8) {
        mask = value
        greyscaleMask = (value & 0x01) != 0 ? 0x30 : 0x3F
        showBGLeft = (value & 0x02) != 0
        showSpritesLeft = (value & 0x04) != 0
        showBG = (value & 0x08) != 0
        showSprites = (value & 0x10) != 0
        renderingEnabled = showBG || showSprites
        mapper.ppuRenderingEnabled = renderingEnabled
        var e = Int(value >> 5) & 7
        if region != .ntsc {
            // 2C07 swaps the red and green emphasis bits.
            e = (e & 4) | ((e & 1) << 1) | ((e & 2) >> 1)
        }
        emphasis = e << 6
    }

    func incrementVRAMAddress() {
        if (scanline < 240 || scanline == preRenderLine) && renderingEnabled {
            // Accessing $2007 while rendering bumps both coarse X and fine Y.
            incrementX()
            incrementY()
        } else {
            v = (v + vramIncrement) & 0x7FFF
        }
        if mapper.needsPPUAddressNotifications { mapper.ppuAddressChanged(v & 0x3FFF, ppuCycle: ppuCycle) }
    }

    @inline(__always)
    func updateNMI() {
        nmiOutput = vblank && nmiEnabled
    }

    func writeOAMDMA(_ value: UInt8) {
        writeRegister(4, value)
    }

    // MARK: - Open bus decay

    func refreshOpenBus(_ value: UInt8, mask: UInt8) {
        openBus = (openBus & ~mask) | (value & mask)
        for bit in 0..<8 where (mask >> bit) & 1 != 0 { openBusDecay[bit] = 36 }   // ~600ms
    }

    func decayOpenBus() {
        for bit in 0..<8 where openBusDecay[bit] > 0 {
            openBusDecay[bit] -= 1
            if openBusDecay[bit] == 0 { openBus &= ~UInt8(1 << bit) }
        }
    }

    // MARK: - Save states

    func saveState(_ w: inout StateWriter) {
        w.write([scanline, dot, v, t, fineX, ntLatch, atLatch, patLoLatch, patHiLatch, bgLo, bgHi, atLo, atHi, spriteCount])
        w.write(frameCount); w.write(masterClock); w.write(ppuCycle)
        w.write(oddFrame); w.write(self.w); w.write(vblank); w.write(sprite0Hit); w.write(spriteOverflow)
        w.write(preventVBlank); w.write(nextSprite0); w.write(lineSprite0)
        w.write(ctrl); w.write(mask); w.write(readBuffer); w.write(oamAddr); w.write(openBus)
        w.write(openBusDecay)
        w.write(palette); w.write(oam); w.write(secondaryOAM)
        w.write(spritePatLo); w.write(spritePatHi)
        w.write(bytes: spriteLine, count: 256)
        w.write(bytes: nextSpriteLine, count: 256)
    }

    func loadState(_ r: inout StateReader) throws {
        let s = try r.readIntArray()
        guard s.count == 14 else { throw StateError.corrupt("PPU") }
        scanline = s[0]; dot = s[1]; v = s[2]; t = s[3]; fineX = s[4]; ntLatch = s[5]; atLatch = s[6]
        patLoLatch = s[7]; patHiLatch = s[8]; bgLo = s[9]; bgHi = s[10]; atLo = s[11]; atHi = s[12]; spriteCount = s[13]
        guard scanline >= 0 && scanline <= preRenderLine && dot >= 0 && dot <= 340 && spriteCount <= 8 else {
            throw StateError.corrupt("PPU timing")
        }
        frameCount = try r.readU64(); masterClock = try r.readU64(); ppuCycle = try r.readU64()
        oddFrame = try r.readBool(); w = try r.readBool(); vblank = try r.readBool()
        sprite0Hit = try r.readBool(); spriteOverflow = try r.readBool()
        preventVBlank = try r.readBool(); nextSprite0 = try r.readBool(); lineSprite0 = try r.readBool()
        let c = try r.readU8(), m = try r.readU8()
        writeCtrl(c); writeMask(m)
        readBuffer = try r.readU8(); oamAddr = try r.readU8(); openBus = try r.readU8()
        openBusDecay = try r.readIntArray()
        guard openBusDecay.count == 8 else { throw StateError.corrupt("PPU open bus") }
        try r.read(into: palette); try r.read(into: oam); try r.read(into: secondaryOAM)
        spritePatLo = try r.readIntArray(); spritePatHi = try r.readIntArray()
        guard spritePatLo.count == 8, spritePatHi.count == 8 else { throw StateError.corrupt("PPU sprites") }
        try r.read(into: spriteLine, count: 256)
        try r.read(into: nextSpriteLine, count: 256)
    }
}

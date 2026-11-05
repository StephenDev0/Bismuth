/// Nametable arrangement.
public enum Mirroring: UInt8, Sendable {
    case horizontal = 0   // $2000=$2400, $2800=$2C00 (vertical scrolling games)
    case vertical = 1     // $2000=$2800, $2400=$2C00 (horizontal scrolling games)
    case singleScreenA = 2
    case singleScreenB = 3
    case fourScreen = 4
}

public enum CartridgeError: Error, Equatable, CustomStringConvertible {
    case notAnNESFile
    case truncated(expected: Int, actual: Int)
    case unsupportedMapper(Int)
    case emptyPRG

    public var description: String {
        switch self {
        case .notAnNESFile: return "Not an iNES / NES 2.0 ROM image"
        case .truncated(let e, let a): return "ROM image is truncated (expected \(e) bytes, got \(a))"
        case .unsupportedMapper(let m): return "Mapper \(m) is not supported"
        case .emptyPRG: return "ROM image has no PRG data"
        }
    }
}

/// A parsed ROM image.
public struct Cartridge: Sendable {
    public var mapperID: Int
    public var submapper: Int
    public var prg: [UInt8]
    public var chr: [UInt8]
    public var trainer: [UInt8]?
    public var mirroring: Mirroring
    public var hasBattery: Bool
    public var isNES20: Bool
    /// Bytes of PRG RAM (volatile + battery backed).
    public var prgRAMSize: Int
    /// Battery-backed part of `prgRAMSize`.
    public var prgNVRAMSize: Int
    /// Bytes of CHR RAM when `chr` is empty (or extra CHR RAM for NES 2.0 boards).
    public var chrRAMSize: Int
    public var region: Region?
    /// CRC32 of PRG+CHR (the No-Intro / libretro database key, header excluded).
    public var crc32: UInt32
    /// CRC32 of PRG only.
    public var prgCRC32: UInt32

    public var hasCHRRAM: Bool { chr.isEmpty }

    public init(data: [UInt8]) throws {
        guard data.count >= 16, data[0] == 0x4E, data[1] == 0x45, data[2] == 0x53, data[3] == 0x1A else {
            throw CartridgeError.notAnNESFile
        }
        let flags6 = data[6], flags7 = data[7]
        isNES20 = (flags7 & 0x0C) == 0x08
        // "DiskDude!" and similar junk in bytes 7-15 of old dumps: ignore the high mapper nibble.
        let junkTail = !isNES20 && data[12..<16].contains(where: { $0 != 0 })

        var mapper = Int(flags6 >> 4) | (junkTail ? 0 : Int(flags7 & 0xF0))
        var prgSize = Int(data[4]) * 16 * 1024
        var chrSize = Int(data[5]) * 8 * 1024
        submapper = 0

        if isNES20 {
            mapper |= Int(data[8] & 0x0F) << 8
            submapper = Int(data[8] >> 4)
            prgSize = Cartridge.nes20Size(lsb: data[4], msbNibble: data[9] & 0x0F, unit: 16 * 1024)
            chrSize = Cartridge.nes20Size(lsb: data[5], msbNibble: data[9] >> 4, unit: 8 * 1024)
            let ramShift = Int(data[10] & 0x0F), nvShift = Int(data[10] >> 4)
            let volatileRAM = ramShift == 0 ? 0 : 64 << ramShift
            prgNVRAMSize = nvShift == 0 ? 0 : 64 << nvShift
            prgRAMSize = volatileRAM + prgNVRAMSize
            let chrShift = Int(data[11] & 0x0F), chrNVShift = Int(data[11] >> 4)
            chrRAMSize = (chrShift == 0 ? 0 : 64 << chrShift) + (chrNVShift == 0 ? 0 : 64 << chrNVShift)
            switch data[12] & 0x03 {
            case 0: region = .ntsc
            case 1: region = .pal
            case 3: region = .dendy
            default: region = nil
            }
        } else {
            prgRAMSize = max(Int(data[8]), 1) * 8 * 1024
            prgNVRAMSize = (flags6 & 0x02) != 0 ? prgRAMSize : 0
            chrRAMSize = chrSize == 0 ? 8 * 1024 : 0
            region = (!junkTail && (data[9] & 0x01) != 0) ? .pal : nil
        }
        if chrSize == 0 && chrRAMSize == 0 { chrRAMSize = 8 * 1024 }

        mapperID = mapper
        hasBattery = (flags6 & 0x02) != 0
        if (flags6 & 0x08) != 0 {
            mirroring = .fourScreen
        } else {
            mirroring = (flags6 & 0x01) != 0 ? .vertical : .horizontal
        }

        var offset = 16
        if (flags6 & 0x04) != 0 {
            guard data.count >= offset + 512 else { throw CartridgeError.truncated(expected: offset + 512, actual: data.count) }
            trainer = Array(data[offset..<offset + 512])
            offset += 512
        } else {
            trainer = nil
        }
        guard prgSize > 0 else { throw CartridgeError.emptyPRG }
        guard data.count >= offset + prgSize else {
            throw CartridgeError.truncated(expected: offset + prgSize + chrSize, actual: data.count)
        }
        prg = Array(data[offset..<offset + prgSize])
        offset += prgSize
        // Tolerate a short CHR section (some bad dumps); pad with zeros.
        let available = max(0, min(chrSize, data.count - offset))
        var chrData = Array(data[offset..<offset + available])
        if chrData.count < chrSize { chrData += [UInt8](repeating: 0, count: chrSize - chrData.count) }
        chr = chrData

        prgCRC32 = CRC32.checksum(prg)
        crc32 = CRC32.checksum(chr, seed: prgCRC32)
        Cartridge.applyKnownFixes(&self)
    }

    /// Builds a cartridge directly from banks (used by tests and tools).
    public init(prg: [UInt8], chr: [UInt8], mapper: Int, mirroring: Mirroring = .horizontal,
                battery: Bool = false, prgRAMSize: Int = 8 * 1024, region: Region? = nil) {
        self.mapperID = mapper
        self.submapper = 0
        self.prg = prg
        self.chr = chr
        self.trainer = nil
        self.mirroring = mirroring
        self.hasBattery = battery
        self.isNES20 = false
        self.prgRAMSize = prgRAMSize
        self.prgNVRAMSize = battery ? prgRAMSize : 0
        self.chrRAMSize = chr.isEmpty ? 8 * 1024 : 0
        self.region = region
        self.prgCRC32 = CRC32.checksum(prg)
        self.crc32 = CRC32.checksum(chr, seed: prgCRC32)
    }

    static func nes20Size(lsb: UInt8, msbNibble: UInt8, unit: Int) -> Int {
        if msbNibble == 0x0F {
            // Exponent-multiplier notation: 2^E * (M*2+1)
            let exponent = Int(lsb >> 2), multiplier = Int(lsb & 0x03) * 2 + 1
            return exponent >= 62 ? 0 : (1 << exponent) * multiplier
        }
        return (Int(msbNibble) << 8 | Int(lsb)) * unit
    }

    /// iNES 1.0 headers cannot describe large PRG-RAM; give the boards that need it their full size.
    static func applyKnownFixes(_ cart: inout Cartridge) {
        // MMC1 SNROM/SOROM/SXROM: iNES 1.0 headers often under-report RAM; give the board its full 32KB.
        if cart.mapperID == 1 && !cart.isNES20 && cart.prgRAMSize < 32 * 1024 && cart.prg.count == 512 * 1024 {
            cart.prgRAMSize = 32 * 1024
            if cart.hasBattery { cart.prgNVRAMSize = cart.prgRAMSize }
        }
        // MMC5 boards can address up to 64KB of PRG RAM.
        if cart.mapperID == 5 && !cart.isNES20 {
            cart.prgRAMSize = 64 * 1024
            if cart.hasBattery { cart.prgNVRAMSize = cart.prgRAMSize }
        }
    }
}

/// IEEE CRC-32 (zlib polynomial).
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum<C: Collection>(_ bytes: C, seed: UInt32 = 0) -> UInt32 where C.Element == UInt8 {
        var crc = ~seed
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}

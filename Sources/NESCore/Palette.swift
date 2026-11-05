#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Colour palettes for converting PPU pixel values (6-bit colour + 3 emphasis bits) to RGB.
///
/// Palettes are generated, not tabulated: the 2C02's composite signal is synthesised from voltage
/// levels measured on a 2C02G (including the attenuated emphasis levels) and decoded like an NTSC
/// TV (12 samples per subcarrier cycle, YUV demodulation referenced to the colour burst). The
/// default uses typical TV settings (-12 degree tint, 1.2x colour), which reproduces the standard
/// NES palette; `tvAccurate` is the strict decode with no adjustments.
public struct NESPalette: Sendable, Equatable {
    /// 512 entries of 0xAARRGGBB, indexed by the PPU pixel value.
    public let argb: [UInt32]

    public init(argb: [UInt32]) {
        precondition(argb.count == 512)
        self.argb = argb
    }

    public enum Kind: String, Sendable, CaseIterable {
        /// 2C02G composite output with typical TV picture settings (default). Matches the
        /// long-standing reference NES palette to within ~1.6 RGB units, including emphasis.
        case composite
        /// Same signal, richer colour and a little more contrast.
        case vivid
        /// Strict decode: chroma normalised to a standard 20 IRE colour burst, no tint (darker, muted).
        case tvAccurate
        /// 2C07 (PAL) composite output.
        case compositePAL
        /// 2C03/2C05 RGB PPU (PlayChoice-10, Famicom Titler, Sharp C1 TV).
        case rgb
        /// Luma only.
        case greyscale
    }

    public static func make(_ kind: Kind) -> NESPalette {
        switch kind {
        case .composite: return composite
        case .vivid: return vivid
        case .tvAccurate: return tvAccurate
        case .compositePAL: return compositePAL
        case .rgb: return rgb
        case .greyscale: return makeComposite(saturation: 0)
        }
    }

    /// Decoder settings that reproduce the standard NES palette from the measured signal:
    /// a -12° tint and 1.2x colour relative to strict burst normalisation.
    public static let standardHue = -12.0
    public static let standardSaturation = 1.2

    public static let composite = makeComposite(hueDegrees: standardHue, saturation: standardSaturation)
    public static let vivid = makeComposite(hueDegrees: standardHue, saturation: 1.45, contrast: 1.06, brightness: 0.01)
    public static let tvAccurate = makeComposite()
    public static let compositePAL = makeComposite(hueDegrees: standardHue, saturation: standardSaturation, pal: true)
    public static let rgb = makeRGB()

    // MARK: - Composite synthesis

    /// Measured 2C02G output levels in volts (lidnariq, NESdev wiki "NTSC video").
    static let levels: [Double] = [
        0.228, 0.312, 0.552, 0.880,   // signal low, luma 0-3
        0.616, 0.840, 1.100, 1.100,   // signal high
        0.192, 0.256, 0.448, 0.712,   // signal low, emphasis attenuated
        0.500, 0.676, 0.896, 0.896,   // signal high, emphasis attenuated
    ]
    static let black = 0.312
    static let white = 1.100
    /// Colour burst swing (hue 8), measured on a 2C02G.
    static let burstLow = 0.148
    static let burstHigh = 0.524

    /// Automatic colour control gain: a TV (or capture device) scales chroma so the burst's
    /// fundamental has the standard 20 IRE amplitude. The 2C02's square-wave burst is hotter
    /// than that, so decoded colours are correspondingly toned down.
    static let accGain: Double = {
        var re = 0.0, im = 0.0
        for p in 0..<12 {
            let s = (inColorPhase(8, p) ? burstHigh : burstLow) / (white - black)
            let angle = 2 * Double.pi * Double(p) / 12
            re += s * cos(angle)
            im -= s * sin(angle)
        }
        let amplitude = (re * re + im * im).squareRoot() * 2 / 12
        return 0.2 / amplitude
    }()

    @inline(__always)
    static func inColorPhase(_ color: Int, _ phase: Int) -> Bool { (color + phase) % 12 < 6 }

    /// The composite voltage the PPU emits for `pixel` at subcarrier sample `phase` (0-11).
    static func signal(pixel: Int, phase: Int) -> Double {
        let color = pixel & 0x0F
        var level = (pixel >> 4) & 3
        let emphasis = pixel >> 6
        if color > 13 { level = 1 }   // $xE / $xF are black
        let attenuate = color < 0x0E && (
            ((emphasis & 1) != 0 && inColorPhase(0, phase)) ||
            ((emphasis & 2) != 0 && inColorPhase(4, phase)) ||
            ((emphasis & 4) != 0 && inColorPhase(8, phase)))
        var low = levels[level + (attenuate ? 8 : 0)]
        var high = levels[4 + level + (attenuate ? 8 : 0)]
        if color == 0 { low = high }       // $x0: luma only, high level
        if color > 12 { high = low }       // $xD-$xF: luma only, low level
        return inColorPhase(color, phase) ? high : low
    }

    /// Decodes the synthesised signal into an sRGB palette.
    /// - Parameters:
    ///   - hueDegrees: decoder tint adjustment.
    ///   - saturation: decoder colour gain (1 = nominal).
    ///   - pal: decode as PAL (phase alternation averages away hue error, slightly lower saturation).
    public static func makeComposite(hueDegrees: Double = 0, saturation: Double = 1, contrast: Double = 1,
                                     brightness: Double = 0, pal: Bool = false) -> NESPalette {
        var out = [UInt32](repeating: 0xFF00_0000, count: 512)
        // The colour burst is hue 8; its fundamental sits at 165° in our sample frame. Rotating by
        // +15° puts the burst on the -U axis, which is where an NTSC decoder references it.
        let rotation = (15.0 + hueDegrees) * Double.pi / 180
        for pixel in 0..<512 {
            var y = 0.0, re = 0.0, im = 0.0
            for p in 0..<12 {
                let s = (signal(pixel: pixel, phase: p) - black) / (white - black)
                let angle = 2 * Double.pi * Double(p) / 12
                y += s
                re += s * cos(angle)
                im -= s * sin(angle)
            }
            y /= 12
            // Complex amplitude of the subcarrier fundamental.
            re *= 2.0 / 12.0
            im *= 2.0 / 12.0
            let u0 = re * cos(rotation) - im * sin(rotation)
            let v0 = re * sin(rotation) + im * cos(rotation)
            let sat = saturation * accGain * (pal ? 0.94 : 1.0)
            let u = u0 * sat, v = v0 * sat
            // YUV (NTSC-scaled chroma) to RGB.
            var r = y + 1.139883 * v
            var g = y - 0.394642 * u - 0.580622 * v
            var b = y + 2.032062 * u
            r = r * contrast + brightness
            g = g * contrast + brightness
            b = b * contrast + brightness
            out[pixel] = pack(r, g, b)
        }
        return NESPalette(argb: out)
    }

    @inline(__always)
    static func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func channel(_ v: Double) -> UInt32 {
            let c = (v * 255).rounded()
            return UInt32(max(0, min(255, c)))
        }
        return 0xFF00_0000 | channel(r) << 16 | channel(g) << 8 | channel(b)
    }

    // MARK: - RGB PPU

    /// 2C03 colour table: three 3-bit DAC levels per entry (R, G, B), from the RGB PPU's ROM.
    static let rgbTable: [Int] = [
        0o333, 0o014, 0o006, 0o326, 0o403, 0o503, 0o510, 0o420, 0o320, 0o120, 0o031, 0o040, 0o022, 0o000, 0o000, 0o000,
        0o555, 0o036, 0o027, 0o407, 0o507, 0o704, 0o700, 0o630, 0o430, 0o140, 0o040, 0o053, 0o044, 0o000, 0o000, 0o000,
        0o777, 0o357, 0o447, 0o637, 0o707, 0o737, 0o740, 0o750, 0o660, 0o360, 0o070, 0o276, 0o077, 0o000, 0o000, 0o000,
        0o777, 0o567, 0o657, 0o757, 0o747, 0o755, 0o764, 0o772, 0o773, 0o572, 0o473, 0o276, 0o467, 0o000, 0o000, 0o000,
    ]

    static func makeRGB() -> NESPalette {
        var out = [UInt32](repeating: 0xFF00_0000, count: 512)
        for pixel in 0..<512 {
            let entry = rgbTable[pixel & 0x3F]
            var r = (entry >> 6) & 7, g = (entry >> 3) & 7, b = entry & 7
            // RGB PPUs implement emphasis by forcing the channel to full intensity.
            let e = pixel >> 6
            if (e & 1) != 0 { r = 7 }
            if (e & 2) != 0 { g = 7 }
            if (e & 4) != 0 { b = 7 }
            out[pixel] = 0xFF00_0000 | UInt32(r * 255 / 7) << 16 | UInt32(g * 255 / 7) << 8 | UInt32(b * 255 / 7)
        }
        return NESPalette(argb: out)
    }

    // MARK: - Files

    /// Loads a standard .pal file (64 or 512 RGB triplets).
    public init?(palFile data: [UInt8]) {
        let entries: Int
        switch data.count {
        case 192: entries = 64
        case 1536: entries = 512
        default: return nil
        }
        var out = [UInt32](repeating: 0xFF00_0000, count: 512)
        for i in 0..<512 {
            let src = entries == 512 ? i : i & 0x3F
            out[i] = 0xFF00_0000 | UInt32(data[src * 3]) << 16 | UInt32(data[src * 3 + 1]) << 8 | UInt32(data[src * 3 + 2])
        }
        if entries == 64 {
            // Approximate emphasis for 64-colour files using the composite attenuation ratios.
            let reference = NESPalette.composite.argb
            for i in 64..<512 {
                let base = reference[i & 0x3F], tinted = reference[i]
                func ratio(_ shift: UInt32) -> Double {
                    let b = Double((base >> shift) & 0xFF), t = Double((tinted >> shift) & 0xFF)
                    return b > 0 ? min(t / b, 1.5) : 1
                }
                let src = out[i & 0x3F]
                let r = Double((src >> 16) & 0xFF) * ratio(16) / 255
                let g = Double((src >> 8) & 0xFF) * ratio(8) / 255
                let b = Double(src & 0xFF) * ratio(0) / 255
                out[i] = NESPalette.pack(r, g, b)
            }
        }
        argb = out
    }

    /// The palette as a 1536-byte .pal file.
    public var palFile: [UInt8] {
        argb.flatMap { [UInt8(($0 >> 16) & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
    }
}

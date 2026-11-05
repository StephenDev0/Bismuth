import Testing
@testable import NESCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Picture and sound quality")
struct QualityTests {
    func rgb(_ c: UInt32) -> (Int, Int, Int) { (Int((c >> 16) & 0xFF), Int((c >> 8) & 0xFF), Int(c & 0xFF)) }

    /// The default palette should match the long-standing reference NES palette.
    @Test func defaultPaletteMatchesReference() {
        let reference: [Int: (Int, Int, Int)] = [
            0x00: (102, 102, 102), 0x10: (173, 173, 173), 0x16: (181, 49, 32), 0x12: (66, 64, 255),
            0x1A: (12, 147, 0), 0x21: (100, 176, 255), 0x22: (146, 144, 255), 0x26: (254, 129, 112),
            0x2A: (92, 228, 48), 0x30: (255, 254, 255), 0x27: (234, 158, 34), 0x2C: (72, 205, 222),
        ]
        let p = NESPalette.composite.argb
        for (index, want) in reference {
            let got = rgb(p[index])
            #expect(abs(got.0 - want.0) <= 6 && abs(got.1 - want.1) <= 6 && abs(got.2 - want.2) <= 6,
                    "$\(String(index, radix: 16)): \(got) vs \(want)")
        }
        // Vivid is more saturated than the default, which is more saturated than the strict decode.
        func chroma(_ c: UInt32) -> Int { let (r, g, b) = rgb(c); return max(r, g, b) - min(r, g, b) }
        #expect(chroma(NESPalette.vivid.argb[0x16]) > chroma(p[0x16]))
        #expect(chroma(p[0x16]) > chroma(NESPalette.tvAccurate.argb[0x16]))
    }

    @Test func scale2xSmoothsDiagonalsOnly() {
        // 3x3: a diagonal of X on O. Scale2x rounds the staircase but keeps colours unchanged.
        let X: UInt32 = 0xFFFF_FFFF, O: UInt32 = 0xFF00_0000
        let src: [UInt32] = [X, O, O,
                             O, X, O,
                             O, O, X]
        var dst = [UInt32](repeating: 0, count: 36)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                Upscaler.scale2x.apply(source: s.baseAddress!, width: 3, height: 3, destination: d.baseAddress!)
            }
        }
        #expect(Set(dst) == [X, O])                 // no new colours
        #expect(dst[0] == X && dst[6 * 5 + 5] == X)  // corners preserved
        #expect(dst[1 * 6 + 2] == X)                 // the staircase is filled in: the diagonal becomes a smooth line
        #expect(dst[0 * 6 + 2] == O)                 // ...without growing past it

        // Flat areas are untouched by every scaler.
        let flat = [UInt32](repeating: X, count: 16)
        for scaler in Upscaler.allCases where scaler != .off {
            var out = [UInt32](repeating: 0, count: 16 * scaler.factor * scaler.factor)
            var scratch = [UInt32](repeating: 0, count: 64)
            flat.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { d in
                    scratch.withUnsafeMutableBufferPointer { t in
                        scaler.apply(source: s.baseAddress!, width: 4, height: 4, destination: d.baseAddress!, scratch: t.baseAddress!)
                    }
                }
            }
            #expect(out.allSatisfy { $0 == X }, "\(scaler)")
        }
    }

    /// Goertzel power at `frequency` for mono samples.
    func power(_ samples: [Float], frequency: Double, rate: Double) -> Double {
        let k = 2 * cos(2 * Double.pi * frequency / rate)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + k * s1 - s2
            s2 = s1; s1 = s0
        }
        return s1 * s1 + s2 * s2 - k * s1 * s2
    }

    @Test func bandLimitedAudioDoesNotAlias() throws {
        let nes = try TestROM.console([0x4C, 0x00, 0xC0])
        nes.audioFilter = .clean
        // Pulse 1: 50% duty, constant volume 15, period 8 -> 1789772.7 / 144 = 12429.0 Hz
        // (periods below 8 are muted by the hardware).
        nes.apu.write(0x4015, 0x01)
        nes.apu.write(0x4000, 0xBF)
        nes.apu.write(0x4001, 0x00)
        nes.apu.write(0x4002, 0x08)
        nes.apu.write(0x4003, 0x00)
        for _ in 0..<20 { nes.runFrame() }
        _ = nes.drainAudio()
        for _ in 0..<30 { nes.runFrame() }
        let stereo = nes.drainAudio()
        let mono = stride(from: 0, to: stereo.count, by: 2).map { Float(stereo[$0]) }
        let f0 = 1_789_772.7 / 144
        let fundamental = power(mono, frequency: f0, rate: 48_000)
        // The 3rd harmonic (37.3 kHz) would alias to 10.7 kHz.
        let alias = power(mono, frequency: 48_000 - 3 * f0, rate: 48_000)
        let db = 10 * log10(alias / fundamental)
        print("Bismuth alias level: \(Int(db.rounded())) dB below the fundamental")
        #expect(fundamental > 0)
        #expect(db < -45, "alias at \(db) dB")
    }
}

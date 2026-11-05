#if canImport(Metal)
import Testing
import Metal
import NESCore
@testable import NESMetal

@Suite("Metal renderer")
@MainActor
struct RendererTests {
    /// 256x240 frame: vertical colour bars across all 64 colours, emphasis on the bottom half.
    func makeFrame() -> [UInt16] {
        var frame = [UInt16](repeating: 0, count: 256 * 240)
        for y in 0..<240 {
            for x in 0..<256 {
                frame[y * 256 + x] = UInt16(x / 4) | (y >= 120 ? 0x40 : 0)
            }
        }
        return frame
    }

    @Test func gpuPaletteLookupMatchesCPU() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try #require(NESMetalRenderer(palette: .composite))
        renderer.filter = .nearest
        renderer.aspectMode = .square
        renderer.cropTop = 0; renderer.cropBottom = 0
        let frame = makeFrame()
        frame.withUnsafeBufferPointer { renderer.submit(frame: $0.baseAddress!) }
        let pixels = try #require(renderer.snapshot(width: 256, height: 240))
        var mismatches = 0
        for y in stride(from: 2, to: 240, by: 8) {
            for x in stride(from: 2, to: 256, by: 4) {
                let expected = NESPalette.composite.argb[Int(frame[y * 256 + x])]
                let i = (y * 256 + x) * 4   // BGRA
                let r = UInt32(pixels[i + 2]), g = UInt32(pixels[i + 1]), b = UInt32(pixels[i])
                let er = (expected >> 16) & 0xFF, eg = (expected >> 8) & 0xFF, eb = expected & 0xFF
                if abs(Int(r) - Int(er)) > 1 || abs(Int(g) - Int(eg)) > 1 || abs(Int(b) - Int(eb)) > 1 { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func everyFilterRendersAndLetterboxes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try #require(NESMetalRenderer())
        let frame = [UInt16](repeating: 0x30, count: 256 * 240)   // white
        frame.withUnsafeBufferPointer { renderer.submit(frame: $0.baseAddress!) }
        for filter in NESMetalRenderer.Filter.allCases {
            renderer.filter = filter
            renderer.aspectMode = .ntscPixelAspect
            let pixels = try #require(renderer.snapshot(width: 640, height: 360))
            // Centre is bright, the pillarbox edge is black.
            let centre = (180 * 640 + 320) * 4, edge = (180 * 640 + 2) * 4
            #expect(pixels[centre + 1] > 150, "\(filter)")
            #expect(pixels[edge + 1] == 0, "\(filter)")
        }
    }

    @Test func pointerMappingRoundTrips() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try #require(NESMetalRenderer())
        renderer.aspectMode = .square
        renderer.cropTop = 8; renderer.cropBottom = 8
        let size = CGSize(width: 512, height: 448)
        let p = renderer.nesCoordinate(for: CGPoint(x: 256, y: 224), drawableSize: size)
        #expect(p.inside && p.x == 128 && p.y == 120)
        let corner = renderer.nesCoordinate(for: CGPoint(x: 1, y: 1), drawableSize: size)
        #expect(corner.x == 0 && corner.y == 8)
    }
}
#endif

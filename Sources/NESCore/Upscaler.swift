/// Pixel-art upscalers for 32-bit frames (0xAARRGGBB).
///
/// - `scale2x`/`scale3x`/`scale4x`: the AdvanceMAME ScaleNx (EPX) family. Edges along diagonals are
///   smoothed, flat areas and straight lines stay pixel-exact, and no new colours are introduced.
/// - `sharp2x`/`sharp3x`/`sharp4x`: integer nearest-neighbour prescaling, so a frontend's bilinear
///   filter stays crisp ("sharp bilinear").
public enum Upscaler: Equatable, Sendable, CaseIterable {
    case off, scale2x, scale3x, scale4x, sharp2x, sharp3x, sharp4x

    public var factor: Int {
        switch self {
        case .off: return 1
        case .scale2x, .sharp2x: return 2
        case .scale3x, .sharp3x: return 3
        case .scale4x, .sharp4x: return 4
        }
    }

    /// Parses a libretro option value ("Scale2x", "Sharp 3x", ...).
    public init(optionValue: String) {
        switch String(optionValue.lowercased().filter { $0 != " " }) {
        case "scale2x": self = .scale2x
        case "scale3x": self = .scale3x
        case "scale4x": self = .scale4x
        case "sharp2x": self = .sharp2x
        case "sharp3x": self = .sharp3x
        case "sharp4x": self = .sharp4x
        default: self = .off
        }
    }

    /// Scales `source` (`width`x`height`, tightly packed) into `destination`
    /// (`width*factor` x `height*factor`). `scratch` must hold `width*2 * height*2` pixels (Scale4x only).
    public func apply(source: UnsafePointer<UInt32>, width: Int, height: Int,
                      destination: UnsafeMutablePointer<UInt32>, scratch: UnsafeMutablePointer<UInt32>? = nil) {
        switch self {
        case .off:
            destination.update(from: source, count: width * height)
        case .scale2x:
            Upscaler.scale2x(source, width, height, destination)
        case .scale3x:
            Upscaler.scale3x(source, width, height, destination)
        case .scale4x:
            if let scratch {
                Upscaler.scale2x(source, width, height, scratch)
                Upscaler.scale2x(UnsafePointer(scratch), width * 2, height * 2, destination)
            } else {
                Upscaler.nearest(source, width, height, 4, destination)
            }
        case .sharp2x, .sharp3x, .sharp4x:
            Upscaler.nearest(source, width, height, factor, destination)
        }
    }

    static func nearest(_ src: UnsafePointer<UInt32>, _ w: Int, _ h: Int, _ n: Int, _ dst: UnsafeMutablePointer<UInt32>) {
        let dw = w * n
        for y in 0..<h {
            let row = dst + y * n * dw
            let s = src + y * w
            for x in 0..<w {
                let c = s[x]
                let o = row + x * n
                for i in 0..<n { o[i] = c }
            }
            for r in 1..<n { (row + r * dw).update(from: row, count: dw) }
        }
    }

    static func scale2x(_ src: UnsafePointer<UInt32>, _ w: Int, _ h: Int, _ dst: UnsafeMutablePointer<UInt32>) {
        let dw = w * 2
        for y in 0..<h {
            let up = src + max(y - 1, 0) * w
            let mid = src + y * w
            let down = src + min(y + 1, h - 1) * w
            let d0 = dst + (y * 2) * dw
            let d1 = d0 + dw
            for x in 0..<w {
                let xl = max(x - 1, 0), xr = min(x + 1, w - 1)
                let b = up[x], d = mid[xl], e = mid[x], f = mid[xr], hh = down[x]
                if b != hh && d != f {
                    d0[x * 2] = d == b ? d : e
                    d0[x * 2 + 1] = b == f ? f : e
                    d1[x * 2] = d == hh ? d : e
                    d1[x * 2 + 1] = hh == f ? f : e
                } else {
                    d0[x * 2] = e; d0[x * 2 + 1] = e
                    d1[x * 2] = e; d1[x * 2 + 1] = e
                }
            }
        }
    }

    static func scale3x(_ src: UnsafePointer<UInt32>, _ w: Int, _ h: Int, _ dst: UnsafeMutablePointer<UInt32>) {
        let dw = w * 3
        for y in 0..<h {
            let up = src + max(y - 1, 0) * w
            let mid = src + y * w
            let down = src + min(y + 1, h - 1) * w
            let r0 = dst + (y * 3) * dw, r1 = r0 + dw, r2 = r1 + dw
            for x in 0..<w {
                let xl = max(x - 1, 0), xr = min(x + 1, w - 1)
                let a = up[xl], b = up[x], c = up[xr]
                let d = mid[xl], e = mid[x], f = mid[xr]
                let g = down[xl], hh = down[x], i = down[xr]
                let o = x * 3
                if b != hh && d != f {
                    r0[o] = d == b ? d : e
                    r0[o + 1] = (d == b && e != c) || (b == f && e != a) ? b : e
                    r0[o + 2] = b == f ? f : e
                    r1[o] = (d == b && e != g) || (d == hh && e != a) ? d : e
                    r1[o + 1] = e
                    r1[o + 2] = (b == f && e != i) || (hh == f && e != c) ? f : e
                    r2[o] = d == hh ? d : e
                    r2[o + 1] = (d == hh && e != i) || (hh == f && e != g) ? hh : e
                    r2[o + 2] = hh == f ? f : e
                } else {
                    r0[o] = e; r0[o + 1] = e; r0[o + 2] = e
                    r1[o] = e; r1[o + 1] = e; r1[o + 2] = e
                    r2[o] = e; r2[o + 1] = e; r2[o + 2] = e
                }
            }
        }
    }
}

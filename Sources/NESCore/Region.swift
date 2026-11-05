/// Console timing variant.
public enum Region: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case ntsc = 0
    case pal = 1
    case dendy = 2

    public var description: String {
        switch self {
        case .ntsc: return "NTSC"
        case .pal: return "PAL"
        case .dendy: return "Dendy"
        }
    }

    /// Master clock frequency in Hz.
    public var masterClockRate: Double {
        switch self {
        case .ntsc: return 21_477_272.0
        case .pal, .dendy: return 26_601_712.0
        }
    }

    /// Master clocks per CPU cycle.
    var cpuDivider: UInt64 {
        switch self {
        case .ntsc: return 12
        case .pal: return 16
        case .dendy: return 15
        }
    }

    /// Master clocks per PPU dot.
    var ppuDivider: UInt64 {
        switch self {
        case .ntsc: return 4
        case .pal, .dendy: return 5
        }
    }

    /// CPU clock in Hz.
    public var cpuClockRate: Double { masterClockRate / Double(cpuDivider) }

    /// Scanlines per frame, including the pre-render line.
    var scanlinesPerFrame: Int { self == .ntsc ? 262 : 312 }

    /// Scanline on which the vblank flag is raised.
    var vblankScanline: Int { self == .dendy ? 291 : 241 }

    /// Frames per second produced by the console.
    public var framesPerSecond: Double {
        // 341 dots per line; NTSC skips one dot on odd frames while rendering.
        let dots = self == .ntsc ? (341.0 * 262.0 - 0.5) : 341.0 * 312.0
        return masterClockRate / (dots * Double(ppuDivider))
    }
}

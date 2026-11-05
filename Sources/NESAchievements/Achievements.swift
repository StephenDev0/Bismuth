import NESCore

/// RetroAchievements support for hosts that embed the core directly (rcheevos `rc_client`).
///
/// Inside libretro frontends none of this is needed: the frontend hashes the
/// content itself and reads memory through the core's memory map. Standalone hosts use:
///  - `RAHash.nes(_:)` to identify the game (`rc_client_begin_identify_and_load_game`),
///  - `AchievementMemory.peek` as the `rc_client_read_memory_func_t`,
///  - `HardcoreGuard` to enforce hardcore rules.
public enum RAHash {
    /// RetroAchievements console id for the NES / Famicom (`RC_CONSOLE_NINTENDO`).
    public static let consoleID: UInt32 = 7

    /// The rcheevos NES hash: MD5 of the image with any 16-byte iNES/NES 2.0 (or fwNES FDS) header removed.
    public static func nes(_ file: [UInt8]) -> String {
        var body = file[...]
        if file.count >= 16 {
            let magic = Array(file[0..<4])
            if magic == [0x4E, 0x45, 0x53, 0x1A] || magic == [0x46, 0x44, 0x53, 0x1A] {
                body = file[16...]
            }
        }
        return MD5.hexDigest(body)
    }
}

/// One region of the RetroAchievements NES address space (mirrors rcheevos `rc_memory_regions_nes`).
public struct AchievementRegion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case systemRAM, mirror, hardware, saveRAM, readOnly }
    public let start: UInt32
    public let end: UInt32
    public let kind: Kind
    public let name: String
}

public enum AchievementMemory {
    /// The memory layout rcheevos expects for console id 7.
    public static let regions: [AchievementRegion] = [
        .init(start: 0x0000, end: 0x07FF, kind: .systemRAM, name: "System RAM"),
        .init(start: 0x0800, end: 0x1FFF, kind: .mirror, name: "Mirror RAM"),
        .init(start: 0x2000, end: 0x2007, kind: .hardware, name: "PPU Register"),
        .init(start: 0x2008, end: 0x3FFF, kind: .mirror, name: "Mirrored PPU Register"),
        .init(start: 0x4000, end: 0x401F, kind: .hardware, name: "APU and I/O register"),
        .init(start: 0x4020, end: 0x5FFF, kind: .readOnly, name: "Cartridge data"),
        .init(start: 0x6000, end: 0x7FFF, kind: .saveRAM, name: "Cartridge RAM"),
        .init(start: 0x8000, end: 0xFFFF, kind: .readOnly, name: "Cartridge ROM"),
    ]

    /// Reads `count` (1-4) little-endian bytes at `address` without side effects.
    /// Matches `rc_client_read_memory_func_t`: returns the number of bytes read.
    public static func read(_ console: NESConsole, address: UInt32, into buffer: UnsafeMutablePointer<UInt8>, count: UInt32) -> UInt32 {
        var n: UInt32 = 0
        while n < count {
            let a = address &+ n
            guard a <= 0xFFFF else { break }
            buffer[Int(n)] = byte(console, a)
            n += 1
        }
        return n
    }

    /// Classic `rc_peek_t` semantics: returns up to 4 bytes as a little-endian value.
    public static func peek(_ console: NESConsole, address: UInt32, numBytes: UInt32) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<min(numBytes, 4) {
            let a = address &+ i
            guard a <= 0xFFFF else { break }
            value |= UInt32(byte(console, a)) << (8 * i)
        }
        return value
    }

    static func byte(_ console: NESConsole, _ address: UInt32) -> UInt8 {
        if address < 0x2000 { return console.systemRAM[Int(address) & 0x7FF] }
        if address >= 0x6000 && address < 0x8000 {
            guard let ram = console.cartridgeRAM else { return 0 }
            return ram[(console.mapper.prgRAMOffset + Int(address & 0x1FFF)) & (ram.count - 1)]
        }
        return console.peek(UInt16(address))
    }
}

/// Enforces RetroAchievements hardcore rules for standalone hosts.
public final class HardcoreGuard {
    public private(set) var enabled = false
    unowned let console: NESConsole

    public init(console: NESConsole) { self.console = console }

    /// Entering hardcore resets the game and drops cheats, as rcheevos requires.
    public func enable() {
        enabled = true
        console.cheats.removeAll()
        console.unlimitedSprites = false
        console.reset()
    }

    public func disable() { enabled = false }

    /// Hardcore forbids loading states, cheats, slow motion and rewind.
    public var canLoadState: Bool { !enabled }
    public var canUseCheats: Bool { !enabled }
    public var canRewind: Bool { !enabled }
    public var canSlowDown: Bool { !enabled }

    public func loadState(_ data: [UInt8]) throws {
        guard canLoadState else { throw HardcoreError.forbidden("Loading save states is disabled in hardcore mode") }
        try console.loadState(data)
    }

    public func addCheat(_ code: String) throws {
        guard canUseCheats else { throw HardcoreError.forbidden("Cheats are disabled in hardcore mode") }
        try console.cheats.add(code)
    }
}

public enum HardcoreError: Error, Equatable {
    case forbidden(String)
}

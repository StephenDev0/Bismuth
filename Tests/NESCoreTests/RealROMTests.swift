import Testing
@testable import NESCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Optional smoke tests against real cartridges. Point BISMUTH_ROM_DIR at a folder of .nes files:
///
///     BISMUTH_ROM_DIR=~/Roms swift test --filter RealROM
@Suite("Real ROMs", .enabled(if: getenv("BISMUTH_ROM_DIR") != nil))
struct RealROMTests {
    static var romPaths: [String] {
        guard let dirPtr = getenv("BISMUTH_ROM_DIR") else { return [] }
        let dir = String(cString: dirPtr)
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var paths = [String]()
        while let entry = readdir(d) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name.lowercased().hasSuffix(".nes") { paths.append(dir + "/" + name) }
        }
        return paths.sorted()
    }

    static func read(_ path: String) -> [UInt8] {
        guard let f = fopen(path, "rb") else { return [] }
        defer { fclose(f) }
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = fread(&buf, 1, buf.count, f)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
    }

    @Test(arguments: romPaths)
    func bootsRendersAndStaysDeterministic(path: String) throws {
        let nes = try NESConsole(rom: Self.read(path))
        for f in 0..<600 {
            nes.setButtons(f % 120 < 5 ? [.start] : [], player: 0)
            nes.runFrame()
        }
        #expect(!nes.cpu.jammed)
        // The picture is not a single flat colour.
        let first = nes.frameBuffer[0]
        #expect((0..<(256 * 240)).contains { nes.frameBuffer[$0] != first })
        let state = nes.saveState()
        for _ in 0..<60 { nes.runFrame() }
        let frameA = Array(UnsafeBufferPointer(start: nes.frameBuffer, count: 256 * 240))
        try nes.loadState(state)
        for _ in 0..<60 { nes.runFrame() }
        let frameB = Array(UnsafeBufferPointer(start: nes.frameBuffer, count: 256 * 240))
        #expect(frameA == frameB)
    }
}

import Testing
import CLibretro
@testable import NESLibretro
@testable import NESCore

// C callbacks cannot capture context, so the fake frontend's state lives in globals.
nonisolated(unsafe) var lastWidth: UInt32 = 0
nonisolated(unsafe) var lastHeight: UInt32 = 0
nonisolated(unsafe) var audioFrames = 0
nonisolated(unsafe) var memoryMapDescriptors = 0
nonisolated(unsafe) var achievementsSupported = false
nonisolated(unsafe) var optionsRegistered = 0
nonisolated(unsafe) var buttonsHeld: Int16 = 0

let environmentCallback: retro_environment_t = { cmd, data in
    switch cmd {
    case 10: return true                                       // SET_PIXEL_FORMAT
    case 16:                                                   // SET_VARIABLES
        var p = data!.assumingMemoryBound(to: retro_variable.self)
        optionsRegistered = 0
        while p.pointee.key != nil { optionsRegistered += 1; p += 1 }
        return true
    case 36 | 0x10000:                                         // SET_MEMORY_MAPS
        memoryMapDescriptors = Int(data!.assumingMemoryBound(to: retro_memory_map.self).pointee.num_descriptors)
        return true
    case 42 | 0x10000:                                         // SET_SUPPORT_ACHIEVEMENTS
        achievementsSupported = data!.assumingMemoryBound(to: Bool.self).pointee
        return true
    case 51 | 0x10000: return true                             // GET_INPUT_BITMASKS
    default: return false
    }
}

let videoCallback: retro_video_refresh_t = { _, w, h, _ in lastWidth = w; lastHeight = h }
let audioBatchCallback: retro_audio_sample_batch_t = { _, frames in audioFrames += frames; return frames }
let audioCallback: retro_audio_sample_t = { _, _ in }
let pollCallback: retro_input_poll_t = {}
let inputCallback: retro_input_state_t = { port, device, _, id in
    port == 0 && device == 1 && id == 256 ? buttonsHeld : 0
}

@Suite("libretro ABI", .serialized)
struct LibretroTests {
    func boot(_ program: [UInt8], battery: Bool = false) -> Bool {
        var rom = TestROMBuilder.make(program: program)
        if battery { rom[6] |= 0x02 }
        LR.set_environment(environmentCallback)
        LR.set_video_refresh(videoCallback)
        LR.set_audio_sample(audioCallback)
        LR.set_audio_sample_batch(audioBatchCallback)
        LR.set_input_poll(pollCallback)
        LR.set_input_state(inputCallback)
        LR.initialize()
        return rom.withUnsafeBytes { bytes in
            var info = retro_game_info(path: nil, data: bytes.baseAddress, size: bytes.count, meta: nil)
            return LR.load_game(&info)
        }
    }

    @Test func systemInfo() {
        var info = retro_system_info()
        LR.get_system_info(&info)
        #expect(String(cString: info.library_name) == "Bismuth")
        #expect(String(cString: info.valid_extensions) == "nes")
        #expect(!info.need_fullpath)
        #expect(LR.api_version() == 1)
    }

    @Test func loadRunSerialize() {
        #expect(boot([0xE6, 0x10, 0x4C, 0x00, 0xC0], battery: true))
        #expect(optionsRegistered == 14)
        #expect(achievementsSupported)
        #expect(memoryMapDescriptors == 2)

        var av = retro_system_av_info()
        LR.get_system_av_info(&av)
        #expect(av.geometry.base_width == 256 && av.geometry.base_height == 224)
        #expect(abs(av.timing.fps - 60.0988) < 0.001)
        #expect(av.timing.sample_rate == 48_000)

        audioFrames = 0
        for _ in 0..<60 { LR.run() }
        #expect(lastWidth == 256 && lastHeight == 224)
        #expect(abs(audioFrames - 47_920) < 100)

        #expect(LR.get_memory_size(2) == 0x800)
        #expect(LR.get_memory_size(0) == 0x2000)
        #expect(LR.get_memory_data(2) != nil)

        let size = LR.serialize_size()
        #expect(size > 0)
        var state = [UInt8](repeating: 0, count: size)
        #expect(LR.serialize(&state, size))
        let ram = LR.get_memory_data(2)!.assumingMemoryBound(to: UInt8.self)
        let before = ram[0x10]
        for _ in 0..<10 { LR.run() }
        #expect(LR.unserialize(state, size))
        #expect(ram[0x10] == before)
        #expect(LR.serialize_size() == size)

        LR.unload_game()
        LR.deinit_()
    }

    @Test func cheatsAndRegion() {
        #expect(boot([0xA9, 0x01, 0x85, 0x40, 0x4C, 0x04, 0xC0]))
        LR.cheat_set(0, true, "C001:07")
        LR.reset()
        for _ in 0..<2 { LR.run() }
        let ram = LR.get_memory_data(2)!.assumingMemoryBound(to: UInt8.self)
        #expect(ram[0x40] == 0x07)
        LR.cheat_reset()
        #expect(LR.get_region() == 0)
        LR.unload_game()
        LR.deinit_()
    }

    @Test func zapperPortDevice() {
        #expect(boot([0x4C, 0x00, 0xC0]))
        LR.set_controller_port_device(1, (1 << 8) | 4)
        #expect(LibretroCore.shared.console?.input.devices[1] == .zapper)
        LR.set_controller_port_device(1, 1)
        #expect(LibretroCore.shared.console?.input.devices[1] == .standard)
        LR.unload_game()
        LR.deinit_()
    }

    @Test func rejectsBadContent() {
        LR.set_environment(environmentCallback)
        LR.initialize()
        let junk: [UInt8] = [1, 2, 3, 4]
        let ok = junk.withUnsafeBytes { bytes in
            var info = retro_game_info(path: nil, data: bytes.baseAddress, size: bytes.count, meta: nil)
            return LR.load_game(&info)
        }
        #expect(!ok)
        LR.deinit_()
    }
}

/// Same layout as the core tests' builder (kept local so the test targets stay independent).
enum TestROMBuilder {
    static func make(program: [UInt8]) -> [UInt8] {
        var prg = [UInt8](repeating: 0xEA, count: 16 * 1024)
        for (i, b) in program.enumerated() { prg[i] = b }
        prg[0x3000] = 0x40; prg[0x3800] = 0x40
        prg[0x3FFA] = 0x00; prg[0x3FFB] = 0xF0
        prg[0x3FFC] = 0x00; prg[0x3FFD] = 0xC0
        prg[0x3FFE] = 0x00; prg[0x3FFF] = 0xF8
        let header: [UInt8] = [0x4E, 0x45, 0x53, 0x1A, 1, 1, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        return header + prg + [UInt8](repeating: 0, count: 8192)
    }
}

/// Unambiguous names for the core's entry points (the C header declares the same symbols).
enum LR {
    static func api_version() -> UInt32 { NESLibretro.retro_api_version() }
    static func get_system_info(_ i: UnsafeMutablePointer<retro_system_info>?) { NESLibretro.retro_get_system_info(i) }
    static func get_system_av_info(_ i: UnsafeMutablePointer<retro_system_av_info>?) { NESLibretro.retro_get_system_av_info(i) }
    static func set_environment(_ cb: retro_environment_t?) { NESLibretro.retro_set_environment(cb) }
    static func set_video_refresh(_ cb: retro_video_refresh_t?) { NESLibretro.retro_set_video_refresh(cb) }
    static func set_audio_sample(_ cb: retro_audio_sample_t?) { NESLibretro.retro_set_audio_sample(cb) }
    static func set_audio_sample_batch(_ cb: retro_audio_sample_batch_t?) { NESLibretro.retro_set_audio_sample_batch(cb) }
    static func set_input_poll(_ cb: retro_input_poll_t?) { NESLibretro.retro_set_input_poll(cb) }
    static func set_input_state(_ cb: retro_input_state_t?) { NESLibretro.retro_set_input_state(cb) }
    static func initialize() { NESLibretro.retro_init() }
    static func deinit_() { NESLibretro.retro_deinit() }
    static func set_controller_port_device(_ p: UInt32, _ d: UInt32) { NESLibretro.retro_set_controller_port_device(p, d) }
    static func reset() { NESLibretro.retro_reset() }
    static func run() { NESLibretro.retro_run() }
    static func serialize_size() -> Int { NESLibretro.retro_serialize_size() }
    static func serialize(_ d: UnsafeMutableRawPointer?, _ n: Int) -> Bool { NESLibretro.retro_serialize(d, n) }
    static func unserialize(_ d: UnsafeRawPointer?, _ n: Int) -> Bool { NESLibretro.retro_unserialize(d, n) }
    static func cheat_reset() { NESLibretro.retro_cheat_reset() }
    static func cheat_set(_ i: UInt32, _ e: Bool, _ c: UnsafePointer<CChar>?) { NESLibretro.retro_cheat_set(i, e, c) }
    static func load_game(_ g: UnsafePointer<retro_game_info>?) -> Bool { NESLibretro.retro_load_game(g) }
    static func unload_game() { NESLibretro.retro_unload_game() }
    static func get_region() -> UInt32 { NESLibretro.retro_get_region() }
    static func get_memory_data(_ id: UInt32) -> UnsafeMutableRawPointer? { NESLibretro.retro_get_memory_data(id) }
    static func get_memory_size(_ id: UInt32) -> Int { NESLibretro.retro_get_memory_size(id) }
}

nonisolated(unsafe) var pointerPressed = false
nonisolated(unsafe) var pointerX: Int16 = 0
nonisolated(unsafe) var pointerY: Int16 = 0

let touchInputCallback: retro_input_state_t = { port, device, _, id in
    if device == 6 {   // RETRO_DEVICE_POINTER
        switch id {
        case 0: return pointerX
        case 1: return pointerY
        case 2: return pointerPressed ? 1 : 0
        default: return 0
        }
    }
    return 0
}

// Same serialized suite as the other ABI tests: they all share the core's global state.
extension LibretroTests {
    func bootWithTouch() -> Bool {
        let rom = TestROMBuilder.make(program: [0x4C, 0x00, 0xC0])
        LR.set_environment(environmentCallback)
        LR.set_video_refresh(videoCallback)
        LR.set_audio_sample(audioCallback)
        LR.set_audio_sample_batch(audioBatchCallback)
        LR.set_input_poll(pollCallback)
        LR.set_input_state(touchInputCallback)
        LR.initialize()
        return rom.withUnsafeBytes { bytes in
            var info = retro_game_info(path: nil, data: bytes.baseAddress, size: bytes.count, meta: nil)
            return LR.load_game(&info)
        }
    }

    @Test func tappingTheScreenFiresTheZapper() throws {
        #expect(bootWithTouch())
        let console = try #require(LibretroCore.shared.console)
        LR.run()
        #expect(console.input.zapperOverlay[1] == false)        // nothing plugged in before a tap
        pointerX = 0; pointerY = 0; pointerPressed = true      // centre of the picture
        LR.run()
        #expect(console.input.zapperOverlay[1])
        #expect(console.input.zappers[1].trigger)
        #expect(abs(console.input.zappers[1].x - 128) <= 1)
        #expect(abs(console.input.zappers[1].y - 120) <= 1)
        pointerPressed = false
        LR.run()
        // A quick tap still holds the trigger for a few frames and keeps aiming afterwards.
        #expect(console.input.zappers[1].trigger)
        for _ in 0..<5 { LR.run() }
        #expect(!console.input.zappers[1].trigger)
        #expect(!console.input.zappers[1].offscreen)
        for _ in 0..<12 { LR.run() }
        #expect(console.input.zappers[1].offscreen)
        // The controller half of port 2 still works: bit 0 is the pad, bits 3-4 the gun.
        console.setButtons([.a], player: 1)
        console.input.write(1); console.input.write(0)
        #expect(console.input.read(port: 1) & 0x01 == 1)
        LR.unload_game()
        LR.deinit_()
    }

    @Test func upscaledOutputSizes() {
        #expect(bootWithTouch())
        for (scaler, w, h) in [(Upscaler.scale2x, 512, 448), (.scale3x, 768, 672), (.scale4x, 1024, 896), (.sharp2x, 512, 448), (.off, 256, 224)] {
            LibretroCore.shared.upscale = scaler
            LR.run()
            #expect(lastWidth == UInt32(w) && lastHeight == UInt32(h), "\(scaler)")
        }
        var av = retro_system_av_info()
        LR.get_system_av_info(&av)
        #expect(av.geometry.max_width == 1024 && av.geometry.max_height == 960)
        LR.unload_game()
        LR.deinit_()
    }
}

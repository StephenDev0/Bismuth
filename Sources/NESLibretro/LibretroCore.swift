import CLibretro
import NESCore

// MARK: - Constants (spelled out so they do not depend on macro import rules)

enum Env {
    static let experimental: UInt32 = 0x10000
    static let setMessage: UInt32 = 6
    static let setPixelFormat: UInt32 = 10
    static let setInputDescriptors: UInt32 = 11
    static let getVariable: UInt32 = 15
    static let setVariables: UInt32 = 16
    static let getVariableUpdate: UInt32 = 17
    static let setSupportNoGame: UInt32 = 18
    static let getLogInterface: UInt32 = 27
    static let setSystemAVInfo: UInt32 = 32
    static let setControllerInfo: UInt32 = 35
    static let setMemoryMaps: UInt32 = 36 | experimental
    static let setGeometry: UInt32 = 37
    static let setSupportAchievements: UInt32 = 42 | experimental
    static let getInputBitmasks: UInt32 = 51 | experimental
}

enum Device {
    static let none: UInt32 = 0
    static let joypad: UInt32 = 1
    static let lightgun: UInt32 = 4
    static let pointer: UInt32 = 6
    static let zapper: UInt32 = ((0 + 1) << 8) | 4   // RETRO_DEVICE_SUBCLASS(LIGHTGUN, 0)
}

enum JoypadID {
    static let b: UInt32 = 0, y: UInt32 = 1, select: UInt32 = 2, start: UInt32 = 3
    static let up: UInt32 = 4, down: UInt32 = 5, left: UInt32 = 6, right: UInt32 = 7
    static let a: UInt32 = 8, x: UInt32 = 9
    static let mask: UInt32 = 256
}

enum LightgunID {
    static let trigger: UInt32 = 2
    static let screenX: UInt32 = 13
    static let screenY: UInt32 = 14
    static let isOffscreen: UInt32 = 15
    static let reload: UInt32 = 16
}

enum PointerID {
    static let x: UInt32 = 0, y: UInt32 = 1, pressed: UInt32 = 2
}

enum MemoryID {
    static let saveRAM: UInt32 = 0
    static let systemRAM: UInt32 = 2
}

let memdescSystemRAM: UInt64 = 1 << 2
let memdescSaveRAM: UInt64 = 1 << 3

// MARK: - Core state

/// Everything the libretro entry points share. libretro calls are single-threaded by contract.
final class LibretroCore {
    nonisolated(unsafe) static let shared = LibretroCore()

    var environment: retro_environment_t?
    var videoRefresh: retro_video_refresh_t?
    var audioSample: retro_audio_sample_t?
    var audioBatch: retro_audio_sample_batch_t?
    var inputPoll: retro_input_poll_t?
    var inputState: retro_input_state_t?
    var logCallback: retro_log_printf_t?

    var console: NESConsole?
    var romData: [UInt8] = []
    var romPath: String = ""
    let video = UnsafeMutablePointer<UInt32>.allocate(capacity: 256 * 240)
    var serializeSize = 0
    var hasBitmasks = false
    var frameCounter: UInt64 = 0
    var portDevices: [UInt32] = [Device.joypad, Device.joypad, Device.joypad, Device.joypad]
    var cheatCodes: [UInt32: String] = [:]
    var memoryDescriptors: UnsafeMutablePointer<retro_memory_descriptor>?
    var lastZapper = ZapperState()
    /// Upscaled output (up to 4x of 256x240).
    let scaled = UnsafeMutablePointer<UInt32>.allocate(capacity: 1024 * 960)
    let scaleScratch = UnsafeMutablePointer<UInt32>.allocate(capacity: 512 * 480)

    // Tap-to-shoot state
    var tapEverUsed = false
    var tapWasPressed = false
    var tapAim = (x: -1, y: -1)
    var tapHoldFrames = 0
    var tapTriggerFrames = 0
    var crosshairVisible = false
    /// Auto aim mode: set once the pointer shows activity, after which it wins over the light gun.
    var pointerActive = false

    // Options
    var regionOption = "Auto"
    var paletteOption = "Composite (2C02)"
    var aspectOption = "8:7 PAR"
    var cropVertical = true
    var cropHorizontal = false
    var spriteLimit = true
    var fourScore = false
    var allowOpposing = false
    var zapperInput = "Auto"
    var crosshair = true
    var ramInit = "Zeros"
    var zapperTap = true
    var upscale = Upscaler.off
    var cleanAudio = false

    init() {
        video.initialize(repeating: 0, count: 256 * 240)
    }

    // MARK: Helpers

    func log(_ message: String, level: retro_log_level = RETRO_LOG_INFO) {
        message.withCString { bismuth_log(logCallback, level, $0) }
    }

    @discardableResult
    func env(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        environment?(cmd, data) ?? false
    }

    func showMessage(_ text: String, frames: UInt32 = 240) {
        text.withCString { cstr in
            var msg = retro_message(msg: cstr, frames: frames)
            _ = env(Env.setMessage, &msg)
        }
    }

    func variable(_ key: String) -> String? {
        key.withCString { k -> String? in
            var v = retro_variable(key: k, value: nil)
            guard env(Env.getVariable, &v), let value = v.value else { return nil }
            return String(cString: value)
        }
    }

    // MARK: Options

    /// Reads all core options. Returns true when the console must be rebuilt (region / RAM init).
    @discardableResult
    func readOptions() -> Bool {
        let oldRegion = regionOption
        regionOption = variable("bismuth_region") ?? regionOption
        paletteOption = variable("bismuth_palette") ?? paletteOption
        aspectOption = variable("bismuth_aspect") ?? aspectOption
        cropVertical = (variable("bismuth_overscan_v") ?? (cropVertical ? "enabled" : "disabled")) == "enabled"
        cropHorizontal = (variable("bismuth_overscan_h") ?? (cropHorizontal ? "enabled" : "disabled")) == "enabled"
        spriteLimit = (variable("bismuth_sprite_limit") ?? (spriteLimit ? "enabled" : "disabled")) == "enabled"
        fourScore = (variable("bismuth_four_score") ?? (fourScore ? "enabled" : "disabled")) == "enabled"
        allowOpposing = (variable("bismuth_opposing") ?? (allowOpposing ? "enabled" : "disabled")) == "enabled"
        zapperInput = variable("bismuth_zapper_input") ?? zapperInput
        crosshair = (variable("bismuth_zapper_crosshair") ?? (crosshair ? "enabled" : "disabled")) == "enabled"
        ramInit = variable("bismuth_ram_init") ?? ramInit
        zapperTap = (variable("bismuth_zapper_tap") ?? (zapperTap ? "enabled" : "disabled")) == "enabled"
        if let u = variable("bismuth_upscale") { upscale = Upscaler(optionValue: u) }
        if let f = variable("bismuth_audio_filter") { cleanAudio = f.hasPrefix("Clean") }
        applyLiveOptions()
        return oldRegion != regionOption
    }

    func applyLiveOptions() {
        guard let console else { return }
        switch paletteOption {
        case "Vivid": console.palette = .vivid
        case "TV-accurate (muted)": console.palette = .tvAccurate
        case "RGB (2C03)": console.palette = .rgb
        case "Composite PAL (2C07)": console.palette = .compositePAL
        case "Greyscale": console.palette = .make(.greyscale)
        default: console.palette = console.region == .ntsc ? .composite : .compositePAL
        }
        console.unlimitedSprites = !spriteLimit
        console.audioFilter = cleanAudio ? .clean : .authentic
        if !zapperTap { console.input.zapperOverlay = [false, false] }
        console.input.fourScore = fourScore
        console.input.allowOpposingDirections = allowOpposing
        applyPortDevices()
    }

    var ramPattern: RAMInitPattern {
        switch ramInit {
        case "Ones": return .ones
        case "Alternating": return .alternating
        case "Random": return .random
        default: return .zeros
        }
    }

    func resolveRegion(_ cartridge: Cartridge) -> Region {
        switch regionOption {
        case "NTSC": return .ntsc
        case "PAL": return .pal
        case "Dendy": return .dendy
        default:
            if let r = cartridge.region { return r }
            let name = romPath.lowercased()
            let palHints = ["(e)", "(europe)", "(pal)", "(australia)", "(germany)", "(france)", "(spain)",
                            "(italy)", "(sweden)", "(netherlands)", "(uk)", "(scandinavia)"]
            let bytes = Array(name.utf8)
            return palHints.contains(where: { bytes.containsSequence(Array($0.utf8)) }) ? .pal : .ntsc
        }
    }

    // MARK: Geometry

    var cropTop: Int { cropVertical ? 8 : 0 }
    var cropBottom: Int { cropVertical ? 8 : 0 }
    var cropLeft: Int { cropHorizontal ? 8 : 0 }
    var cropRight: Int { cropHorizontal ? 8 : 0 }
    var outputWidth: Int { 256 - cropLeft - cropRight }
    var outputHeight: Int { 240 - cropTop - cropBottom }

    var aspectRatio: Float {
        let w = Float(outputWidth), h = Float(outputHeight)
        switch aspectOption {
        case "4:3": return 4.0 / 3.0
        case "1:1 PAR": return w / h
        default:
            // NTSC pixels are 8:7; PAL pixels are ~1.386 (2950000/2128137).
            let par: Float = console?.region == .ntsc || console == nil ? 8.0 / 7.0 : 1.3862
            return w * par / h
        }
    }

    var scaledWidth: Int { outputWidth * upscale.factor }
    var scaledHeight: Int { outputHeight * upscale.factor }

    func fillAVInfo(_ info: inout retro_system_av_info) {
        let region = console?.region ?? .ntsc
        info.geometry.base_width = UInt32(scaledWidth)
        info.geometry.base_height = UInt32(scaledHeight)
        // Announce the largest size up front so upscaling can change without reinitialising video.
        info.geometry.max_width = 1024
        info.geometry.max_height = 960
        info.geometry.aspect_ratio = aspectRatio
        info.timing.fps = region.framesPerSecond
        info.timing.sample_rate = 48_000
    }

    // MARK: Loading

    func buildConsole() -> Bool {
        do {
            let cart = try Cartridge(data: romData)
            guard MapperFactory.isSupported(cart.mapperID) else {
                log("Mapper \(cart.mapperID) is not supported", level: RETRO_LOG_ERROR)
                showMessage("Bismuth: mapper \(cart.mapperID) is not supported")
                return false
            }
            let previousBattery = console?.batteryRAM?.bytes
            let nes = try NESConsole(cartridge: cart, region: resolveRegion(cart), sampleRate: 48_000,
                                     ramInitPattern: ramPattern)
            if let previousBattery, let ram = nes.batteryRAM, previousBattery.count == ram.count {
                previousBattery.withUnsafeBufferPointer { ram.copy(from: $0.baseAddress!, count: $0.count) }
            }
            console = nes
            applyLiveOptions()
            applyCheats()
            serializeSize = nes.saveState().count
            log("Loaded \(MapperFactory.supportedMappers[cart.mapperID] ?? "?") (mapper \(cart.mapperID)), " +
                "PRG \(cart.prg.count / 1024)KB, CHR \(cart.chr.isEmpty ? "RAM" : "\(cart.chr.count / 1024)KB"), " +
                "\(nes.region), CRC32 \(String(cart.crc32, radix: 16, uppercase: true))")
            return true
        } catch {
            log("Failed to load ROM: \(error)", level: RETRO_LOG_ERROR)
            showMessage("Bismuth: \(error)")
            return false
        }
    }

    func publishMemoryMaps() {
        guard let console else { return }
        memoryDescriptors?.deallocate()
        let descriptors = UnsafeMutablePointer<retro_memory_descriptor>.allocate(capacity: 2)
        memoryDescriptors = descriptors
        var count: UInt32 = 0
        descriptors[0] = retro_memory_descriptor(
            flags: memdescSystemRAM, ptr: UnsafeMutableRawPointer(console.systemRAM.pointer), offset: 0,
            start: 0x0000, select: 0, disconnect: 0, len: 0x800, addrspace: bismuth_addrspace_ram())
        count += 1
        if let wram = console.cartridgeRAM {
            descriptors[1] = retro_memory_descriptor(
                flags: console.batteryRAM != nil ? memdescSaveRAM : memdescSystemRAM,
                ptr: UnsafeMutableRawPointer(wram.pointer), offset: 0,
                start: 0x6000, select: 0, disconnect: 0, len: min(wram.count, 0x2000), addrspace: bismuth_addrspace_wram())
            count += 1
        }
        var map = retro_memory_map(descriptors: UnsafePointer(descriptors), num_descriptors: count)
        env(Env.setMemoryMaps, &map)
    }

    // MARK: Input

    func applyPortDevices() {
        guard let console else { return }
        for port in 0..<2 {
            switch portDevices[port] {
            case Device.zapper: console.setDevice(.zapper, port: port)
            case Device.none: console.setDevice(.none, port: port)
            default: console.setDevice(.standard, port: port)
            }
        }
    }

    func pollInput() {
        guard let console, let state = inputState else { return }
        inputPoll?()
        let turboOn = (frameCounter / 2) & 1 == 0
        let players = fourScore ? 4 : 2
        for player in 0..<4 {
            guard player < players, portDevices[player] != Device.none, portDevices[player] != Device.zapper else {
                console.setButtons([], player: player)
                continue
            }
            let port = UInt32(player)
            var mask: Int16
            if hasBitmasks {
                mask = state(port, Device.joypad, 0, JoypadID.mask)
            } else {
                mask = 0
                for id in 0..<12 where state(port, Device.joypad, 0, UInt32(id)) != 0 { mask |= 1 << Int16(id) }
            }
            func held(_ id: UInt32) -> Bool { (mask >> Int16(id)) & 1 != 0 }
            var b = NESButtons()
            if held(JoypadID.a) || (held(JoypadID.x) && turboOn) { b.insert(.a) }
            if held(JoypadID.b) || (held(JoypadID.y) && turboOn) { b.insert(.b) }
            if held(JoypadID.select) { b.insert(.select) }
            if held(JoypadID.start) { b.insert(.start) }
            if held(JoypadID.up) { b.insert(.up) }
            if held(JoypadID.down) { b.insert(.down) }
            if held(JoypadID.left) { b.insert(.left) }
            if held(JoypadID.right) { b.insert(.right) }
            console.setButtons(b, player: player)
        }
        var explicitZapper = false
        for port in 0..<2 where portDevices[port] == Device.zapper {
            explicitZapper = true
            lastZapper = readZapper(port: UInt32(port), state: state)
            console.setZapper(port: port, x: lastZapper.x, y: lastZapper.y,
                              trigger: lastZapper.trigger, offscreen: lastZapper.offscreen)
        }
        crosshairVisible = explicitZapper && !lastZapper.offscreen
        if !explicitZapper && zapperTap && portDevices[1] != Device.none {
            updateTapZapper(console: console, state: state)
        }
    }

    /// Tap to shoot: a touch on the picture aims and fires a Zapper that shares port 2 with
    /// controller 2. The first tap plugs it in, so non-gun games are unaffected until then.
    func updateTapZapper(console: NESConsole, state: retro_input_state_t) {
        // Touches are global, not per player: RetroArch reports them on any port, index 0.
        let pressed = state(0, Device.pointer, 0, PointerID.pressed) != 0
        if pressed {
            tapAim = toNES(state(0, Device.pointer, 0, PointerID.x), state(0, Device.pointer, 0, PointerID.y))
            // Keep aiming here briefly after release: games test the light on later frames.
            tapHoldFrames = 12
            if !tapWasPressed { tapTriggerFrames = 4 }   // even the quickest tap holds the trigger 4 frames
            tapEverUsed = true
        } else if tapHoldFrames > 0 {
            tapHoldFrames -= 1
        }
        let trigger = pressed || tapTriggerFrames > 0
        if tapTriggerFrames > 0 { tapTriggerFrames -= 1 }
        tapWasPressed = pressed
        guard tapEverUsed else { return }
        console.input.zapperOverlay[1] = true
        let aiming = tapHoldFrames > 0
        lastZapper = ZapperState(x: tapAim.x, y: tapAim.y, trigger: trigger, offscreen: !aiming)
        console.setZapper(port: 1, x: tapAim.x, y: tapAim.y, trigger: trigger, offscreen: !aiming)
        crosshairVisible = aiming
    }

    /// Maps libretro's [-0x7FFF, 0x7FFF] screen coordinates onto NES pixels.
    func toNES(_ sx: Int16, _ sy: Int16) -> (Int, Int) {
        let x = (Int(sx) + 0x7FFF) * outputWidth / 0xFFFE + cropLeft
        let y = (Int(sy) + 0x7FFF) * outputHeight / 0xFFFE + cropTop
        return (min(max(x, 0), 255), min(max(y, 0), 239))
    }

    func readZapper(port: UInt32, state: retro_input_state_t) -> ZapperState {
        let pointerX = state(0, Device.pointer, 0, PointerID.x)
        let pointerY = state(0, Device.pointer, 0, PointerID.y)
        let pointerPressed = state(0, Device.pointer, 0, PointerID.pressed) != 0
        let usePointer: Bool
        switch zapperInput {
        case "Pointer / touch": usePointer = true
        case "Light gun": usePointer = false
        default:
            // Auto: follow the pointer once it shows activity (touch screens, mice), else the light gun.
            if pointerPressed || pointerX != 0 || pointerY != 0 { pointerActive = true }
            usePointer = pointerActive
        }
        if usePointer {
            let (x, y) = toNES(pointerX, pointerY)
            return ZapperState(x: x, y: y, trigger: pointerPressed, offscreen: false)
        }
        let gx = state(port, Device.lightgun, 0, LightgunID.screenX)
        let gy = state(port, Device.lightgun, 0, LightgunID.screenY)
        let offscreen = state(port, Device.lightgun, 0, LightgunID.isOffscreen) != 0
        let reload = state(port, Device.lightgun, 0, LightgunID.reload) != 0
        let trigger = state(port, Device.lightgun, 0, LightgunID.trigger) != 0
        let (x, y) = toNES(gx, gy)
        return ZapperState(x: x, y: y, trigger: trigger || reload, offscreen: offscreen || reload)
    }

    // MARK: Video

    func drawCrosshair() {
        guard crosshair, crosshairVisible, lastZapper.x >= 0 else { return }
        let cx = lastZapper.x - cropLeft, cy = lastZapper.y - cropTop
        let w = outputWidth, h = outputHeight
        func plot(_ x: Int, _ y: Int, _ c: UInt32) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            video[y * w + x] = c
        }
        for d in -5...5 where abs(d) > 1 {
            plot(cx + d, cy, 0xFFFF_FFFF); plot(cx, cy + d, 0xFFFF_FFFF)
            plot(cx + d, cy + 1, 0xFF00_0000); plot(cx + 1, cy + d, 0xFF00_0000)
        }
    }

    // MARK: Cheats

    func applyCheats() {
        guard let console else { return }
        console.cheats.removeAll()
        for index in cheatCodes.keys.sorted() {
            guard let code = cheatCodes[index] else { continue }
            do {
                try console.cheats.add(code)
            } catch {
                log("Ignoring invalid cheat \"\(code)\"", level: RETRO_LOG_WARN)
            }
        }
    }
}

private extension Array where Element == UInt8 {
    /// Substring search that does not need iOS 16's `String.contains(_:)`.
    func containsSequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return needle.isEmpty }
        for start in 0...(count - needle.count) where self[start..<start + needle.count].elementsEqual(needle) {
            return true
        }
        return false
    }
}

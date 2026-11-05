import CLibretro
import NESCore

// The libretro C ABI. Every symbol here is what a libretro frontend dlsym()s.

private var core: LibretroCore { LibretroCore.shared }

@_cdecl("retro_api_version")
public func retro_api_version() -> UInt32 { 1 }

@_cdecl("retro_get_system_info")
public func retro_get_system_info(_ info: UnsafeMutablePointer<retro_system_info>?) {
    guard let info else { return }
    info.pointee.library_name = bismuth_library_name()
    info.pointee.library_version = bismuth_library_version()
    info.pointee.valid_extensions = bismuth_valid_extensions()
    info.pointee.need_fullpath = false
    info.pointee.block_extract = false
}

@_cdecl("retro_get_system_av_info")
public func retro_get_system_av_info(_ info: UnsafeMutablePointer<retro_system_av_info>?) {
    guard let info else { return }
    core.fillAVInfo(&info.pointee)
}

@_cdecl("retro_set_environment")
public func retro_set_environment(_ cb: retro_environment_t?) {
    core.environment = cb
    var noGame = false
    core.env(Env.setSupportNoGame, &noGame)
    core.env(Env.setVariables, UnsafeMutableRawPointer(mutating: bismuth_core_variables()))
    core.env(Env.setControllerInfo, UnsafeMutableRawPointer(mutating: bismuth_controller_info()))
    var logInterface = retro_log_callback(log: nil)
    if core.env(Env.getLogInterface, &logInterface) {
        core.logCallback = logInterface.log
    }
}

@_cdecl("retro_set_video_refresh")
public func retro_set_video_refresh(_ cb: retro_video_refresh_t?) { core.videoRefresh = cb }

@_cdecl("retro_set_audio_sample")
public func retro_set_audio_sample(_ cb: retro_audio_sample_t?) { core.audioSample = cb }

@_cdecl("retro_set_audio_sample_batch")
public func retro_set_audio_sample_batch(_ cb: retro_audio_sample_batch_t?) { core.audioBatch = cb }

@_cdecl("retro_set_input_poll")
public func retro_set_input_poll(_ cb: retro_input_poll_t?) { core.inputPoll = cb }

@_cdecl("retro_set_input_state")
public func retro_set_input_state(_ cb: retro_input_state_t?) { core.inputState = cb }

@_cdecl("retro_init")
public func retro_init() {
    core.hasBitmasks = core.env(Env.getInputBitmasks, nil)
}

@_cdecl("retro_deinit")
public func retro_deinit() {
    core.console = nil
    core.romData = []
    core.memoryDescriptors?.deallocate()
    core.memoryDescriptors = nil
}

@_cdecl("retro_set_controller_port_device")
public func retro_set_controller_port_device(_ port: UInt32, _ device: UInt32) {
    guard port < 4 else { return }
    var d = device
    // Only ports 1-2 accept the Zapper; anything unknown becomes a gamepad.
    if d != Device.none && d != Device.zapper { d = Device.joypad }
    if port >= 2 && d == Device.zapper { d = Device.joypad }
    core.portDevices[Int(port)] = d
    core.applyPortDevices()
}

@_cdecl("retro_reset")
public func retro_reset() { core.console?.reset() }

@_cdecl("retro_run")
public func retro_run() {
    var updated = false
    if core.env(Env.getVariableUpdate, &updated), updated {
        let oldGeometry = (core.scaledWidth, core.scaledHeight, core.aspectRatio)
        if core.readOptions() {
            // Region changed: rebuild the machine (battery RAM is carried over) and re-announce timing.
            if core.buildConsole() {
                core.publishMemoryMaps()
                var av = retro_system_av_info()
                core.fillAVInfo(&av)
                core.env(Env.setSystemAVInfo, &av)
            }
        } else if oldGeometry != (core.scaledWidth, core.scaledHeight, core.aspectRatio) {
            var av = retro_system_av_info()
            core.fillAVInfo(&av)
            core.env(Env.setGeometry, &av.geometry)
        }
    }
    guard let console = core.console else { return }

    core.pollInput()
    console.runFrame()
    core.frameCounter &+= 1

    console.renderARGB(into: core.video, pitch: core.outputWidth, cropTop: core.cropTop, cropBottom: core.cropBottom,
                       cropLeft: core.cropLeft, cropRight: core.cropRight)
    core.drawCrosshair()
    if core.upscale == .off {
        core.videoRefresh?(UnsafeRawPointer(core.video), UInt32(core.outputWidth), UInt32(core.outputHeight),
                           core.outputWidth * 4)
    } else {
        core.upscale.apply(source: core.video, width: core.outputWidth, height: core.outputHeight,
                           destination: core.scaled, scratch: core.scaleScratch)
        core.videoRefresh?(UnsafeRawPointer(core.scaled), UInt32(core.scaledWidth), UInt32(core.scaledHeight),
                           core.scaledWidth * 4)
    }

    console.withAudio { samples in
        guard let base = samples.baseAddress, samples.count >= 2 else { return }
        var frames = samples.count / 2
        var offset = 0
        // Frontends may accept fewer frames than offered; keep feeding until done.
        while frames > 0, let batch = core.audioBatch {
            let written = batch(base + offset * 2, frames)
            if written <= 0 { break }
            frames -= written
            offset += written
        }
    }
}

@_cdecl("retro_serialize_size")
public func retro_serialize_size() -> Int { core.serializeSize }

@_cdecl("retro_serialize")
public func retro_serialize(_ data: UnsafeMutableRawPointer?, _ size: Int) -> Bool {
    guard let data, let console = core.console else { return false }
    let state = console.saveState()
    guard state.count <= size else { return false }
    state.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: state.count) }
    if size > state.count { (data + state.count).initializeMemory(as: UInt8.self, repeating: 0, count: size - state.count) }
    return true
}

@_cdecl("retro_unserialize")
public func retro_unserialize(_ data: UnsafeRawPointer?, _ size: Int) -> Bool {
    guard let data, let console = core.console, size > 0 else { return false }
    let bytes = Array(UnsafeRawBufferPointer(start: data, count: size))
    do {
        try console.loadState(bytes)
        return true
    } catch {
        core.log("Failed to load state: \(error)", level: RETRO_LOG_WARN)
        return false
    }
}

@_cdecl("retro_cheat_reset")
public func retro_cheat_reset() {
    core.cheatCodes.removeAll()
    core.applyCheats()
}

@_cdecl("retro_cheat_set")
public func retro_cheat_set(_ index: UInt32, _ enabled: Bool, _ code: UnsafePointer<CChar>?) {
    if enabled, let code {
        core.cheatCodes[index] = String(cString: code)
    } else {
        core.cheatCodes[index] = nil
    }
    core.applyCheats()
}

@_cdecl("retro_load_game")
public func retro_load_game(_ game: UnsafePointer<retro_game_info>?) -> Bool {
    guard let game, let data = game.pointee.data, game.pointee.size > 0 else { return false }
    core.romData = Array(UnsafeRawBufferPointer(start: data, count: game.pointee.size))
    core.romPath = game.pointee.path.map { String(cString: $0) } ?? ""

    var format = RETRO_PIXEL_FORMAT_XRGB8888
    guard core.env(Env.setPixelFormat, &format) else {
        core.log("XRGB8888 is not supported by the frontend", level: RETRO_LOG_ERROR)
        return false
    }
    core.env(Env.setInputDescriptors, UnsafeMutableRawPointer(mutating: bismuth_input_descriptors()))
    core.readOptions()
    guard core.buildConsole() else { return false }
    core.publishMemoryMaps()
    var achievements = true
    core.env(Env.setSupportAchievements, &achievements)
    return true
}

@_cdecl("retro_load_game_special")
public func retro_load_game_special(_ type: UInt32, _ info: UnsafePointer<retro_game_info>?, _ num: Int) -> Bool { false }

@_cdecl("retro_unload_game")
public func retro_unload_game() {
    core.console = nil
    core.romData = []
    core.cheatCodes.removeAll()
}

@_cdecl("retro_get_region")
public func retro_get_region() -> UInt32 {
    guard let console = core.console, console.region != .ntsc else { return 0 }   // RETRO_REGION_NTSC
    return 1                                                                      // RETRO_REGION_PAL
}

@_cdecl("retro_get_memory_data")
public func retro_get_memory_data(_ id: UInt32) -> UnsafeMutableRawPointer? {
    guard let console = core.console else { return nil }
    switch id {
    case MemoryID.saveRAM: return console.batteryRAM.map { UnsafeMutableRawPointer($0.pointer) }
    case MemoryID.systemRAM: return UnsafeMutableRawPointer(console.systemRAM.pointer)
    default: return nil
    }
}

@_cdecl("retro_get_memory_size")
public func retro_get_memory_size(_ id: UInt32) -> Int {
    guard let console = core.console else { return 0 }
    switch id {
    case MemoryID.saveRAM: return console.batteryRAM?.count ?? 0
    case MemoryID.systemRAM: return console.systemRAM.count
    default: return 0
    }
}

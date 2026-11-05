#if os(macOS)
import AppKit
import AVFoundation
import GameController
import MetalKit
import NESCore
import NESMetal

/// Lock-protected ring buffer of interleaved stereo Int16 samples.
final class AudioRing: @unchecked Sendable {
    private var buffer = [Int16](repeating: 0, count: 48_000)
    private var read = 0, write = 0, count = 0
    private let lock = NSLock()

    var buffered: Int { lock.lock(); defer { lock.unlock() }; return count }

    func push(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            if count == buffer.count { read = (read + 1) % buffer.count; count -= 1 }
            buffer[write] = s
            write = (write + 1) % buffer.count
            count += 1
        }
    }

    func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            if count >= 2 {
                left[i] = Float(buffer[read]) / 32768; read = (read + 1) % buffer.count
                right[i] = Float(buffer[read]) / 32768; read = (read + 1) % buffer.count
                count -= 2
            } else {
                left[i] = 0; right[i] = 0
            }
        }
    }
}

@MainActor
final class Player: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var screen: NESMetalView!
    var console: NESConsole?
    var romURL: URL?
    let audio = AudioRing()
    let engine = AVAudioEngine()
    var keys = NESButtons()
    var zapperEnabled = false
    var paused = false
    var stateSlot: [UInt8]?
    var lastBatterySave = Date()
    /// Files AppKit hands us (command line, Finder) before the window exists.
    var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 768, height: 672),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bismuth"
        window.center()
        window.delegate = self
        guard let view = NESMetalView(frame: window.contentView!.bounds) else {
            fatalError("Metal is not available")
        }
        screen = view
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.onFrame = { [weak self] v in MainActor.assumeIsolated { self?.tick(v) } }
        view.onPointer = { [weak self] x, y, inside, pressed in
            MainActor.assumeIsolated {
                guard let self, self.zapperEnabled else { return }
                self.console?.setZapper(port: 1, x: x, y: y, trigger: pressed, offscreen: !inside)
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command) else { return event }
            let code = event.keyCode, down = event.type == .keyDown
            let handled = MainActor.assumeIsolated { self.handleKey(code: code, down: down) }
            return handled ? nil : event
        }
        startAudio()
        NSApp.activate(ignoringOtherApps: true)
        if let url = pendingURL ?? CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }).map(URL.init(fileURLWithPath:)) {
            pendingURL = nil
            load(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { saveBattery() }

    // MARK: Audio

    func startAudio() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let ring = audio
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.pull(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    // MARK: Emulation

    func tick(_ view: NESMetalView) {
        guard let console, !paused else { return }
        pollControllers(console)
        // Pace emulation off the audio clock: keep ~3 frames of audio queued.
        let perFrame = Int(48_000 / console.region.framesPerSecond) * 2
        var runs = 0
        while audio.buffered < perFrame * 3 && runs < 3 {
            console.runFrame()
            console.withAudio { audio.push($0) }
            runs += 1
        }
        if runs > 0 { view.renderer.submit(console) }
        if Date().timeIntervalSince(lastBatterySave) > 15 { saveBattery() }
    }

    func pollControllers(_ console: NESConsole) {
        var pads = [keys, NESButtons()]
        for (i, controller) in GCController.controllers().prefix(2).enumerated() {
            guard let g = controller.extendedGamepad else { continue }
            var b = i == 0 ? keys : NESButtons()
            if g.buttonA.isPressed { b.insert(.b) }
            if g.buttonB.isPressed { b.insert(.a) }
            if g.buttonX.isPressed { b.insert(.b) }
            if g.buttonY.isPressed { b.insert(.a) }
            if g.buttonOptions?.isPressed == true || g.leftShoulder.isPressed { b.insert(.select) }
            if g.buttonMenu.isPressed || g.rightShoulder.isPressed { b.insert(.start) }
            let dx = g.dpad.xAxis.value + g.leftThumbstick.xAxis.value
            let dy = g.dpad.yAxis.value + g.leftThumbstick.yAxis.value
            if dx < -0.5 { b.insert(.left) }
            if dx > 0.5 { b.insert(.right) }
            if dy > 0.5 { b.insert(.up) }
            if dy < -0.5 { b.insert(.down) }
            pads[i] = b
        }
        console.setButtons(pads[0], player: 0)
        console.setButtons(pads[1], player: 1)
    }

    func handleKey(code: UInt16, down: Bool) -> Bool {
        let map: [UInt16: NESButtons] = [123: .left, 124: .right, 125: .down, 126: .up,
                                         6: .b, 7: .a, 36: .start, 48: .select, 49: .select]
        guard let button = map[code] else { return false }
        if down { keys.insert(button) } else { keys.remove(button) }
        return true
    }

    // MARK: Files

    var batteryURL: URL? {
        guard let romURL else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bismuth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(romURL.deletingPathExtension().lastPathComponent + ".sav")
    }

    func load(_ url: URL) {
        saveBattery()
        do {
            let data = try Data(contentsOf: url)
            let nes = try NESConsole(rom: [UInt8](data))
            romURL = url
            if let saveURL = batteryURL, let ram = nes.batteryRAM, let saved = try? Data(contentsOf: saveURL), saved.count == ram.count {
                saved.withUnsafeBytes { ram.copy(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: saved.count) }
            }
            nes.setDevice(zapperEnabled ? .zapper : .standard, port: 1)
            console = nes
            screen.renderer.palette = nes.palette
            window.title = "Bismuth — \(url.deletingPathExtension().lastPathComponent)"
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open \(url.lastPathComponent)"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    func saveBattery() {
        guard let ram = console?.batteryRAM, let url = batteryURL else { return }
        try? Data(ram.bytes).write(to: url)
        lastBatterySave = Date()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if screen == nil { pendingURL = url } else { load(url) }
        return true
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Bismuth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open ROM…", action: #selector(openROM), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Save State", action: #selector(saveState), keyEquivalent: "s")
        file.addItem(withTitle: "Load State", action: #selector(loadState), keyEquivalent: "l")
        fileItem.submenu = file

        let emuItem = NSMenuItem(); main.addItem(emuItem)
        let emu = NSMenu(title: "Emulation")
        emu.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        emu.addItem(withTitle: "Reset", action: #selector(resetConsole), keyEquivalent: "r")
        emu.addItem(withTitle: "Power Cycle", action: #selector(powerCycle), keyEquivalent: "R")
        emu.addItem(.separator())
        emu.addItem(withTitle: "Zapper on Port 2", action: #selector(toggleZapper), keyEquivalent: "z")
        emuItem.submenu = emu

        let videoItem = NSMenuItem(); main.addItem(videoItem)
        let video = NSMenu(title: "Video")
        for (i, f) in NESMetalRenderer.Filter.allCases.enumerated() {
            let item = video.addItem(withTitle: "Filter: \(f.rawValue)", action: #selector(setFilter(_:)), keyEquivalent: "\(i + 1)")
            item.tag = i
        }
        video.addItem(.separator())
        for (i, k) in NESPalette.Kind.allCases.enumerated() {
            let item = video.addItem(withTitle: "Palette: \(k.rawValue)", action: #selector(setPalette(_:)), keyEquivalent: "")
            item.tag = i
        }
        video.addItem(.separator())
        video.addItem(withTitle: "Integer Scaling", action: #selector(toggleIntegerScaling), keyEquivalent: "i")
        videoItem.submenu = video
        NSApp.mainMenu = main
    }

    @objc func openROM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    @objc func saveState() { stateSlot = console?.saveState() }
    @objc func loadState() { if let s = stateSlot { try? console?.loadState(s) } }
    @objc func togglePause() { paused.toggle() }
    @objc func resetConsole() { console?.reset() }
    @objc func powerCycle() { console?.powerCycle() }

    @objc func toggleZapper(_ sender: NSMenuItem) {
        zapperEnabled.toggle()
        sender.state = zapperEnabled ? .on : .off
        console?.setDevice(zapperEnabled ? .zapper : .standard, port: 1)
        zapperEnabled ? NSCursor.crosshair.push() : NSCursor.pop()
    }

    @objc func setFilter(_ sender: NSMenuItem) {
        screen.renderer.filter = NESMetalRenderer.Filter.allCases[sender.tag]
    }

    @objc func setPalette(_ sender: NSMenuItem) {
        let palette = NESPalette.make(NESPalette.Kind.allCases[sender.tag])
        console?.palette = palette
        screen.renderer.palette = palette
    }

    @objc func toggleIntegerScaling(_ sender: NSMenuItem) {
        screen.renderer.integerScaling.toggle()
        sender.state = screen.renderer.integerScaling ? .on : .off
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { Player() }
app.delegate = delegate
app.run()
#else
print("BismuthPlayer is a macOS app. On iOS/tvOS embed NESMetal's NESScreen in your own app.")
#endif

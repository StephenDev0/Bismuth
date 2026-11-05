import NESCore
import NESAchievements
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// bismuth-cli: headless driver for Bismuth.
//
//   bismuth-cli info <rom>
//   bismuth-cli hash <rom>
//   bismuth-cli run <rom> [--frames N] [--png out.png] [--png-every N --png-dir dir]
//                          [--wav out.wav] [--input "60-65:start;200-260:right+b"]
//                          [--zapper "300:128,120,fire"] [--region ntsc|pal|dendy]
//                          [--upscale scale3x] [--palette vivid] [--state-test]
//   bismuth-cli palette [composite|rgb|pal] --png out.png

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

func readFile(_ path: String) -> [UInt8] {
    guard let f = fopen(path, "rb") else { fail("cannot open \(path)") }
    defer { fclose(f) }
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = fread(&buf, 1, buf.count, f)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

func writeFile(_ path: String, _ data: [UInt8]) {
    guard let f = fopen(path, "wb") else { fail("cannot write \(path)") }
    defer { fclose(f) }
    _ = data.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, f) }
}

func now() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

func hex(_ v: UInt32, _ digits: Int = 8) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, digits - s.count)) + s
}

func parseButtons(_ s: String) -> NESButtons {
    var b = NESButtons()
    for name in s.split(separator: "+") {
        switch name.lowercased() {
        case "a": b.insert(.a)
        case "b": b.insert(.b)
        case "select", "sel": b.insert(.select)
        case "start": b.insert(.start)
        case "up": b.insert(.up)
        case "down": b.insert(.down)
        case "left": b.insert(.left)
        case "right": b.insert(.right)
        default: fail("unknown button \(name)")
        }
    }
    return b
}

/// "60-65:start;200:a" (optionally prefixed "p2@") -> per-frame button sets.
func parseTimeline(_ s: String) -> [(range: ClosedRange<Int>, player: Int, buttons: NESButtons)] {
    s.split(separator: ";").map { entry in
        var e = Substring(entry)
        var player = 0
        if e.hasPrefix("p"), let at = e.firstIndex(of: "@"), let p = Int(e[e.index(after: e.startIndex)..<at]) {
            player = p - 1
            e = e[e.index(after: at)...]
        }
        let parts = e.split(separator: ":")
        guard parts.count == 2 else { fail("bad input entry \(entry)") }
        let frames = parts[0].split(separator: "-").compactMap { Int($0) }
        guard frames.count == 1 || frames.count == 2 else { fail("bad frame range \(parts[0])") }
        return (frames[0]...(frames.count == 2 ? frames[1] : frames[0]), player, parseButtons(String(parts[1])))
    }
}

var upscaler = Upscaler.off

@MainActor func savePNG(_ nes: NESConsole, _ path: String) {
    guard upscaler != .off else {
        writeFile(path, Encoders.png(width: 256, height: 240, rgba: nes.renderRGBA()))
        return
    }
    let n = upscaler.factor
    var src = [UInt32](repeating: 0, count: 256 * 240)
    var dst = [UInt32](repeating: 0, count: 256 * 240 * n * n)
    var scratch = [UInt32](repeating: 0, count: 512 * 480)
    src.withUnsafeMutableBufferPointer { nes.renderARGB(into: $0.baseAddress!) }
    src.withUnsafeBufferPointer { s in
        dst.withUnsafeMutableBufferPointer { d in
            scratch.withUnsafeMutableBufferPointer { t in
                upscaler.apply(source: s.baseAddress!, width: 256, height: 240, destination: d.baseAddress!, scratch: t.baseAddress!)
            }
        }
    }
    var rgba = [UInt8](repeating: 255, count: dst.count * 4)
    for (i, c) in dst.enumerated() {
        rgba[i * 4] = UInt8((c >> 16) & 0xFF); rgba[i * 4 + 1] = UInt8((c >> 8) & 0xFF); rgba[i * 4 + 2] = UInt8(c & 0xFF)
    }
    writeFile(path, Encoders.png(width: 256 * n, height: 240 * n, rgba: rgba))
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: bismuth-cli info|hash|run|palette ...")
    exit(2)
}
args.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
@MainActor func flag(_ name: String) -> Bool { args.contains(name) }

switch command {
case "info":
    guard let path = args.first else { fail("missing rom") }
    let data = readFile(path)
    do {
        let cart = try Cartridge(data: data)
        print("format:     \(cart.isNES20 ? "NES 2.0" : "iNES")")
        print("mapper:     \(cart.mapperID).\(cart.submapper) (\(MapperFactory.supportedMappers[cart.mapperID] ?? "unsupported"))")
        print("prg:        \(cart.prg.count / 1024) KB")
        print("chr:        \(cart.chr.isEmpty ? "\(cart.chrRAMSize / 1024) KB RAM" : "\(cart.chr.count / 1024) KB ROM")")
        print("prg-ram:    \(cart.prgRAMSize / 1024) KB\(cart.hasBattery ? " (battery)" : "")")
        print("mirroring:  \(cart.mirroring)")
        print("region:     \(cart.region?.description ?? "unspecified")")
        print("crc32:      \(hex(cart.crc32))")
        print("ra-hash:    \(RAHash.nes(data))")
    } catch {
        fail("\(error)")
    }

case "hash":
    guard let path = args.first else { fail("missing rom") }
    print(RAHash.nes(readFile(path)))

case "palette":
    let kind: NESPalette.Kind
    switch args.first {
    case "rgb": kind = .rgb
    case "pal": kind = .compositePAL
    case "vivid": kind = .vivid
    case "tv": kind = .tvAccurate
    default: kind = .composite
    }
    let palette = NESPalette.make(kind)
    // 16 columns x 32 rows (4 rows per emphasis setting), 16x16 swatches.
    let w = 16 * 16, h = 32 * 16
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let c = palette.argb[(y / 16) * 16 + x / 16]
            let i = (y * w + x) * 4
            rgba[i] = UInt8((c >> 16) & 0xFF); rgba[i + 1] = UInt8((c >> 8) & 0xFF); rgba[i + 2] = UInt8(c & 0xFF); rgba[i + 3] = 255
        }
    }
    if let out = option("--png") { writeFile(out, Encoders.png(width: w, height: h, rgba: rgba)) }
    if flag("--dump") {
        for i in 0..<64 {
            let c = palette.argb[i]
            print("$\(hex(UInt32(i), 2)): \((c >> 16) & 0xFF) \((c >> 8) & 0xFF) \(c & 0xFF)")
        }
    }

case "run":
    guard let path = args.first else { fail("missing rom") }
    let frames = Int(option("--frames") ?? "600") ?? 600
    var region: Region?
    switch option("--region") {
    case "pal": region = .pal
    case "dendy": region = .dendy
    case "ntsc": region = .ntsc
    default: region = nil
    }
    let nes: NESConsole
    do { nes = try NESConsole(rom: readFile(path), region: region) } catch { fail("\(error)") }
    if let u = option("--upscale") { upscaler = Upscaler(optionValue: u) }
    if let p = option("--palette"), let kind = NESPalette.Kind(rawValue: p) { nes.palette = .make(kind) }
    let timeline = parseTimeline(option("--input") ?? "")
    var zapperEvents: [Int: (Int, Int, Bool)] = [:]
    if let z = option("--zapper") {
        nes.setDevice(.zapper, port: 1)
        for entry in z.split(separator: ";") {
            let p = entry.split(separator: ":")
            let f = Int(p[0]) ?? 0
            let v = p[1].split(separator: ",")
            zapperEvents[f] = (Int(v[0]) ?? 0, Int(v[1]) ?? 0, v.count > 2 && v[2] == "fire")
        }
    }
    if let codes = option("--cheat") {
        do { try nes.cheats.add(codes) } catch { fail("bad cheat: \(error)") }
    }
    let pngEvery = Int(option("--png-every") ?? "0") ?? 0
    let pngDir = option("--png-dir") ?? "."
    var audio = [Int16]()
    let collectAudio = option("--wav") != nil
    var zapper = (x: -1, y: -1, fire: false)
    let start = now()
    for f in 0..<frames {
        var pressed = [NESButtons](repeating: [], count: 4)
        for t in timeline where t.range.contains(f) { pressed[t.player].formUnion(t.buttons) }
        for p in 0..<4 { nes.setButtons(pressed[p], player: p) }
        if let z = zapperEvents[f] { zapper = (z.0, z.1, z.2) } else if zapper.fire && zapperEvents[f - 3] != nil { zapper.fire = false }
        nes.setZapper(port: 1, x: zapper.x, y: zapper.y, trigger: zapper.fire)
        nes.runFrame()
        if collectAudio { audio += nes.drainAudio() } else { _ = nes.drainAudio() }
        if pngEvery > 0 && (f + 1) % pngEvery == 0 { savePNG(nes, "\(pngDir)/frame\(f + 1).png") }
    }
    let elapsed = now() - start
    let fps = Double(frames) / elapsed
    print("frames: \(frames)  time: \(String(Int(elapsed * 1000))) ms  speed: \(Int(fps)) fps (\(Int(fps / nes.region.framesPerSecond * 100))%)")
    if let out = option("--png") { savePNG(nes, out) }
    if let out = option("--wav") { writeFile(out, Encoders.wav(samples: audio, sampleRate: 48_000)) }
    if flag("--state-test") {
        // Determinism check: save, run 120 frames, load, run 120 frames, compare.
        let state = nes.saveState()
        for _ in 0..<120 { nes.runFrame() }
        let a = nes.renderRGBA(), ramA = nes.systemRAM.bytes
        do { try nes.loadState(state) } catch { fail("loadState: \(error)") }
        for _ in 0..<120 { nes.runFrame() }
        let b = nes.renderRGBA(), ramB = nes.systemRAM.bytes
        print("state size: \(state.count) bytes, deterministic: \(a == b && ramA == ramB)")
    }
    print("pc: $\(hex(UInt32(nes.cpu.pc), 4))  frame: \(nes.frameCount)  jammed: \(nes.cpu.jammed)")

default:
    fail("unknown command \(command)")
}

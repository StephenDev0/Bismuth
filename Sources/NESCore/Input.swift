/// Standard controller buttons, in the order the NES shifts them out.
public struct NESButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let a = NESButtons(rawValue: 0x01)
    public static let b = NESButtons(rawValue: 0x02)
    public static let select = NESButtons(rawValue: 0x04)
    public static let start = NESButtons(rawValue: 0x08)
    public static let up = NESButtons(rawValue: 0x10)
    public static let down = NESButtons(rawValue: 0x20)
    public static let left = NESButtons(rawValue: 0x40)
    public static let right = NESButtons(rawValue: 0x80)
}

/// What is plugged into a controller port.
public enum InputDevice: UInt8, Sendable, CaseIterable {
    case none = 0
    case standard = 1
    /// NES Zapper light gun (normally port 2).
    case zapper = 2
}

/// Zapper state, in NES screen coordinates (0-255, 0-239). Off-screen aim never sees light.
public struct ZapperState: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var trigger: Bool
    /// Aim is pointing away from the screen (used to reload in some games).
    public var offscreen: Bool

    public init(x: Int = -1, y: Int = -1, trigger: Bool = false, offscreen: Bool = false) {
        self.x = x; self.y = y; self.trigger = trigger; self.offscreen = offscreen
    }
}

/// The two controller ports, an optional Four Score, and the Zapper's light sensor.
public final class InputPorts {
    public var devices: [InputDevice] = [.standard, .standard]
    /// NES Four Score: ports carry players 1+3 and 2+4.
    public var fourScore = false
    /// Allow Up+Down / Left+Right at once (impossible on a real D-pad; some games glitch).
    public var allowOpposingDirections = false
    /// Pixel radius checked around the Zapper's aim point (makes touch aiming forgiving).
    public var zapperRadius = 3
    /// Minimum brightness (0-255 average of R,G,B) the Zapper's photodiode reacts to.
    public var zapperLightThreshold = 110

    /// A Zapper sharing a port with a standard controller ("tap to shoot"): bit 0 still carries
    /// the controller, bits 3-4 carry the gun. Lets touch frontends fire without reconfiguring ports.
    public var zapperOverlay = [false, false]

    var buttons = [UInt8](repeating: 0, count: 4)
    public var zappers = [ZapperState(), ZapperState()]
    var shift = [UInt32](repeating: 0, count: 2)
    var strobe = false

    /// Strong but acyclic: the PPU never references the input ports.
    var ppu: PPU?
    var brightness = [UInt8](repeating: 0, count: 512)

    init() {}

    func setPalette(_ palette: NESPalette) {
        for i in 0..<512 {
            let c = palette.argb[i]
            let sum = Int((c >> 16) & 0xFF) + Int((c >> 8) & 0xFF) + Int(c & 0xFF)
            brightness[i] = UInt8(sum / 3)
        }
    }

    public func setButtons(_ value: NESButtons, player: Int) {
        guard player >= 0 && player < 4 else { return }
        var v = value.rawValue
        if !allowOpposingDirections {
            if (v & 0x30) == 0x30 { v &= ~0x30 }
            if (v & 0xC0) == 0xC0 { v &= ~0xC0 }
        }
        buttons[player] = v
    }

    public func buttons(player: Int) -> NESButtons { NESButtons(rawValue: buttons[player & 3]) }

    func write(_ value: UInt8) {
        let newStrobe = (value & 1) != 0
        if strobe && !newStrobe { latch() }
        strobe = newStrobe
        if strobe { latch() }
    }

    func latch() {
        for port in 0..<2 {
            if fourScore {
                let signature: UInt32 = port == 0 ? 0x10 : 0x20
                shift[port] = UInt32(buttons[port]) | UInt32(buttons[port + 2]) << 8 | signature << 16
            } else {
                shift[port] = UInt32(buttons[port])
            }
        }
    }

    func read(port: Int) -> UInt8 {
        switch devices[port] {
        case .none:
            return 0
        case .standard:
            if strobe { latch() }
            let bit = UInt8(shift[port] & 1)
            // Official controllers return 1 after the report; the Four Score returns 0.
            let fill: UInt32 = fourScore ? 0 : (1 << 7)
            shift[port] = (shift[port] >> 1) | fill
            return zapperOverlay[port] ? bit | zapperBits(port) : bit
        case .zapper:
            return zapperBits(port)
        }
    }

    /// Bit 4: trigger held. Bit 3: no light seen (the photodiode output is active low).
    func zapperBits(_ port: Int) -> UInt8 {
        let z = zappers[port]
        var v: UInt8 = 0
        if z.trigger { v |= 0x10 }
        if !senseLight(z) { v |= 0x08 }
        return v
    }

    /// True if the photodiode is seeing bright pixels the beam drew recently.
    func senseLight(_ z: ZapperState) -> Bool {
        guard !z.offscreen, z.x >= 0, z.x < 256, z.y >= 0, z.y < 240, let ppu else { return false }
        let line = ppu.scanline, dot = ppu.dot
        guard line < 240 || line == ppu.preRenderLine else { return false }
        let currentLine = line == ppu.preRenderLine ? -1 : line
        let r = zapperRadius
        for yy in max(0, z.y - r)...min(239, z.y + r) {
            // The diode stays lit for roughly 20 scanlines after the beam passes.
            let age = currentLine - yy
            guard age >= 0 && age <= 20 else { continue }
            for xx in max(0, z.x - r)...min(255, z.x + r) {
                if age == 0 && xx >= dot - 1 { break }   // not drawn yet this frame
                let pixel = Int(ppu.frameBuffer[yy * 256 + xx]) & 0x1FF
                if Int(brightness[pixel]) >= zapperLightThreshold { return true }
            }
        }
        return false
    }

    func saveState(_ w: inout StateWriter) {
        w.write(buttons.map { Int($0) })
        w.write(shift.map { Int($0) })
        w.write(strobe)
        for z in zappers { w.write([z.x, z.y]); w.write(z.trigger); w.write(z.offscreen) }
    }

    func loadState(_ r: inout StateReader) throws {
        let b = try r.readIntArray(), s = try r.readIntArray()
        guard b.count == 4, s.count == 2 else { throw StateError.corrupt("input") }
        buttons = b.map { UInt8(truncatingIfNeeded: $0) }
        shift = s.map { UInt32(truncatingIfNeeded: $0) }
        strobe = try r.readBool()
        for i in 0..<2 {
            let p = try r.readIntArray()
            guard p.count == 2 else { throw StateError.corrupt("zapper") }
            zappers[i] = ZapperState(x: p[0], y: p[1], trigger: try r.readBool(), offscreen: try r.readBool())
        }
    }
}

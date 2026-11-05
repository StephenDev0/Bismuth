#if canImport(MetalKit) && canImport(SwiftUI)
import MetalKit
import SwiftUI
import NESCore

/// An MTKView that presents NES frames. Set `onFrame` to run emulation from the display link
/// (it is called once per display refresh, before drawing).
public final class NESMetalView: MTKView {
    public let renderer: NESMetalRenderer
    /// Called on every display refresh, before the frame is drawn.
    public var onFrame: ((NESMetalView) -> Void)?
    /// Pointer updates in NES pixel coordinates (Zapper aiming). `inside` is false off the image.
    public var onPointer: ((_ x: Int, _ y: Int, _ inside: Bool, _ pressed: Bool) -> Void)?

    public init?(frame: CGRect = .zero, palette: NESPalette = .composite) {
        guard let renderer = NESMetalRenderer(palette: palette) else { return nil }
        self.renderer = renderer
        super.init(frame: frame, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        delegate = self
        #if os(macOS)
        layer?.isOpaque = true
        #endif
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func pointer(at location: CGPoint, pressed: Bool) {
        let scale = drawableSize.width / max(bounds.width, 1)
        #if os(macOS)
        let flipped = CGPoint(x: location.x * scale, y: (bounds.height - location.y) * scale)
        #else
        let flipped = CGPoint(x: location.x * scale, y: location.y * scale)
        #endif
        let p = renderer.nesCoordinate(for: flipped, drawableSize: drawableSize)
        onPointer?(p.x, p.y, p.inside, pressed)
    }

    #if os(macOS)
    public override var acceptsFirstResponder: Bool { true }
    public override func mouseDown(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil), pressed: true) }
    public override func mouseUp(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil), pressed: false) }
    public override func mouseDragged(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil), pressed: true) }
    public override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil), pressed: false) }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    #else
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { pointer(at: t.location(in: self), pressed: true) }
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { pointer(at: t.location(in: self), pressed: true) }
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { pointer(at: t.location(in: self), pressed: false) }
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { pointer(at: t.location(in: self), pressed: false) }
    }
    #endif
}

extension NESMetalView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        onFrame?(self)
        renderer.render(to: self)
    }
}

/// SwiftUI view that shows a console's output. Drive emulation from `onFrame`.
///
/// ```swift
/// NESScreen(console: nes) { nes in nes.runFrame() }
/// ```
public struct NESScreen {
    let console: NESConsole
    let filter: NESMetalRenderer.Filter
    let step: (NESConsole) -> Void

    public init(console: NESConsole, filter: NESMetalRenderer.Filter = .sharpBilinear,
                step: @escaping (NESConsole) -> Void = { $0.runFrame() }) {
        self.console = console
        self.filter = filter
        self.step = step
    }

    @MainActor func makeView() -> NESMetalView {
        let view = NESMetalView(palette: console.palette)!
        configure(view)
        return view
    }

    @MainActor func configure(_ view: NESMetalView) {
        view.renderer.filter = filter
        let console = self.console, step = self.step
        view.onFrame = { v in
            step(console)
            v.renderer.submit(console)
        }
        view.onPointer = { x, y, inside, pressed in
            console.setZapper(port: 1, x: x, y: y, trigger: pressed, offscreen: !inside)
        }
    }
}

#if os(macOS)
extension NESScreen: NSViewRepresentable {
    public func makeNSView(context: Context) -> NESMetalView { makeView() }
    public func updateNSView(_ view: NESMetalView, context: Context) { configure(view) }
}
#else
extension NESScreen: UIViewRepresentable {
    public func makeUIView(context: Context) -> NESMetalView { makeView() }
    public func updateUIView(_ view: NESMetalView, context: Context) { configure(view) }
}
#endif
#endif

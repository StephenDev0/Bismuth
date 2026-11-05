#if canImport(Metal)
import Metal
import MetalKit
import NESCore

/// Draws NES frames with Metal.
///
/// Frames are uploaded as raw 9-bit PPU pixel values; a compute pass converts them through the
/// active palette on the GPU (so palette changes are free and emphasis is exact), and a render pass
/// scales the result with the chosen filter and aspect ratio.
@MainActor
public final class NESMetalRenderer: NSObject, MTKViewDelegate {
    public enum Filter: String, CaseIterable, Sendable {
        case nearest, sharpBilinear, scale2x, scanlines, crt
    }

    public enum AspectMode: String, CaseIterable, Sendable {
        /// 8:7 pixel aspect ratio, how NTSC NES pixels appear on a TV.
        case ntscPixelAspect
        /// 2C07 PAL pixel aspect ratio.
        case palPixelAspect
        /// Square pixels.
        case square
        /// 4:3 display.
        case fourThree
        /// Fill the view.
        case stretch
    }

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let lookupPipeline: MTLComputePipelineState
    var renderPipelines: [Filter: MTLRenderPipelineState] = [:]
    let paletteTexture: MTLTexture
    let indexTextures: [MTLTexture]
    let colorTexture: MTLTexture
    let inflight = DispatchSemaphore(value: 3)
    var frameIndex = 0
    var hasFrame = false
    let lock = NSLock()

    public var filter: Filter = .sharpBilinear
    public var aspectMode: AspectMode = .ntscPixelAspect
    /// Only scale by whole multiples (crisper; may leave borders).
    public var integerScaling = false
    /// Overscan crop in NES pixels.
    public var cropTop = 8, cropBottom = 8, cropLeft = 0, cropRight = 0
    public var scanlineStrength: Float = 0.45
    public var crtCurvature: Float = 0.06
    public var crtMaskStrength: Float = 0.25
    public var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    public var palette: NESPalette {
        didSet { uploadPalette() }
    }

    struct Uniforms {
        var scale: SIMD2<Float>
        var sourceSize: SIMD2<Float>
        var sourceOrigin: SIMD2<Float>
        var textureSize: SIMD2<Float>
        var outputSize: SIMD2<Float>
        var scanlineStrength: Float
        var curvature: Float
        var maskStrength: Float
    }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), palette: NESPalette = .composite,
                 pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.palette = palette
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            guard let lookup = library.makeFunction(name: "nes_palette_lookup") else { return nil }
            lookupPipeline = try device.makeComputePipelineState(function: lookup)
            let fragments: [Filter: String] = [
                .nearest: "nes_fragment_nearest", .sharpBilinear: "nes_fragment_sharp", .scale2x: "nes_fragment_scale2x",
                .scanlines: "nes_fragment_scanlines", .crt: "nes_fragment_crt",
            ]
            for (filter, name) in fragments {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: "nes_vertex")
                desc.fragmentFunction = library.makeFunction(name: name)
                desc.colorAttachments[0].pixelFormat = pixelFormat
                renderPipelines[filter] = try device.makeRenderPipelineState(descriptor: desc)
            }
        } catch {
            print("NESMetalRenderer: shader compilation failed: \(error)")
            return nil
        }

        let paletteDesc = MTLTextureDescriptor()
        paletteDesc.textureType = .type1D
        paletteDesc.pixelFormat = .rgba8Unorm
        paletteDesc.width = 512
        paletteDesc.usage = .shaderRead
        guard let paletteTexture = device.makeTexture(descriptor: paletteDesc) else { return nil }
        self.paletteTexture = paletteTexture

        let indexDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: 256, height: 240, mipmapped: false)
        indexDesc.usage = .shaderRead
        indexDesc.storageMode = .shared
        var textures = [MTLTexture]()
        for _ in 0..<3 {
            guard let t = device.makeTexture(descriptor: indexDesc) else { return nil }
            textures.append(t)
        }
        indexTextures = textures

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 240, mipmapped: false)
        colorDesc.usage = [.shaderRead, .shaderWrite]
        colorDesc.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: colorDesc) else { return nil }
        self.colorTexture = colorTexture
        super.init()
        uploadPalette()
    }

    func uploadPalette() {
        var rgba = [UInt8](repeating: 0, count: 512 * 4)
        for (i, c) in palette.argb.enumerated() {
            rgba[i * 4] = UInt8((c >> 16) & 0xFF)
            rgba[i * 4 + 1] = UInt8((c >> 8) & 0xFF)
            rgba[i * 4 + 2] = UInt8(c & 0xFF)
            rgba[i * 4 + 3] = 0xFF
        }
        paletteTexture.replace(region: MTLRegionMake1D(0, 512), mipmapLevel: 0, withBytes: rgba, bytesPerRow: 512 * 4)
    }

    /// Copies a 256x240 frame of PPU pixel values (e.g. `NESConsole.frameBuffer`) for the next draw.
    public func submit(frame: UnsafePointer<UInt16>) {
        lock.lock()
        frameIndex = (frameIndex + 1) % indexTextures.count
        indexTextures[frameIndex].replace(region: MTLRegionMake2D(0, 0, 256, 240), mipmapLevel: 0,
                                          withBytes: frame, bytesPerRow: 256 * 2)
        hasFrame = true
        lock.unlock()
    }

    /// Convenience: submits the console's current frame and adopts its palette.
    public func submit(_ console: NESConsole) {
        if console.palette != palette { palette = console.palette }
        submit(frame: console.frameBuffer)
    }

    // MARK: - Layout

    var sourceWidth: Int { 256 - cropLeft - cropRight }
    var sourceHeight: Int { 240 - cropTop - cropBottom }

    /// Display aspect ratio (width / height) of the visible image.
    public var displayAspect: Double {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        switch aspectMode {
        case .ntscPixelAspect: return w * 8 / 7 / h
        case .palPixelAspect: return w * 1.3862 / h
        case .square: return w / h
        case .fourThree: return 4.0 / 3.0
        case .stretch: return 0
        }
    }

    /// Size of the image inside a drawable of `size`, in pixels.
    public func fittedSize(in size: CGSize) -> CGSize {
        let aspect = displayAspect
        guard aspect > 0 else { return size }
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        if integerScaling {
            let scale = max(1, floor(h / CGFloat(sourceHeight)))
            h = CGFloat(sourceHeight) * scale
            w = h * aspect
            if w > size.width {
                w = size.width; h = w / aspect
            }
        }
        return CGSize(width: w, height: h)
    }

    /// Converts a point in the view's drawable (pixels, origin top-left) to NES screen pixels.
    public func nesCoordinate(for point: CGPoint, drawableSize: CGSize) -> (x: Int, y: Int, inside: Bool) {
        let fit = fittedSize(in: drawableSize)
        let ox = (drawableSize.width - fit.width) / 2, oy = (drawableSize.height - fit.height) / 2
        let u = (point.x - ox) / fit.width, v = (point.y - oy) / fit.height
        let inside = u >= 0 && u < 1 && v >= 0 && v < 1
        let x = Int(u * CGFloat(sourceWidth)) + cropLeft
        let y = Int(v * CGFloat(sourceHeight)) + cropTop
        return (min(max(x, 0), 255), min(max(y, 0), 239), inside)
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        render(to: view)
    }

    /// Encodes and presents a frame into `view`'s current drawable.
    public func render(to view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        inflight.wait()
        guard let commands = queue.makeCommandBuffer() else { inflight.signal(); return }
        commands.addCompletedHandler { [inflight] _ in inflight.signal() }
        encode(into: commands, pass: pass, size: view.drawableSize)
        commands.present(drawable)
        commands.commit()
    }

    /// Renders the current frame offscreen and returns BGRA pixels (tests, screenshots).
    public func snapshot(width: Int, height: Int) -> [UInt8]? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        encode(into: commands, pass: pass, size: CGSize(width: width, height: height))
        commands.commit()
        commands.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return out
    }

    /// Palette lookup (compute) followed by the scaling/filter pass into `pass`.
    private func encode(into commands: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        lock.lock()
        let source = indexTextures[frameIndex]
        let ready = hasFrame
        lock.unlock()

        if ready, let compute = commands.makeComputeCommandEncoder() {
            compute.setComputePipelineState(lookupPipeline)
            compute.setTexture(source, index: 0)
            compute.setTexture(paletteTexture, index: 1)
            compute.setTexture(colorTexture, index: 2)
            let w = lookupPipeline.threadExecutionWidth
            let h = max(1, lookupPipeline.maxTotalThreadsPerThreadgroup / w)
            compute.dispatchThreadgroups(MTLSize(width: (256 + w - 1) / w, height: (240 + h - 1) / h, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            compute.endEncoding()
        }

        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if ready, let pipeline = renderPipelines[filter] {
            let fit = fittedSize(in: size)
            var uniforms = Uniforms(
                scale: SIMD2(Float(fit.width / size.width), Float(fit.height / size.height)),
                sourceSize: SIMD2(Float(sourceWidth), Float(sourceHeight)),
                sourceOrigin: SIMD2(Float(cropLeft), Float(cropTop)),
                textureSize: SIMD2(256, 240),
                outputSize: SIMD2(Float(fit.width), Float(fit.height)),
                scanlineStrength: scanlineStrength,
                curvature: crtCurvature,
                maskStrength: crtMaskStrength)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(colorTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }
}
#endif

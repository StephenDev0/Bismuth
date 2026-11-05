#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Band-limited step synthesis (the technique of blargg's blip_buf).
///
/// The APU's output only changes at discrete CPU cycles. Instead of averaging the 1.79 MHz signal down
/// to the output rate (which aliases), each change is added to the output as a windowed-sinc band-limited
/// step placed at its exact sub-sample time. The result is alias-free, timing-exact audio that costs work
/// only when the waveform actually changes.
final class BlipBuffer {
    static let phaseBits = 6
    static let phases = 1 << phaseBits
    static let taps = 16

    let kernel: UnsafeMutablePointer<Float>
    let capacity = 4096
    let buffer: UnsafeMutablePointer<Float>
    /// Current time in output samples, 32.32 fixed point, relative to `buffer[0]`.
    var position: UInt64 = 0
    var step: UInt64 = 0
    var integrator: Float = 0

    init(clockRate: Double, sampleRate: Double) {
        kernel = .allocate(capacity: BlipBuffer.phases * BlipBuffer.taps)
        buffer = .allocate(capacity: capacity + BlipBuffer.taps)
        buffer.initialize(repeating: 0, count: capacity + BlipBuffer.taps)
        kernel.initialize(repeating: 0, count: BlipBuffer.phases * BlipBuffer.taps)
        configure(clockRate: clockRate, sampleRate: sampleRate)
    }

    deinit {
        kernel.deallocate()
        buffer.deallocate()
    }

    func configure(clockRate: Double, sampleRate: Double) {
        step = UInt64(sampleRate / clockRate * 4_294_967_296.0)
        // Pass band up to ~20 kHz (or 90% of Nyquist at low rates).
        let cutoff = min(0.45, 20_000 / sampleRate)
        let taps = BlipBuffer.taps, half = Double(taps / 2)
        for p in 0..<BlipBuffer.phases {
            let frac = Double(p) / Double(BlipBuffer.phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: taps)
            for i in 0..<taps {
                // Distance from the step to output sample i (with a fixed delay of taps/2 - 1 samples).
                let x = Double(i) - (half - 1) - frac
                let sincArg = 2 * cutoff * x
                let sinc = abs(sincArg) < 1e-9 ? 1.0 : sin(Double.pi * sincArg) / (Double.pi * sincArg)
                let t = x / half
                let window = abs(t) >= 1 ? 0 : 0.42 + 0.5 * cos(Double.pi * t) + 0.08 * cos(2 * Double.pi * t)
                row[i] = 2 * cutoff * sinc * window
                sum += row[i]
            }
            for i in 0..<taps { kernel[p * taps + i] = Float(row[i] / sum) }
        }
    }

    func clear() {
        buffer.update(repeating: 0, count: capacity + BlipBuffer.taps)
        position &= 0xFFFF_FFFF
        integrator = 0
    }

    /// Adds an amplitude change at the current time.
    @inline(__always)
    func addDelta(_ delta: Float) {
        let index = Int(truncatingIfNeeded: position >> 32)
        let phase = Int(truncatingIfNeeded: (position >> (32 - UInt64(BlipBuffer.phaseBits)))) & (BlipBuffer.phases - 1)
        let k = kernel + phase * BlipBuffer.taps
        let b = buffer + index
        for i in 0..<BlipBuffer.taps { b[i] += delta * k[i] }
    }

    /// Advances time by one input clock.
    @inline(__always)
    func advance() { position &+= step }

    /// Whole output samples that no future delta can change.
    var available: Int { Int(truncatingIfNeeded: position >> 32) }

    /// Emits all finished samples (integrated, i.e. absolute amplitude) and slides the buffer.
    func read(_ body: (Float) -> Void) {
        let n = available
        guard n > 0 else { return }
        for i in 0..<n {
            integrator += buffer[i]
            body(integrator)
        }
        let tail = BlipBuffer.taps
        for i in 0..<tail { buffer[i] = buffer[n + i] }
        (buffer + tail).update(repeating: 0, count: n)
        position -= UInt64(n) << 32
    }
}

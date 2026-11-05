/// Metal shader source, compiled at runtime so the package needs no offline `metal` toolchain
/// (SwiftPM command-line builds cannot compile .metal files).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Pass 1: PPU pixel values (6-bit colour + emphasis) -> RGBA through the 512-entry palette.
    kernel void nes_palette_lookup(texture2d<ushort, access::read> indices [[texture(0)]],
                                   texture1d<float, access::read> palette [[texture(1)]],
                                   texture2d<float, access::write> output [[texture(2)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        ushort value = indices.read(gid).r & 0x1FF;
        output.write(palette.read(uint(value)), gid);
    }

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float2 scale;          // quad size in clip space (aspect fit)
        float2 sourceSize;     // visible source pixels
        float2 sourceOrigin;   // crop offset in source pixels
        float2 textureSize;    // full texture size (256x240)
        float2 outputSize;     // drawable size in pixels
        float scanlineStrength;
        float curvature;
        float maskStrength;
    };

    vertex VertexOut nes_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VertexOut out;
        out.position = float4(corners[vid] * u.scale, 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    float2 source_uv(float2 uv, constant Uniforms &u) {
        return (u.sourceOrigin + uv * u.sourceSize) / u.textureSize;
    }

    fragment float4 nes_fragment_nearest(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                         constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return tex.sample(s, source_uv(in.uv, u));
    }

    // Sharp bilinear: nearest within a texel, a one-output-pixel bilinear seam between texels.
    float4 sharp_sample(texture2d<float> tex, float2 uv, constant Uniforms &u) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 texel = source_uv(uv, u) * u.textureSize;
        float2 scale = max(floor(u.outputSize / u.sourceSize), float2(1.0));
        float2 fractPart = fract(texel);
        float2 region = 0.5 - 0.5 / scale;
        float2 centerDist = fractPart - 0.5;
        float2 f = (centerDist - clamp(centerDist, -region, region)) * scale + 0.5;
        float2 modTexel = floor(texel) + f;
        return tex.sample(s, modTexel / u.textureSize);
    }

    fragment float4 nes_fragment_sharp(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                       constant Uniforms &u [[buffer(0)]]) {
        return sharp_sample(tex, in.uv, u);
    }

    // Scale2x / EPX evaluated per output pixel: each source texel is split into quadrants that take a
    // neighbour's colour where a diagonal edge passes, so staircases are smoothed without blurring.
    bool same(float3 a, float3 b) { return all(abs(a - b) < 0.004); }

    fragment float4 nes_fragment_scale2x(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                         constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float2 texel = source_uv(in.uv, u) * u.textureSize;
        float2 cell = floor(texel);
        float2 f = texel - cell;
        float2 ts = 1.0 / u.textureSize;
        float2 c = (cell + 0.5) * ts;
        float3 E = tex.sample(s, c).rgb;
        float3 B = tex.sample(s, c - float2(0, ts.y)).rgb;
        float3 D = tex.sample(s, c - float2(ts.x, 0)).rgb;
        float3 F = tex.sample(s, c + float2(ts.x, 0)).rgb;
        float3 H = tex.sample(s, c + float2(0, ts.y)).rgb;
        float3 o = E;
        if (!same(B, H) && !same(D, F)) {
            if (f.y < 0.5) {
                if (f.x < 0.5) { if (same(D, B)) o = D; }
                else           { if (same(B, F)) o = F; }
            } else {
                if (f.x < 0.5) { if (same(D, H)) o = D; }
                else           { if (same(H, F)) o = F; }
            }
        }
        return float4(o, 1.0);
    }

    fragment float4 nes_fragment_scanlines(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                           constant Uniforms &u [[buffer(0)]]) {
        float4 c = sharp_sample(tex, in.uv, u);
        float y = in.uv.y * u.sourceSize.y;
        float line = 0.5 + 0.5 * cos(fract(y) * 6.2831853);
        float weight = mix(1.0, line * 0.6 + 0.55, u.scanlineStrength);
        return float4(c.rgb * weight, 1.0);
    }

    // Lightweight CRT: barrel curvature, gaussian-ish scanlines, aperture-grille mask, vignette.
    fragment float4 nes_fragment_crt(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                     constant Uniforms &u [[buffer(0)]]) {
        float2 cc = in.uv * 2.0 - 1.0;
        float2 warped = cc * (1.0 + u.curvature * dot(cc.yx, cc.yx));
        float2 uv = warped * 0.5 + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 texel = uv * u.sourceSize;
        float yCenter = floor(texel.y) + 0.5;
        float dy = texel.y - yCenter;
        float2 sampleUV = (u.sourceOrigin + float2(texel.x, yCenter)) / u.textureSize;
        float3 c = tex.sample(s, sampleUV).rgb;
        c = pow(c, float3(2.2));
        float luma = dot(c, float3(0.299, 0.587, 0.114));
        float width = mix(0.30, 0.55, luma);
        float beam = exp(-(dy * dy) / (2.0 * width * width));
        c *= mix(1.0, beam * 1.25, u.scanlineStrength);
        float px = in.position.x;
        int phase = int(px) % 3;
        float3 mask = float3(phase == 0 ? 1.0 : 1.0 - u.maskStrength,
                             phase == 1 ? 1.0 : 1.0 - u.maskStrength,
                             phase == 2 ? 1.0 : 1.0 - u.maskStrength);
        c *= mask * (1.0 + u.maskStrength * 0.6);
        float vignette = 1.0 - 0.18 * dot(cc, cc);
        c = pow(max(c, 0.0), float3(1.0 / 2.2)) * vignette;
        return float4(c, 1.0);
    }
    """
}

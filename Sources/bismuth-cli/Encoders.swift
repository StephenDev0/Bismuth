import NESCore

/// Minimal PNG (stored deflate) and WAV writers, so the CLI needs no image or audio frameworks.
enum Encoders {
    static func png(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var z: [UInt8] = [0x78, 0x01]
        var offset = 0
        while offset < raw.count || raw.isEmpty {
            let n = min(65535, raw.count - offset)
            let final = offset + n >= raw.count
            z.append(final ? 1 : 0)
            z.append(UInt8(n & 0xFF)); z.append(UInt8(n >> 8))
            z.append(UInt8(~n & 0xFF)); z.append(UInt8((~n >> 8) & 0xFF))
            z.append(contentsOf: raw[offset..<offset + n])
            offset += n
            if raw.isEmpty { break }
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        z += be32(b << 16 | a)

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr = be32(UInt32(width)) + be32(UInt32(height))
        ihdr += [8, 6, 0, 0, 0]
        out += chunk("IHDR", ihdr)
        out += chunk("IDAT", z)
        out += chunk("IEND", [])
        return out
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        return be32(UInt32(data.count)) + t + data + be32(CRC32.checksum(t + data))
    }

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    static func wav(samples: [Int16], sampleRate: Int, channels: Int = 2) -> [UInt8] {
        let dataSize = UInt32(samples.count * 2)
        var out = Array("RIFF".utf8) + le32(36 + dataSize) + Array("WAVE".utf8)
        out += Array("fmt ".utf8) + le32(16) + [1, 0, UInt8(channels), 0]
        out += le32(UInt32(sampleRate)) + le32(UInt32(sampleRate * channels * 2)) + [UInt8(channels * 2), 0, 16, 0]
        out += Array("data".utf8) + le32(dataSize)
        out.reserveCapacity(out.count + samples.count * 2)
        for s in samples { out.append(UInt8(UInt16(bitPattern: s) & 0xFF)); out.append(UInt8(UInt16(bitPattern: s) >> 8)) }
        return out
    }
}

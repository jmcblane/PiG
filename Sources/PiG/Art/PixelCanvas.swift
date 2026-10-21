import CoreGraphics
import Foundation

/// Straight-alpha RGBA color.
struct RGBA: Hashable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ hex: String, alpha: Double = 1) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255), UInt8(max(0, min(255, alpha * 255))))
    }

    private static func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    func shade(_ f: Double) -> RGBA { RGBA(Self.c(Double(r) * f), Self.c(Double(g) * f), Self.c(Double(b) * f), a) }

    func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(Self.c(Double(r) + (Double(o.r) - Double(r)) * t),
             Self.c(Double(g) + (Double(o.g) - Double(g)) * t),
             Self.c(Double(b) + (Double(o.b) - Double(b)) * t), a)
    }

    func alpha(_ v: Double) -> RGBA { RGBA(r, g, b, Self.c(v * 255)) }

    static let clear = RGBA(0, 0, 0, 0)
}

/// A small pixel buffer with crisp (non-antialiased) pixels. y points down.
/// Ported from PiAgents; only the pieces `PixelPeople` uses are kept.
final class PixelCanvas {
    let width: Int
    let height: Int
    private var px: [RGBA]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        px = Array(repeating: .clear, count: self.width * self.height)
    }

    /// Source-over blend.
    func set(_ x: Int, _ y: Int, _ c: RGBA) {
        guard x >= 0, y >= 0, x < width, y < height, c.a > 0 else { return }
        let i = y * width + x
        if c.a == 255 { px[i] = c; return }
        let d = px[i]
        let sa = Double(c.a) / 255, da = Double(d.a) / 255
        let oa = sa + da * (1 - sa)
        guard oa > 0 else { return }
        func ch(_ s: UInt8, _ dd: UInt8) -> UInt8 { UInt8(max(0, min(255, ((Double(s) * sa + Double(dd) * da * (1 - sa)) / oa).rounded()))) }
        px[i] = RGBA(ch(c.r, d.r), ch(c.g, d.g), ch(c.b, d.b), UInt8((oa * 255).rounded()))
    }

    func image() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<px.count {
            bytes[i * 4] = px[i].r; bytes[i * 4 + 1] = px[i].g; bytes[i * 4 + 2] = px[i].b; bytes[i * 4 + 3] = px[i].a
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

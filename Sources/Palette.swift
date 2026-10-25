import AppKit
import SwiftUI

/// Colours pulled from the album art, tuned to read well as glows on dark/translucent glass.
struct Palette: Equatable {
    var primary: Color    // glow on the active line, equalizer, accents
    var secondary: Color  // second aura blob
    var tint: Color       // dark wash inside the glass card

    static let neutral = Palette(primary: Color(white: 0.95),
                                 secondary: Color(white: 0.7),
                                 tint: Color(white: 0.12))

    static func from(_ image: NSImage) -> Palette {
        let side = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .neutral }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = ctx.data else { return .neutral }
        let px = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // 12 hue buckets, weighted by saturation so vivid colours win over greys.
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sumR = [Double](repeating: 0, count: bins)
        var sumG = [Double](repeating: 0, count: bins)
        var sumB = [Double](repeating: 0, count: bins)
        var totalBrightness = 0.0

        for i in 0..<(side * side) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let (h, s, v) = hsv(r, g, b)
            totalBrightness += v
            guard s > 0.22, v > 0.18 else { continue }
            let bin = min(bins - 1, Int(h * Double(bins)))
            let w = s * s * (0.4 + v)
            weight[bin] += w
            sumR[bin] += r * w; sumG[bin] += g * w; sumB[bin] += b * w
        }

        let ranked = weight.indices.sorted { weight[$0] > weight[$1] }
        guard let top = ranked.first, weight[top] > 2 else {
            // Mostly greyscale art: a soft warm/cool neutral based on overall brightness.
            let avg = totalBrightness / Double(side * side)
            return Palette(primary: Color(white: 0.96), secondary: Color(white: 0.6),
                           tint: Color(white: 0.08 + avg * 0.1))
        }
        func color(_ bin: Int) -> (Double, Double, Double) {
            hsv(sumR[bin] / weight[bin], sumG[bin] / weight[bin], sumB[bin] / weight[bin])
        }
        let p = color(top)
        let secondBin = ranked.dropFirst().first { bin in
            let d = abs(bin - top)
            return min(d, bins - d) >= 2 && weight[bin] > weight[top] * 0.15
        }
        let s2 = secondBin.map(color) ?? (fmod(p.0 + 0.08, 1), p.1 * 0.8, p.2)

        return Palette(
            primary: Color(hue: p.0, saturation: min(p.1, 0.75), brightness: max(p.2, 0.92)),
            secondary: Color(hue: s2.0, saturation: min(s2.1, 0.8), brightness: max(s2.2, 0.8)),
            tint: Color(hue: p.0, saturation: min(p.1 * 0.9, 0.7), brightness: 0.3)
        )
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = fmod((g - b) / d, 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}

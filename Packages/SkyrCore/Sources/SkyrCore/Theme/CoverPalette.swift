import CoreGraphics
import Foundation
import ImageIO

/// Two colours read from a cover: the most present vivid colour, and a darker shade of it for gradients.
public nonisolated enum CoverPalette {
    public struct Pair: Codable, Hashable, Sendable {
        public let primary: String
        public let secondary: String
    }

    public static func extract(from data: Data) -> Pair? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 48,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return extract(from: image)
    }

    public static func extract(from image: CGImage) -> Pair? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Histogram on a 6×6×6 grid, keeping the mean colour of every cell.
        struct Bin { var count = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var bins = [Bin](repeating: Bin(), count: 216)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset]) / 255, g = Double(pixels[offset + 1]) / 255, b = Double(pixels[offset + 2]) / 255
            let key = min(5, Int(r * 6)) * 36 + min(5, Int(g * 6)) * 6 + min(5, Int(b * 6))
            bins[key].count += 1
            bins[key].r += r
            bins[key].g += g
            bins[key].b += b
        }

        // Colourful, reasonably bright cells win; greys, near-white and near-black only count a little.
        var best: (score: Double, r: Double, g: Double, b: Double)?
        for bin in bins where bin.count > 0 {
            let r = bin.r / bin.count, g = bin.g / bin.count, b = bin.b / bin.count
            let (_, saturation, value) = hsv(r: r, g: g, b: b)
            var weight = 0.08 + 0.92 * saturation
            if value < 0.12 { weight *= 0.15 } else if value < 0.3 { weight *= 0.6 }
            if value > 0.94, saturation < 0.12 { weight *= 0.3 }
            let score = bin.count * weight
            if best == nil || score > best!.score { best = (score, r, g, b) }
        }
        guard let best else { return nil }

        // Average the neighbouring cells so the colour is not a quantisation artefact.
        var sum = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        for bin in bins where bin.count > 0 {
            let r = bin.r / bin.count, g = bin.g / bin.count, b = bin.b / bin.count
            let distance = ((r - best.r) * (r - best.r) + (g - best.g) * (g - best.g) + (b - best.b) * (b - best.b)).squareRoot()
            if distance < 0.2 {
                sum.r += r * bin.count
                sum.g += g * bin.count
                sum.b += b * bin.count
                sum.n += bin.count
            }
        }
        var (hue, saturation, value) = hsv(r: sum.r / sum.n, g: sum.g / sum.n, b: sum.b / sum.n)
        // Keep the tint visible on paper and away from neon.
        saturation = min(saturation, 0.85)
        value = max(value, 0.34)
        let primary = rgb(h: hue, s: saturation, v: value)
        let secondary = rgb(h: hue, s: min(1, saturation * 1.15 + 0.05), v: max(0.12, value * 0.42))
        return Pair(primary: hex(primary), secondary: hex(secondary))
    }

    public static func hsv(r: Double, g: Double, b: Double) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0.0001 {
            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        return (hue, maxC > 0 ? delta / maxC : 0, maxC)
    }

    public static func rgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    public static func hex(_ rgb: (Double, Double, Double)) -> String {
        String(format: "#%02x%02x%02x", Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()), Int((rgb.2 * 255).rounded()))
    }
}

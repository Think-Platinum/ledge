import AppKit
import SwiftUI
import os

/// Extracts dominant colors from album artwork for dynamic widget backgrounds.
///
/// Downloads the image, scales it down for fast processing, then samples
/// pixels to find dominant and accent colors. Also samples the image edges
/// for directional colour bleed. Results are cached by URL.
nonisolated class AlbumColorExtractor: @unchecked Sendable {

    struct Colors: Equatable {
        /// Dominant colour, darkened for centre glow (text-safe).
        let primary: Color
        /// Secondary accent colour, darkened.
        let secondary: Color
        /// Whether the raw primary colour is dark (brightness < 0.5).
        let isDark: Bool

        // Edge-sampled colours at near-full saturation for radial bleed.
        // Each is the average colour of one edge of the album art, lightly
        // darkened (80%) to avoid pure-white bleed.
        let edgeTop: Color
        let edgeBottom: Color
        let edgeLeading: Color
        let edgeTrailing: Color

        /// Average luminance of the raw (undarkened) primary colour (0–1).
        /// Used by the widget to decide adaptive text colour for contrast.
        let primaryLuminance: Double

        /// Overall average colour of all sampled pixels (undarkened).
        /// Used by Frosted Glass style as a tint overlay.
        let averageColor: Color
    }

    /// Thread-safe cache of extracted colors keyed by artwork URL.
    private let cache = OSAllocatedUnfairLock(initialState: [String: Colors]())

    /// Extract dominant colors from an image URL.
    func extract(from urlString: String) async -> Colors? {
        // Check cache
        if let cached = cache.withLock({ $0[urlString] }) {
            return cached
        }

        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let colors = analyzeImage(cgImage)

        cache.withLock { $0[urlString] = colors }

        return colors
    }

    /// Clear the cache (e.g., when memory is low).
    func clearCache() {
        cache.withLock { $0.removeAll() }
    }

    private func analyzeImage(_ cgImage: CGImage) -> Colors {
        let sampleSize = 24
        var pixelData = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .fallback
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        // Collect color buckets using simple quantization
        var buckets: [Int: (r: Double, g: Double, b: Double, count: Int)] = [:]
        var totalR = 0.0, totalG = 0.0, totalB = 0.0

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = (y * sampleSize + x) * 4
                let r = Double(pixelData[offset]) / 255.0
                let g = Double(pixelData[offset + 1]) / 255.0
                let b = Double(pixelData[offset + 2]) / 255.0

                totalR += r; totalG += g; totalB += b

                // Quantize to 4-bit per channel for bucketing
                let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
                if var bucket = buckets[key] {
                    bucket.r += r
                    bucket.g += g
                    bucket.b += b
                    bucket.count += 1
                    buckets[key] = bucket
                } else {
                    buckets[key] = (r, g, b, 1)
                }
            }
        }

        let pixelCount = Double(sampleSize * sampleSize)
        let avgColor = Color(red: totalR / pixelCount, green: totalG / pixelCount, blue: totalB / pixelCount)

        // Sort buckets by count (most common first), skip very dark/bright
        let sorted = buckets.values
            .filter { bucket in
                let avg = (bucket.r + bucket.g + bucket.b) / (3.0 * Double(bucket.count))
                return avg > 0.05 && avg < 0.9
            }
            .sorted { $0.count > $1.count }

        let primaryBucket = sorted.first ?? (r: 0.15, g: 0.15, b: 0.15, count: 1)
        let secondaryBucket = sorted.dropFirst().first ?? primaryBucket

        let pr = primaryBucket.r / Double(primaryBucket.count)
        let pg = primaryBucket.g / Double(primaryBucket.count)
        let pb = primaryBucket.b / Double(primaryBucket.count)

        let sr = secondaryBucket.r / Double(secondaryBucket.count)
        let sg = secondaryBucket.g / Double(secondaryBucket.count)
        let sb = secondaryBucket.b / Double(secondaryBucket.count)

        // Darken the colors for the centre glow (multiply by 0.4)
        let darkenFactor = 0.4
        let primary = Color(
            red: pr * darkenFactor,
            green: pg * darkenFactor,
            blue: pb * darkenFactor
        )
        let secondary = Color(
            red: sr * darkenFactor * 0.7,
            green: sg * darkenFactor * 0.7,
            blue: sb * darkenFactor * 0.7
        )

        // Sample the 4 edges of the image for directional bleed colours
        let edgeTop = averageEdge(pixelData: pixelData, sampleSize: sampleSize, edge: .top)
        let edgeBottom = averageEdge(pixelData: pixelData, sampleSize: sampleSize, edge: .bottom)
        let edgeLeading = averageEdge(pixelData: pixelData, sampleSize: sampleSize, edge: .leading)
        let edgeTrailing = averageEdge(pixelData: pixelData, sampleSize: sampleSize, edge: .trailing)

        let brightness = (pr + pg + pb) / 3.0
        return Colors(
            primary: primary,
            secondary: secondary,
            isDark: brightness < 0.5,
            edgeTop: edgeTop,
            edgeBottom: edgeBottom,
            edgeLeading: edgeLeading,
            edgeTrailing: edgeTrailing,
            primaryLuminance: brightness,
            averageColor: avgColor
        )
    }

    // MARK: - Edge Sampling

    private enum Edge { case top, bottom, leading, trailing }

    /// Averages the pixel colours along one edge of the sample grid.
    /// Lightly darkened (80%) to avoid pure-white bleed at widget edges.
    private func averageEdge(pixelData: [UInt8], sampleSize: Int, edge: Edge) -> Color {
        var totalR = 0.0, totalG = 0.0, totalB = 0.0
        let count = sampleSize

        for i in 0..<sampleSize {
            let offset: Int
            switch edge {
            case .top:      offset = i * 4                                          // y=0, x=i
            case .bottom:   offset = ((sampleSize - 1) * sampleSize + i) * 4       // y=last, x=i
            case .leading:  offset = (i * sampleSize) * 4                           // y=i, x=0
            case .trailing: offset = (i * sampleSize + sampleSize - 1) * 4         // y=i, x=last
            }
            totalR += Double(pixelData[offset]) / 255.0
            totalG += Double(pixelData[offset + 1]) / 255.0
            totalB += Double(pixelData[offset + 2]) / 255.0
        }

        let n = Double(count)
        // Use the true average edge colour — no darkening — so the bleed
        // matches the actual pixel colours at the album art boundary.
        return Color(
            red: totalR / n,
            green: totalG / n,
            blue: totalB / n
        )
    }
}

extension AlbumColorExtractor.Colors {
    /// Fallback colours when image analysis fails.
    nonisolated static let fallback = AlbumColorExtractor.Colors(
        primary: Color(white: 0.15),
        secondary: Color(white: 0.1),
        isDark: true,
        edgeTop: Color(white: 0.2),
        edgeBottom: Color(white: 0.2),
        edgeLeading: Color(white: 0.2),
        edgeTrailing: Color(white: 0.2),
        primaryLuminance: 0.15,
        averageColor: Color(white: 0.2)
    )
}

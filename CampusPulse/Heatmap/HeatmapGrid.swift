import CoreGraphics
import MapKit

/// A normalized (0…1) density field covering a map rect, produced by splatting
/// aggregated density cells with a Gaussian kernel. Rendering is pure and runs off the main thread.
struct HeatmapGrid: Sendable {
    let width: Int
    let height: Int
    var values: [Float]

    static func empty(width: Int, height: Int) -> HeatmapGrid {
        HeatmapGrid(width: width, height: height, values: [Float](repeating: 0, count: width * height))
    }

    /// - Parameters:
    ///   - sigmaMeters: Gaussian radius; larger values blend neighbouring cells into smoother regions.
    ///   - referenceDensity: Normalisation floor so a sparse campus doesn't render as "packed".
    static func render(
        cells: [DensityCell],
        in mapRect: MKMapRect,
        width: Int = 400,
        sigmaMeters: Double = 62,
        referenceDensity: Float = 60
    ) -> HeatmapGrid {
        let height = max(1, Int((Double(width) * mapRect.height / mapRect.width).rounded()))
        var grid = HeatmapGrid.empty(width: width, height: height)
        guard !cells.isEmpty else { return grid }

        let mapPointsPerPixel = mapRect.width / Double(width)
        let midLatitude = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate.latitude
        let mapPointsPerMeter = MKMapPointsPerMeterAtLatitude(midLatitude)
        let sigma = max(1.0, sigmaMeters * mapPointsPerMeter / mapPointsPerPixel)
        let radius = Int((sigma * 3).rounded(.up))
        let side = radius * 2 + 1

        var kernel = [Float](repeating: 0, count: side * side)
        let twoSigmaSquared = 2 * sigma * sigma
        for ky in -radius...radius {
            for kx in -radius...radius {
                let d2 = Double(kx * kx + ky * ky)
                kernel[(ky + radius) * side + (kx + radius)] = Float(exp(-d2 / twoSigmaSquared))
            }
        }

        grid.values.withUnsafeMutableBufferPointer { field in
            kernel.withUnsafeBufferPointer { k in
                for cell in cells {
                    let point = MKMapPoint(cell.coordinate.clCoordinate)
                    let cx = Int(((point.x - mapRect.minX) / mapPointsPerPixel).rounded())
                    let cy = Int(((point.y - mapRect.minY) / mapPointsPerPixel).rounded())
                    let weight = Float(cell.weight)
                    let y0 = max(0, cy - radius), y1 = min(height - 1, cy + radius)
                    let x0 = max(0, cx - radius), x1 = min(width - 1, cx + radius)
                    guard y0 <= y1, x0 <= x1 else { continue }
                    for y in y0...y1 {
                        let kRow = (y - cy + radius) * side + radius - cx
                        let fRow = y * width
                        for x in x0...x1 {
                            field[fRow + x] += weight * k[kRow + x]
                        }
                    }
                }
            }
        }

        let peak = grid.values.max() ?? 0
        let normaliser = max(peak * 0.9, referenceDensity)
        for i in grid.values.indices {
            grid.values[i] = min(1, grid.values[i] / normaliser)
        }
        return grid
    }

    func blended(with other: HeatmapGrid, fraction t: Float) -> HeatmapGrid {
        guard other.width == width, other.height == height else { return other }
        var result = self
        let inverse = 1 - t
        result.values.withUnsafeMutableBufferPointer { out in
            other.values.withUnsafeBufferPointer { target in
                for i in 0..<out.count {
                    out[i] = out[i] * inverse + target[i] * t
                }
            }
        }
        return result
    }

    /// Colors the field into an image `scale`× larger than the grid. Density values are
    /// interpolated *before* coloring, so edges stay smooth instead of showing blocky color steps.
    func makeImage(scale: Int = 2) -> CGImage? {
        let lut = HeatPalette.lookupTable
        let levels = Float(HeatPalette.lookupLevels - 1)
        let outWidth = width * scale
        let outHeight = height * scale
        let maxX = Float(width - 1)
        let maxY = Float(height - 1)
        let inverseScale = 1 / Float(scale)
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight * 4)

        pixels.withUnsafeMutableBufferPointer { out in
            lut.withUnsafeBufferPointer { table in
                values.withUnsafeBufferPointer { field in
                    for oy in 0..<outHeight {
                        let fy = min(maxY, max(0, (Float(oy) + 0.5) * inverseScale - 0.5))
                        let y0 = Int(fy)
                        let y1 = min(y0 + 1, height - 1)
                        let ty = fy - Float(y0)
                        let row0 = y0 * width
                        let row1 = y1 * width
                        for ox in 0..<outWidth {
                            let fx = min(maxX, max(0, (Float(ox) + 0.5) * inverseScale - 0.5))
                            let x0 = Int(fx)
                            let x1 = min(x0 + 1, width - 1)
                            let tx = fx - Float(x0)
                            let top = field[row0 + x0] + (field[row0 + x1] - field[row0 + x0]) * tx
                            let bottom = field[row1 + x0] + (field[row1 + x1] - field[row1 + x0]) * tx
                            let value = top + (bottom - top) * ty
                            let index = Int(value * levels) * 4
                            let o = (oy * outWidth + ox) * 4
                            out[o] = table[index]
                            out[o + 1] = table[index + 1]
                            out[o + 2] = table[index + 2]
                            out[o + 3] = table[index + 3]
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

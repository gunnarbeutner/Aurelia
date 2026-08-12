import SwiftUI

/// Waveform-style progress bar that replaces the standard slider.
/// Generates pseudo-random bars from track ID for consistent appearance.
struct WaveformView: View {
    static let barSpacing: CGFloat = 1.5

    let currentTime: Double
    let duration: Double
    let trackId: String
    let onSeek: (Double) -> Void

    var barCount: Int = 60

    @State private var isDragging = false
    @State private var dragTime: Double = 0

    private var progress: Double {
        guard duration > 0 else { return 0 }
        let time = isDragging ? dragTime : currentTime
        return min(max(time / duration, 0), 1)
    }

    private var bars: [CGFloat] {
        generateBars(for: trackId, count: barCount)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let rects = Self.barRects(in: size, heights: bars)

                for (index, rect) in rects.enumerated() {
                    let barProgress = Double(index) / Double(bars.count)
                    let path = Path(
                        roundedRect: rect,
                        cornerRadius: min(1, rect.width / 2)
                    )
                    context.fill(
                        path,
                        with: .color(barProgress <= progress ? .appAccent : .appBorder)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let pct = min(max(value.location.x / geo.size.width, 0), 1)
                        dragTime = pct * duration
                    }
                    .onEnded { value in
                        let pct = min(max(value.location.x / geo.size.width, 0), 1)
                        onSeek(pct * duration)
                        isDragging = false
                    }
            )
        }
    }

    /// Produces a bounded set of waveform bars. Keeping this calculation
    /// independent of SwiftUI's intrinsic sizing prevents the waveform from
    /// expanding its parent scroll view beyond the device width.
    static func barRects(in size: CGSize, heights: [CGFloat]) -> [CGRect] {
        guard !heights.isEmpty, size.width > 0, size.height > 0 else { return [] }

        let gapCount = max(0, heights.count - 1)
        let spacing = gapCount > 0
            ? min(barSpacing, size.width / CGFloat(gapCount))
            : 0
        let totalSpacing = spacing * CGFloat(gapCount)
        let barWidth = max(0, (size.width - totalSpacing) / CGFloat(heights.count))

        return heights.enumerated().map { index, heightFraction in
            let barHeight = size.height * min(max(heightFraction, 0), 1)
            return CGRect(
                x: CGFloat(index) * (barWidth + spacing),
                y: (size.height - barHeight) / 2,
                width: barWidth,
                height: barHeight
            )
        }
    }

    // MARK: - Bar Generation (seeded pseudo-random, matches PWA)

    private func generateBars(for id: String, count: Int) -> [CGFloat] {
        var seed = hashString(id)
        var bars: [CGFloat] = []

        for i in 0..<count {
            seed = (seed &* 9301 &+ 49297) % 233280
            let raw = CGFloat(seed) / 233280.0
            let baseHeight = 0.3 + raw * 0.7

            let smoothingFactor: CGFloat = 0.15
            let prevHeight = i > 0 ? bars[i - 1] : baseHeight
            let height = prevHeight * smoothingFactor + baseHeight * (1 - smoothingFactor)
            bars.append(min(max(height, 0.2), 1.0))
        }
        return bars
    }

    private func hashString(_ str: String) -> Int {
        var hash = 0
        for char in str.unicodeScalars {
            hash = ((hash &<< 5) &- hash) &+ Int(char.value)
        }
        return abs(hash)
    }
}

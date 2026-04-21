import SwiftUI

/// Full-featured candlestick chart drawn with Canvas. Includes price grid +
/// right-axis labels, volume histogram in the lower section, MA7/25/99
/// overlays, last-price tag, and a thin time strip at the bottom.
///
/// The chart is pannable: drag horizontally to scroll older candles into
/// view. The visible window defaults to 80 candles. When the drag stops at
/// the right edge (scrollOffset == 0) the chart auto-follows newly-arrived
/// bars; if the user has scrolled back, the offset is preserved.
struct KLineChartView: View {
    let candles: [Candle]
    let height: CGFloat

    private let axisWidth: CGFloat = 54
    private let timeStripHeight: CGFloat = 14
    private let volumeShare: CGFloat = 0.22
    private let gridDivisions = 4
    private let barGap: CGFloat = 1
    private let defaultVisible: Int = 80
    private let minVisible: Int = 20
    private let maxVisible: Int = 250

    @State private var visibleCount: Int = 80
    @State private var scrollOffset: Int = 0      // candles shifted from the right edge
    @State private var dragStart: Int = 0
    @State private var pinchStart: Int = 0

    var body: some View {
        GeometryReader { geo in
            Group {
                if candles.count < 2 {
                    Rectangle()
                        .fill(Color.gray.opacity(0.06))
                        .overlay { ProgressView().controlSize(.small) }
                } else {
                    Canvas(rendersAsynchronously: false) { context, size in
                        draw(context: context, size: size, visibleCandles: visibleSlice)
                    }
                    .contentShape(Rectangle())
                    .gesture(panGesture(geo: geo))
                    .gesture(zoomGesture())
                }
            }
        }
        .frame(height: height)
    }

    // MARK: - Gestures

    private func panGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let plotWidth = geo.size.width - axisWidth
                let bw = plotWidth / CGFloat(max(1, visibleCount))
                let delta = Int(value.translation.width / bw)
                let maxOffset = max(0, candles.count - visibleCount)
                scrollOffset = min(maxOffset, max(0, dragStart + delta))
            }
            .onEnded { _ in
                dragStart = scrollOffset
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = Double(pinchStart > 0 ? pinchStart : visibleCount)
                let next = Int((base / value.magnification).rounded())
                visibleCount = min(maxVisible, max(minVisible, next))
            }
            .onEnded { _ in
                pinchStart = visibleCount
            }
    }

    private var visibleSlice: [Candle] {
        let total = candles.count
        let end = total - scrollOffset
        let start = max(0, end - visibleCount)
        guard start < end else { return [] }
        return Array(candles[start..<min(end, total)])
    }

    // MARK: - Draw

    private func draw(context: GraphicsContext, size: CGSize, visibleCandles: [Candle]) {
        let plotWidth = size.width - axisWidth
        guard plotWidth > 0, size.height > timeStripHeight + 10, visibleCandles.count >= 2 else { return }

        let priceAreaHeight = (size.height - timeStripHeight) * (1 - volumeShare)
        let volumeAreaHeight = (size.height - timeStripHeight) * volumeShare
        let volumeTopY = priceAreaHeight

        let (lo, hi) = priceRange(of: visibleCandles)
        let priceSpan = hi - lo
        guard priceSpan > 0 else { return }

        let volMax = visibleCandles.map { Double($0.volume) }.max() ?? 1
        let barWidth = max(1, (plotWidth - CGFloat(visibleCandles.count) * barGap) / CGFloat(visibleCandles.count))

        drawGrid(context: context, plotWidth: plotWidth, priceAreaHeight: priceAreaHeight, lo: lo, hi: hi, priceSpan: priceSpan, rightEdge: size.width)
        drawCandles(context: context, candles: visibleCandles, barWidth: barWidth, priceAreaHeight: priceAreaHeight, lo: lo, priceSpan: priceSpan, volumeTopY: volumeTopY, volumeAreaHeight: volumeAreaHeight, volMax: volMax)
        drawMA(context: context, visible: visibleCandles, period: 7, color: .yellow, barWidth: barWidth, priceAreaHeight: priceAreaHeight, lo: lo, priceSpan: priceSpan)
        drawMA(context: context, visible: visibleCandles, period: 25, color: .purple, barWidth: barWidth, priceAreaHeight: priceAreaHeight, lo: lo, priceSpan: priceSpan)
        drawMA(context: context, visible: visibleCandles, period: 99, color: .pink, barWidth: barWidth, priceAreaHeight: priceAreaHeight, lo: lo, priceSpan: priceSpan)
        drawLastPrice(context: context, visible: visibleCandles, plotWidth: plotWidth, priceAreaHeight: priceAreaHeight, lo: lo, priceSpan: priceSpan, rightEdge: size.width)
        drawTimeStrip(context: context, visible: visibleCandles, barWidth: barWidth, topY: size.height - timeStripHeight + 2)
        drawVolumeAxis(context: context, rightEdge: size.width, volumeTopY: volumeTopY, volMax: volMax)
    }

    // MARK: - Segments

    private func drawGrid(context: GraphicsContext, plotWidth: CGFloat, priceAreaHeight: CGFloat, lo: Double, hi: Double, priceSpan: Double, rightEdge: CGFloat) {
        for i in 0...gridDivisions {
            let t = CGFloat(i) / CGFloat(gridDivisions)
            let y = t * priceAreaHeight
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: plotWidth, y: y))
            context.stroke(line, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            let price = hi - Double(t) * priceSpan
            context.draw(
                Text(Formatters.price(price))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary),
                at: CGPoint(x: rightEdge - 2, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawCandles(context: GraphicsContext, candles: [Candle], barWidth: CGFloat, priceAreaHeight: CGFloat, lo: Double, priceSpan: Double, volumeTopY: CGFloat, volumeAreaHeight: CGFloat, volMax: Double) {
        for i in 0..<candles.count {
            let c = candles[i]
            let x = CGFloat(i) * (barWidth + barGap) + barWidth / 2
            let isUp = c.close >= c.open
            let color: Color = isUp ? .brandUp : .brandDown

            let yOpen  = priceAreaHeight - CGFloat((Double(c.open)  - lo) / priceSpan) * priceAreaHeight
            let yClose = priceAreaHeight - CGFloat((Double(c.close) - lo) / priceSpan) * priceAreaHeight
            let yHigh  = priceAreaHeight - CGFloat((Double(c.high)  - lo) / priceSpan) * priceAreaHeight
            let yLow   = priceAreaHeight - CGFloat((Double(c.low)   - lo) / priceSpan) * priceAreaHeight

            var wick = Path()
            wick.move(to: CGPoint(x: x, y: yHigh))
            wick.addLine(to: CGPoint(x: x, y: yLow))
            context.stroke(wick, with: .color(color), lineWidth: 1)

            let bodyTop = min(yOpen, yClose)
            let bodyBottom = max(yOpen, yClose)
            let bodyHeight = max(1, bodyBottom - bodyTop)
            let bodyRect = CGRect(x: x - barWidth / 2, y: bodyTop, width: barWidth, height: bodyHeight)
            context.fill(Path(bodyRect), with: .color(color))

            if volMax > 0 {
                let volH = CGFloat(Double(c.volume) / volMax) * volumeAreaHeight
                let volRect = CGRect(
                    x: x - barWidth / 2,
                    y: volumeTopY + (volumeAreaHeight - volH),
                    width: barWidth,
                    height: volH
                )
                context.fill(Path(volRect), with: .color(color.opacity(0.5)))
            }
        }
    }

    private func drawMA(context: GraphicsContext, visible: [Candle], period: Int, color: Color, barWidth: CGFloat, priceAreaHeight: CGFloat, lo: Double, priceSpan: Double) {
        guard visible.count >= period else { return }
        var path = Path()
        var started = false
        for i in (period - 1)..<visible.count {
            var sum = 0.0
            for j in (i - period + 1)...i {
                sum += Double(visible[j].close)
            }
            let avg = sum / Double(period)
            let x = CGFloat(i) * (barWidth + barGap) + barWidth / 2
            let y = priceAreaHeight - CGFloat((avg - lo) / priceSpan) * priceAreaHeight
            if !started {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.2)
    }

    private func drawLastPrice(context: GraphicsContext, visible: [Candle], plotWidth: CGFloat, priceAreaHeight: CGFloat, lo: Double, priceSpan: Double, rightEdge: CGFloat) {
        guard let last = visible.last else { return }
        let y = priceAreaHeight - CGFloat((Double(last.close) - lo) / priceSpan) * priceAreaHeight
        let up = last.close >= last.open
        let color: Color = up ? .brandUp : .brandDown

        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: plotWidth, y: y))
        context.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))

        let label = Formatters.price(Double(last.close))
        let labelSize: CGFloat = 52
        let tagRect = CGRect(x: rightEdge - labelSize, y: y - 8, width: labelSize - 2, height: 16)
        context.fill(Path(roundedRect: tagRect, cornerSize: CGSize(width: 3, height: 3)), with: .color(color))
        context.draw(
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white),
            at: CGPoint(x: rightEdge - labelSize / 2 - 1, y: y),
            anchor: .center
        )
    }

    private func drawTimeStrip(context: GraphicsContext, visible: [Candle], barWidth: CGFloat, topY: CGFloat) {
        guard visible.count >= 2 else { return }
        let indices = [0, visible.count / 4, visible.count / 2, visible.count * 3 / 4, visible.count - 1]
        let fmt = DateFormatter()
        fmt.dateFormat = visible.count > 200 ? "MM-dd" : "HH:mm"
        for i in indices {
            guard i < visible.count else { continue }
            let x = CGFloat(i) * (barWidth + barGap) + barWidth / 2
            let text = fmt.string(from: visible[i].date)
            context.draw(
                Text(text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary),
                at: CGPoint(x: x, y: topY + 6),
                anchor: .center
            )
        }
    }

    private func drawVolumeAxis(context: GraphicsContext, rightEdge: CGFloat, volumeTopY: CGFloat, volMax: Double) {
        context.draw(
            Text(Formatters.compact(volMax))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.secondary),
            at: CGPoint(x: rightEdge - 2, y: volumeTopY + 2),
            anchor: .topTrailing
        )
    }

    // MARK: - Range

    private func priceRange(of window: [Candle]) -> (Double, Double) {
        let lows = window.map { Double($0.low) }
        let highs = window.map { Double($0.high) }
        let lo = lows.min() ?? 0
        let hi = highs.max() ?? 1
        let padding = (hi - lo) * 0.05
        return (lo - padding, hi + padding)
    }
}

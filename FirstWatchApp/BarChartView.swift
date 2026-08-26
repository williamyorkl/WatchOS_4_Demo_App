import SwiftUI

/// A lightweight, dependency-free bar chart for SwiftUI (iOS 14+).
///
/// Apple's Swift Charts needs iOS 16, and pulling in DGCharts for a single bar
/// view would violate the razor principle. This hand-rolled chart covers exactly
/// what History needs.
///
/// Design notes (fixes a round of issues):
/// - Bars are `Identifiable` by a STABLE index (not UUID()), so re-renders keep
///   identity and animate instead of flashing.
/// - Empty bars render a faint minimum-height stub so the time axis stays
///   readable (a flat line of zero-height bars is invisible).
/// - Small positive values get a minimum height so "a little" ≠ "nothing".
/// - A visible baseline + a couple of Y-axis gridlines anchor the values.
/// - Tappable bars call back so History can drill in later.
struct BarChartView: View {

    /// One bar. `id` is a stable caller-supplied key (e.g. hour Int or day
    /// string) so identity survives data refreshes.
    struct Bar: Identifiable {
        let id: String
        let value: Double
        let label: String          // x-axis caption (e.g. "Mon" or "Jun")
        let valueLabel: String?    // optional value text above the bar
    }

    let bars: [Bar]
    var accent: Color = .successGreen
    var height: CGFloat = 180
    /// Called when a bar is tapped (index into `bars`).
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(bars.map(\.value).max() ?? 1, 1)
            let barCount = max(bars.count, 1)
            let spacing: CGFloat = 6
            let labelArea: CGFloat = 34    // reserved for x-axis label + value label
            let plotHeight = max(geo.size.height - labelArea, 20)
            let barWidth = max((geo.size.width - spacing * CGFloat(max(barCount - 1, 0))) / CGFloat(barCount), 6)

            VStack(alignment: .leading, spacing: 0) {
                // Plot area with gridlines.
                ZStack(alignment: .bottomLeading) {
                    gridlines(plotHeight: plotHeight, maxValue: maxValue)

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(bars) { bar in
                            barColumn(bar: bar,
                                      maxValue: maxValue,
                                      plotHeight: plotHeight,
                                      barWidth: barWidth,
                                      index: bars.firstIndex(where: { $0.id == bar.id }) ?? 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                }
                .frame(height: plotHeight)

                // Baseline.
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)

                // X-axis labels (rendered once here, not per-bar, for alignment).
                HStack(spacing: spacing) {
                    ForEach(bars) { bar in
                        Text(bar.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: barWidth)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .frame(height: height)
    }

    // MARK: - Subviews

    /// Two faint horizontal gridlines (at 50% and 100% of max) to anchor values.
    @ViewBuilder
    private func gridlines(plotHeight: CGFloat, maxValue: Double) -> some View {
        VStack {
            HStack {
                Text(formatTick(maxValue))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            Spacer()
            HStack {
                Text(formatTick(maxValue / 2))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .overlay(
                // dashed midline
                Line()
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(dash: [3, 3]))
            )
            .frame(height: plotHeight / 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: plotHeight, alignment: .top)
    }

    /// A single bar with its value label and tap handling.
    @ViewBuilder
    private func barColumn(bar: Bar, maxValue: Double, plotHeight: CGFloat,
                           barWidth: CGFloat, index: Int) -> some View {
        let h = barHeight(value: bar.value, maxValue: maxValue, available: plotHeight)

        VStack(spacing: 3) {
            if let v = bar.valueLabel, bar.value > 0 {
                Text(v)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }

            if bar.value > 0 {
                RoundedRectangle(cornerRadius: min(barWidth / 3, 4))
                    .fill(accent)
                    .frame(width: barWidth, height: h)
                    .shadow(color: accent.opacity(0.3), radius: 2)
            } else {
                // Empty stub so the time axis stays visible/readable.
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: barWidth * 0.5, height: 3)
            }
        }
        .frame(width: barWidth, height: plotHeight, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { onTap?(index) }
    }

    /// Map a value to a pixel height, with a floor so tiny-but-nonzero values
    /// are still distinguishable from zero.
    private func barHeight(value: Double, maxValue: Double, available: CGFloat) -> CGFloat {
        guard maxValue > 0, available > 0, value > 0 else { return 0 }
        let ratio = value / maxValue
        let floor: CGFloat = 6   // minimum visible bar height for any nonzero value
        return max(floor, CGFloat(ratio) * available)
    }

    private func formatTick(_ v: Double) -> String {
        let s = Int(v.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m"
    }
}

/// A simple horizontal line shape for the dashed gridline.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 30, y: rect.midY))   // leave room for tick label
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

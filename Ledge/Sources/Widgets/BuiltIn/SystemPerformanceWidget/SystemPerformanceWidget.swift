import SwiftUI
import Combine

/// System performance widget showing CPU, Memory, Disk usage, and Network bandwidth.
struct SystemPerformanceWidget {

    struct Config: Codable, Equatable {
        var showCPU: Bool = true
        var showMemory: Bool = true
        var showDisk: Bool = true
        var showNetwork: Bool = true
    }

    /// Shared history store that survives page changes.
    /// When the widget view is destroyed (page switch), data lives here.
    /// When a new view appears, it reads from this store immediately.
    @MainActor
    final class SharedHistory {
        static let shared = SharedHistory()

        /// Number of visible points on the chart. Arrays keep up to maxHistory + 1
        /// points — the extra point is the "incoming" sample that scrolls into view.
        static let maxHistory = 60

        var metrics = SystemPerformanceProvider.Metrics()
        var cpuHistory: [Double] = []
        var memHistory: [Double] = []
        var diskReadHistory: [Double] = []
        var diskWriteHistory: [Double] = []
        var downloadHistory: [Double] = []
        var uploadHistory: [Double] = []

        func append(_ m: SystemPerformanceProvider.Metrics) {
            metrics = m

            cpuHistory.append(m.cpuUsage / 100.0)
            if cpuHistory.count > Self.maxHistory + 1 { cpuHistory.removeFirst() }

            memHistory.append(m.memoryPercent / 100.0)
            if memHistory.count > Self.maxHistory + 1 { memHistory.removeFirst() }

            diskReadHistory.append(m.diskReadBytesPerSec)
            if diskReadHistory.count > Self.maxHistory + 1 { diskReadHistory.removeFirst() }

            diskWriteHistory.append(m.diskWriteBytesPerSec)
            if diskWriteHistory.count > Self.maxHistory + 1 { diskWriteHistory.removeFirst() }

            downloadHistory.append(m.networkDownBytesPerSec)
            if downloadHistory.count > Self.maxHistory + 1 { downloadHistory.removeFirst() }

            uploadHistory.append(m.networkUpBytesPerSec)
            if uploadHistory.count > Self.maxHistory + 1 { uploadHistory.removeFirst() }
        }
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.system-performance",
        displayName: "System Performance",
        description: "CPU, Memory, Disk & Network bandwidth",
        iconSystemName: "gauge.with.dots.needle.33percent",
        minimumSize: .fourByThree,
        defaultSize: .sixByFour,
        maximumSize: .tenBySix,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(SystemPerformanceWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(SystemPerformanceSettingsView(instanceID: instanceID, configStore: configStore))
        }
    )
}

// MARK: - View

struct SystemPerformanceWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = SystemPerformanceWidget.Config()
    private let provider = SystemPerformanceProvider.shared
    private let history = SystemPerformanceWidget.SharedHistory.shared

    @State private var metrics = SystemPerformanceProvider.Metrics()
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var diskReadHistory: [Double] = []
    @State private var diskWriteHistory: [Double] = []
    @State private var downloadHistory: [Double] = []
    @State private var uploadHistory: [Double] = []

    /// Scroll phase drives horizontal translation of chart points (0 = no scroll,
    /// 1 = scrolled one step left). Animated with `.linear` to create smooth
    /// continuous scrolling instead of per-point Y interpolation.
    @State private var scrollPhase: CGFloat = 0

    private let pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 200

            if isCompact {
                compactLayout
            } else {
                fullLayout
            }
        }
        .onAppear {
            loadConfig()
            restoreFromSharedHistory()
            refreshMetrics()
        }
        .onReceive(pollTimer) { _ in refreshMetrics() }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID { loadConfig() }
        }
    }

    // MARK: - Full Layout (2+ rows)

    private var fullLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            if config.showCPU {
                MetricCard(
                    icon: "cpu",
                    label: "CPU",
                    value: String(format: "%.0f%%", metrics.cpuUsage),
                    percent: metrics.cpuUsage / 100.0,
                    history: cpuHistory,
                    color: cpuColor,
                    sparklineColor: .mint,
                    theme: theme,
                    scrollPhase: scrollPhase
                )
            }

            if config.showMemory {
                MetricCard(
                    icon: "memorychip",
                    label: "Memory",
                    value: String(format: "%.1f / %.0f GB  %.0f%%", metrics.memoryUsed, metrics.memoryTotal, metrics.memoryPercent),
                    percent: metrics.memoryPercent / 100.0,
                    history: memHistory,
                    color: memColor,
                    sparklineColor: .cyan,
                    theme: theme,
                    scrollPhase: scrollPhase
                )
            }

            if config.showDisk {
                DiskCard(
                    readHistory: diskReadHistory,
                    writeHistory: diskWriteHistory,
                    currentRead: metrics.diskReadBytesPerSec,
                    currentWrite: metrics.diskWriteBytesPerSec,
                    diskUsed: metrics.diskUsed,
                    diskTotal: metrics.diskTotal,
                    diskPercent: metrics.diskPercent / 100.0,
                    color: diskColor,
                    theme: theme,
                    scrollPhase: scrollPhase
                )
            }

            if config.showNetwork {
                NetworkCard(
                    downloadHistory: downloadHistory,
                    uploadHistory: uploadHistory,
                    currentDown: metrics.networkDownBytesPerSec,
                    currentUp: metrics.networkUpBytesPerSec,
                    theme: theme,
                    scrollPhase: scrollPhase
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Compact Layout (1 row)

    private var compactLayout: some View {
        HStack(spacing: 16) {
            if config.showCPU {
                CompactMetric(
                    icon: "cpu",
                    value: String(format: "%.0f%%", metrics.cpuUsage),
                    percent: metrics.cpuUsage / 100.0,
                    color: cpuColor,
                    theme: theme
                )
            }
            if config.showMemory {
                CompactMetric(
                    icon: "memorychip",
                    value: String(format: "%.0f%%", metrics.memoryPercent),
                    percent: metrics.memoryPercent / 100.0,
                    color: memColor,
                    theme: theme
                )
            }
            if config.showDisk {
                CompactMetric(
                    icon: "internaldrive",
                    value: String(format: "%.0f%%", metrics.diskPercent),
                    percent: metrics.diskPercent / 100.0,
                    color: diskColor,
                    theme: theme
                )
            }
            if config.showNetwork {
                VStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 18))
                        .foregroundColor(.cyan)
                    Text(formatRate(metrics.networkDownBytesPerSec))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.cyan)
                    Text(formatRate(metrics.networkUpBytesPerSec))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Colors

    private var cpuColor: Color {
        if metrics.cpuUsage > 80 { return .red }
        if metrics.cpuUsage > 50 { return .orange }
        return .green
    }

    private var memColor: Color {
        if metrics.memoryPercent > 85 { return .red }
        if metrics.memoryPercent > 60 { return .orange }
        return .blue
    }

    private var diskColor: Color {
        if metrics.diskPercent > 90 { return .red }
        if metrics.diskPercent > 75 { return .orange }
        return .purple
    }

    // MARK: - Helpers

    /// Restore metrics and history from the shared store on appear.
    /// This preserves data across page switches where the view is destroyed/recreated.
    private func restoreFromSharedHistory() {
        metrics = history.metrics
        cpuHistory = history.cpuHistory
        memHistory = history.memHistory
        diskReadHistory = history.diskReadHistory
        diskWriteHistory = history.diskWriteHistory
        downloadHistory = history.downloadHistory
        uploadHistory = history.uploadHistory

        // If the history is already full, set phase to 1 so we show the latest
        // window of data (the oldest extra point is already "scrolled off").
        if cpuHistory.count > SystemPerformanceWidget.SharedHistory.maxHistory {
            scrollPhase = 1.0
        }
    }

    private func refreshMetrics() {
        let p = provider
        let h = history
        Task.detached {
            let m = p.collect()
            await MainActor.run {
                metrics = m

                // Update shared history (survives page changes)
                h.append(m)

                // Atomically update data arrays and reset scroll phase (no animation).
                // At phase=0 with the new (shifted) data, the visible points are identical
                // to the previous frame at phase=1 with the old data — no visual glitch.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    cpuHistory = h.cpuHistory
                    memHistory = h.memHistory
                    diskReadHistory = h.diskReadHistory
                    diskWriteHistory = h.diskWriteHistory
                    downloadHistory = h.downloadHistory
                    uploadHistory = h.uploadHistory
                    scrollPhase = 0
                }

                // Animate the scroll over the poll interval. The phase drives horizontal
                // translation of all chart points, creating smooth continuous scrolling
                // instead of the per-point Y interpolation that caused "wiggling".
                if h.cpuHistory.count > SystemPerformanceWidget.SharedHistory.maxHistory {
                    DispatchQueue.main.async {
                        withAnimation(.linear(duration: 2.0)) {
                            scrollPhase = 1.0
                        }
                    }
                }
            }
        }
    }

    private func loadConfig() {
        if let saved: SystemPerformanceWidget.Config = configStore.read(instanceID: instanceID, as: SystemPerformanceWidget.Config.self) {
            config = saved
        }
    }
}

// MARK: - Vertical Bar Background
//
// Reusable full-height vertical bar (width = percentage) with a short sharp
// trailing fade. 85% solid, 15% fade-out.

private struct VerticalBarBackground: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * min(max(percent, 0), 1.0)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color.opacity(0.30))
                    .frame(width: max(barWidth * 0.85, 0))
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.30), color.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(barWidth * 0.15, 0))
                Spacer(minLength: 0)
            }
            .animation(.linear(duration: 2.0), value: percent)
        }
    }
}

// MARK: - Rate Label (arrow + rate, no text label, no background)

private struct RateLabel: View {
    let direction: String  // "arrow.up" or "arrow.down"
    let rate: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: direction)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            Text(rate)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

// MARK: - Metric Card (Full Layout)
//
// No header row. Sparkline fills the entire card. Icon+label top-left,
// value bottom-left — all overlaid on the graph. 2px margins.

private struct MetricCard: View {
    let icon: String
    let label: String
    let value: String
    let percent: Double
    let history: [Double]
    let color: Color
    let sparklineColor: Color
    let theme: LedgeTheme
    let scrollPhase: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Full-height vertical bar background
                VerticalBarBackground(percent: percent, color: color)

                // Sparkline fills entire card
                if !history.isEmpty {
                    SparklineView(data: history, color: sparklineColor, scrollPhase: scrollPhase)
                }
            }
            .overlay(alignment: .topLeading) {
                // Icon + label — top-left
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundColor(color)
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(2)
            }
            .overlay(alignment: .bottomLeading) {
                // Value — bottom-left
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .padding(2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Disk Card
//
// No header row. Bandwidth graph fills entire card. All labels overlaid.
// Icon+label top-left, ↑ Read top-right (cyan),
// usage bottom-left, ↓ Write bottom-right (orange). 2px margins.

private struct DiskCard: View {
    let readHistory: [Double]
    let writeHistory: [Double]
    let currentRead: Double
    let currentWrite: Double
    let diskUsed: Double
    let diskTotal: Double
    let diskPercent: Double
    let color: Color
    let theme: LedgeTheme
    let scrollPhase: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Full-height vertical bar background
                VerticalBarBackground(percent: diskPercent, color: color)

                // Bandwidth graph fills entire card
                BandwidthGraphView(
                    downloadHistory: readHistory,
                    uploadHistory: writeHistory,
                    isVertical: geo.size.height > geo.size.width,
                    theme: theme,
                    scrollPhase: scrollPhase
                )
            }
            .overlay(alignment: .topLeading) {
                // Icon + label — top-left
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 13))
                        .foregroundColor(color)
                    Text("Disk")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(2)
            }
            .overlay(alignment: .topTrailing) {
                // ↑ Read — top-right, arrow up, cyan
                RateLabel(direction: "arrow.up", rate: formatRate(currentRead), color: .cyan)
                    .padding(2)
            }
            .overlay(alignment: .bottomLeading) {
                // Usage info — bottom-left
                Text(String(format: "%.0f / %.0f GB  %.0f%%", diskUsed, diskTotal, diskPercent * 100))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .padding(2)
            }
            .overlay(alignment: .bottomTrailing) {
                // ↓ Write — bottom-right, arrow down, orange
                RateLabel(direction: "arrow.down", rate: formatRate(currentWrite), color: .orange)
                    .padding(2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Network Card
//
// No header row. Bandwidth graph fills entire card. All labels overlaid.
// Icon+label top-left, ↑ Send top-right (orange),
// ↓ Receive bottom-right (cyan). 2px margins.

private struct NetworkCard: View {
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    let currentDown: Double
    let currentUp: Double
    let theme: LedgeTheme
    let scrollPhase: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Bandwidth graph fills entire card
                BandwidthGraphView(
                    downloadHistory: downloadHistory,
                    uploadHistory: uploadHistory,
                    isVertical: geo.size.height > geo.size.width,
                    theme: theme,
                    scrollPhase: scrollPhase
                )
            }
            .overlay(alignment: .topLeading) {
                // Icon + label — top-left
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 13))
                        .foregroundColor(.cyan)
                    Text("Network")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(2)
            }
            .overlay(alignment: .topTrailing) {
                // ↑ Send (upload) — top-right, cyan to match graph top half
                RateLabel(direction: "arrow.up", rate: formatRate(currentUp), color: .cyan)
                    .padding(2)
            }
            .overlay(alignment: .bottomTrailing) {
                // ↓ Receive (download) — bottom-right, orange to match graph bottom half
                RateLabel(direction: "arrow.down", rate: formatRate(currentDown), color: .orange)
                    .padding(2)
            }
        }
    }
}

// MARK: - Bandwidth Graph (bidirectional, orientation-aware)

private struct BandwidthGraphView: View {
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    let isVertical: Bool
    let theme: LedgeTheme
    let scrollPhase: CGFloat

    private let downloadColor: Color = .cyan
    private let uploadColor: Color = .orange
    private let visibleCount = SystemPerformanceWidget.SharedHistory.maxHistory

    /// Pre-normalize both histories against their shared max.
    private var maxVal: Double {
        max(downloadHistory.max() ?? 0, uploadHistory.max() ?? 0, 1024)
    }

    private var normalizedDown: [Double] {
        downloadHistory.map { min($0 / maxVal, 1.0) }
    }

    private var normalizedUp: [Double] {
        uploadHistory.map { min($0 / maxVal, 1.0) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Download fill
                BandwidthFillShape(
                    data: normalizedDown,
                    scrollPhase: scrollPhase,
                    isAbove: true,
                    isVertical: isVertical,
                    visibleCount: visibleCount
                )
                .fill(downloadColor.opacity(0.3))

                // Download stroke
                BandwidthStrokeShape(
                    data: normalizedDown,
                    scrollPhase: scrollPhase,
                    isAbove: true,
                    isVertical: isVertical,
                    visibleCount: visibleCount
                )
                .stroke(downloadColor, lineWidth: 1.5)

                // Upload fill
                BandwidthFillShape(
                    data: normalizedUp,
                    scrollPhase: scrollPhase,
                    isAbove: false,
                    isVertical: isVertical,
                    visibleCount: visibleCount
                )
                .fill(uploadColor.opacity(0.3))

                // Upload stroke
                BandwidthStrokeShape(
                    data: normalizedUp,
                    scrollPhase: scrollPhase,
                    isAbove: false,
                    isVertical: isVertical,
                    visibleCount: visibleCount
                )
                .stroke(uploadColor, lineWidth: 1.5)

                // Center line
                if isVertical {
                    Path { path in
                        path.move(to: CGPoint(x: w / 2, y: 0))
                        path.addLine(to: CGPoint(x: w / 2, y: h))
                    }
                    .stroke(theme.primaryText.opacity(0.15), lineWidth: 0.5)
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h / 2))
                        path.addLine(to: CGPoint(x: w, y: h / 2))
                    }
                    .stroke(theme.primaryText.opacity(0.15), lineWidth: 0.5)
                }
            }
            .clipped()
        }
    }
}

/// Animatable fill shape for a bandwidth half (above or below center).
/// Scrolls horizontally (or vertically) via `scrollPhase` instead of
/// interpolating Y values, preventing the "wiggling" artifact.
private struct BandwidthFillShape: Shape {
    var data: [Double]
    var scrollPhase: CGFloat
    let isAbove: Bool
    let isVertical: Bool
    let visibleCount: Int

    var animatableData: CGFloat {
        get { scrollPhase }
        set { scrollPhase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard data.count > 1 else { return Path() }
        let count = data.count
        let isScrolling = count > visibleCount

        if isVertical {
            let mid = rect.width / 2
            let stepHeight: CGFloat
            if isScrolling {
                stepHeight = rect.height / CGFloat(visibleCount - 1)
            } else {
                stepHeight = rect.height / CGFloat(count - 1)
            }
            let yOffset = isScrolling ? scrollPhase * stepHeight : 0

            let points = data.enumerated().map { i, val in
                let y = CGFloat(i) * stepHeight - yOffset
                let x = isAbove
                    ? mid + (mid * min(max(CGFloat(val), 0), 1.0))
                    : mid - (mid * min(max(CGFloat(val), 0), 1.0))
                return CGPoint(x: x, y: y)
            }
            var path = Path()
            path.move(to: CGPoint(x: mid, y: points[0].y))
            appendCatmullRomCurve(to: &path, points: points, from: CGPoint(x: mid, y: points[0].y))
            path.addLine(to: CGPoint(x: mid, y: points[count - 1].y))
            path.closeSubpath()
            return path
        } else {
            let mid = rect.height / 2
            let stepWidth: CGFloat
            if isScrolling {
                stepWidth = rect.width / CGFloat(visibleCount - 1)
            } else {
                stepWidth = rect.width / CGFloat(count - 1)
            }
            let xOffset = isScrolling ? scrollPhase * stepWidth : 0

            let points = data.enumerated().map { i, val in
                let x = CGFloat(i) * stepWidth - xOffset
                let y = isAbove
                    ? mid - (mid * min(max(CGFloat(val), 0), 1.0))
                    : mid + (mid * min(max(CGFloat(val), 0), 1.0))
                return CGPoint(x: x, y: y)
            }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: mid))
            appendCatmullRomCurve(to: &path, points: points, from: CGPoint(x: points[0].x, y: mid))
            path.addLine(to: CGPoint(x: points[count - 1].x, y: mid))
            path.closeSubpath()
            return path
        }
    }
}

/// Animatable stroke shape for a bandwidth half (above or below center).
private struct BandwidthStrokeShape: Shape {
    var data: [Double]
    var scrollPhase: CGFloat
    let isAbove: Bool
    let isVertical: Bool
    let visibleCount: Int

    var animatableData: CGFloat {
        get { scrollPhase }
        set { scrollPhase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard data.count > 1 else { return Path() }
        let count = data.count
        let isScrolling = count > visibleCount

        if isVertical {
            let mid = rect.width / 2
            let stepHeight: CGFloat
            if isScrolling {
                stepHeight = rect.height / CGFloat(visibleCount - 1)
            } else {
                stepHeight = rect.height / CGFloat(count - 1)
            }
            let yOffset = isScrolling ? scrollPhase * stepHeight : 0

            let points = data.enumerated().map { i, val in
                let y = CGFloat(i) * stepHeight - yOffset
                let x = isAbove
                    ? mid + (mid * min(max(CGFloat(val), 0), 1.0))
                    : mid - (mid * min(max(CGFloat(val), 0), 1.0))
                return CGPoint(x: x, y: y)
            }
            return catmullRomPath(points: points)
        } else {
            let mid = rect.height / 2
            let stepWidth: CGFloat
            if isScrolling {
                stepWidth = rect.width / CGFloat(visibleCount - 1)
            } else {
                stepWidth = rect.width / CGFloat(count - 1)
            }
            let xOffset = isScrolling ? scrollPhase * stepWidth : 0

            let points = data.enumerated().map { i, val in
                let x = CGFloat(i) * stepWidth - xOffset
                let y = isAbove
                    ? mid - (mid * min(max(CGFloat(val), 0), 1.0))
                    : mid + (mid * min(max(CGFloat(val), 0), 1.0))
                return CGPoint(x: x, y: y)
            }
            return catmullRomPath(points: points)
        }
    }
}

// MARK: - Compact Metric (Single Row)

private struct CompactMetric: View {
    let icon: String
    let value: String
    let percent: Double
    let color: Color
    let theme: LedgeTheme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)

            // Circular progress
            ZStack {
                Circle()
                    .stroke(theme.primaryText.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(percent, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 2.0), value: percent)
            }
            .frame(width: 40, height: 40)
        }
    }
}

// MARK: - Sparkline Graph
//
// Brighter stroke (2pt) and slightly more opaque fill for better contrast
// when rendered on top of the tinted vertical bar.

private struct SparklineView: View {
    let data: [Double]
    let color: Color
    let scrollPhase: CGFloat

    private let visibleCount = SystemPerformanceWidget.SharedHistory.maxHistory

    var body: some View {
        ZStack {
            // Fill (rendered first, behind the line)
            SparklineFillShape(data: data, scrollPhase: scrollPhase, visibleCount: visibleCount)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Line (on top)
            SparklineStrokeShape(data: data, scrollPhase: scrollPhase, visibleCount: visibleCount)
                .stroke(color.opacity(0.9), lineWidth: 2)
        }
        .clipped()
    }
}

/// Animatable shape for the sparkline fill area.
/// Uses `scrollPhase` to translate horizontally rather than interpolating
/// per-point Y values, which eliminates the "wiggling worm" artifact.
private struct SparklineFillShape: Shape {
    var data: [Double]
    var scrollPhase: CGFloat
    let visibleCount: Int

    var animatableData: CGFloat {
        get { scrollPhase }
        set { scrollPhase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard data.count > 1 else { return Path() }

        let isScrolling = data.count > visibleCount
        let stepWidth: CGFloat
        if isScrolling {
            stepWidth = rect.width / CGFloat(visibleCount - 1)
        } else {
            stepWidth = rect.width / CGFloat(data.count - 1)
        }
        let xOffset = isScrolling ? scrollPhase * stepWidth : 0

        let points = data.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * stepWidth - xOffset,
                y: rect.height * (1 - min(max(CGFloat(value), 0), 1.0))
            )
        }

        var path = Path()
        path.move(to: CGPoint(x: points[0].x, y: rect.height))
        // Line up to the first data point, then trace the curve
        appendCatmullRomCurve(to: &path, points: points, from: CGPoint(x: points[0].x, y: rect.height))
        // Close back to bottom-right
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// Animatable shape for the sparkline stroke.
private struct SparklineStrokeShape: Shape {
    var data: [Double]
    var scrollPhase: CGFloat
    let visibleCount: Int

    var animatableData: CGFloat {
        get { scrollPhase }
        set { scrollPhase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard data.count > 1 else { return Path() }

        let isScrolling = data.count > visibleCount
        let stepWidth: CGFloat
        if isScrolling {
            stepWidth = rect.width / CGFloat(visibleCount - 1)
        } else {
            stepWidth = rect.width / CGFloat(data.count - 1)
        }
        let xOffset = isScrolling ? scrollPhase * stepWidth : 0

        let points = data.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * stepWidth - xOffset,
                y: rect.height * (1 - min(max(CGFloat(value), 0), 1.0))
            )
        }

        return catmullRomPath(points: points)
    }
}

// MARK: - Catmull-Rom Spline Helpers
//
// Converts an array of CGPoints into a smooth Path using centripetal
// Catmull-Rom → cubic Bezier conversion. Each segment between consecutive
// points gets smooth control points derived from their neighbors.
//
// Uses monotone clamping to prevent overshoot — control points are clamped
// so curves never exceed the Y range of their endpoints (no crossing the
// center line in bandwidth graphs, no going below 0 or above 1 in sparklines).

/// Build a standalone path starting at points[0] (for strokes).
private func catmullRomPath(points: [CGPoint]) -> Path {
    Path { path in
        guard points.count > 1 else { return }
        path.move(to: points[0])
        addCatmullRomSegments(to: &path, points: points)
    }
}

/// Append curve segments to an existing path (for fills).
/// Draws a line from `from` to points[0], then adds curve segments.
private func appendCatmullRomCurve(to path: inout Path, points: [CGPoint], from: CGPoint) {
    guard points.count > 1 else { return }
    path.addLine(to: points[0])
    addCatmullRomSegments(to: &path, points: points)
}

/// Core: add Catmull-Rom cubic Bezier segments to a path (path cursor must already be at points[0]).
private func addCatmullRomSegments(to path: inout Path, points: [CGPoint]) {
    if points.count == 2 {
        path.addLine(to: points[1])
        return
    }

    for i in 0..<(points.count - 1) {
        let p0 = points[max(i - 1, 0)]
        let p1 = points[i]
        let p2 = points[i + 1]
        let p3 = points[min(i + 2, points.count - 1)]

        // Tension factor — 6.0 gives gentle smoothing without excess overshoot
        let tension: CGFloat = 6.0
        var cp1 = CGPoint(
            x: p1.x + (p2.x - p0.x) / tension,
            y: p1.y + (p2.y - p0.y) / tension
        )
        var cp2 = CGPoint(
            x: p2.x - (p3.x - p1.x) / tension,
            y: p2.y - (p3.y - p1.y) / tension
        )

        // Monotone Y clamping — prevent control points from overshooting
        // the Y range of the segment endpoints. This stops curves from
        // crossing the center line or going negative.
        let minY = min(p1.y, p2.y)
        let maxY = max(p1.y, p2.y)
        cp1.y = min(max(cp1.y, minY), maxY)
        cp2.y = min(max(cp2.y, minY), maxY)

        path.addCurve(to: p2, control1: cp1, control2: cp2)
    }
}

private func formatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
    if bytesPerSec < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSec / 1024) }
    if bytesPerSec < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024)) }
    return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
}

// MARK: - Settings

struct SystemPerformanceSettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = SystemPerformanceWidget.Config()

    var body: some View {
        Form {
            Toggle("Show CPU", isOn: $config.showCPU)
            Toggle("Show Memory", isOn: $config.showMemory)
            Toggle("Show Disk", isOn: $config.showDisk)
            Toggle("Show Network", isOn: $config.showNetwork)
        }
        .onAppear { loadConfig() }
        .onChange(of: config) { _, _ in saveConfig() }
    }

    private func loadConfig() {
        if let saved: SystemPerformanceWidget.Config = configStore.read(instanceID: instanceID, as: SystemPerformanceWidget.Config.self) {
            config = saved
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }
}

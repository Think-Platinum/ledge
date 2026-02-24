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

        var metrics = SystemPerformanceProvider.Metrics()
        var cpuHistory: [Double] = []
        var memHistory: [Double] = []
        var diskReadHistory: [Double] = []
        var diskWriteHistory: [Double] = []
        var downloadHistory: [Double] = []
        var uploadHistory: [Double] = []

        let maxHistory = 60

        func append(_ m: SystemPerformanceProvider.Metrics) {
            metrics = m

            cpuHistory.append(m.cpuUsage / 100.0)
            if cpuHistory.count > maxHistory { cpuHistory.removeFirst() }

            memHistory.append(m.memoryPercent / 100.0)
            if memHistory.count > maxHistory { memHistory.removeFirst() }

            diskReadHistory.append(m.diskReadBytesPerSec)
            if diskReadHistory.count > maxHistory { diskReadHistory.removeFirst() }

            diskWriteHistory.append(m.diskWriteBytesPerSec)
            if diskWriteHistory.count > maxHistory { diskWriteHistory.removeFirst() }

            downloadHistory.append(m.networkDownBytesPerSec)
            if downloadHistory.count > maxHistory { downloadHistory.removeFirst() }

            uploadHistory.append(m.networkUpBytesPerSec)
            if uploadHistory.count > maxHistory { uploadHistory.removeFirst() }
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
                    theme: theme
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
                    theme: theme
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
                    theme: theme
                )
            }

            if config.showNetwork {
                NetworkCard(
                    downloadHistory: downloadHistory,
                    uploadHistory: uploadHistory,
                    currentDown: metrics.networkDownBytesPerSec,
                    currentUp: metrics.networkUpBytesPerSec,
                    theme: theme
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
    }

    private func refreshMetrics() {
        let p = provider
        Task.detached {
            let m = p.collect()
            await MainActor.run {
                metrics = m

                // Update shared history (survives page changes)
                history.append(m)

                // Sync local @State arrays for rendering
                cpuHistory = history.cpuHistory
                memHistory = history.memHistory
                diskReadHistory = history.diskReadHistory
                diskWriteHistory = history.diskWriteHistory
                downloadHistory = history.downloadHistory
                uploadHistory = history.uploadHistory
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
            .animation(.easeInOut(duration: 1.0), value: percent)
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Full-height vertical bar background
                VerticalBarBackground(percent: percent, color: color)

                // Sparkline fills entire card
                if !history.isEmpty {
                    SparklineView(data: history, color: sparklineColor)
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
                    theme: theme
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Bandwidth graph fills entire card
                BandwidthGraphView(
                    downloadHistory: downloadHistory,
                    uploadHistory: uploadHistory,
                    isVertical: geo.size.height > geo.size.width,
                    theme: theme
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

    private let downloadColor: Color = .cyan
    private let uploadColor: Color = .orange

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Canvas { context, size in
                let maxVal = max(
                    downloadHistory.max() ?? 0,
                    uploadHistory.max() ?? 0,
                    1024 // minimum 1 KB/s scale
                )
                let count = max(downloadHistory.count, uploadHistory.count)
                guard count > 1 else { return }

                if isVertical {
                    drawVertical(context: context, size: size, maxVal: maxVal, count: count)
                } else {
                    drawHorizontal(context: context, size: size, maxVal: maxVal, count: count)
                }
            }

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
    }

    // Horizontal: X=time, download above center, upload below center
    private func drawHorizontal(context: GraphicsContext, size: CGSize, maxVal: Double, count: Int) {
        let w = size.width
        let h = size.height
        let mid = h / 2

        // Download (above center line)
        if !downloadHistory.isEmpty {
            var downFill = Path()
            downFill.move(to: CGPoint(x: 0, y: mid))
            for (i, val) in downloadHistory.enumerated() {
                let x = w * Double(i) / Double(count - 1)
                let y = mid - (mid * min(val / maxVal, 1.0))
                downFill.addLine(to: CGPoint(x: x, y: y))
            }
            downFill.addLine(to: CGPoint(x: w * Double(downloadHistory.count - 1) / Double(count - 1), y: mid))
            downFill.closeSubpath()
            context.fill(downFill, with: .color(downloadColor.opacity(0.3)))

            var downLine = Path()
            for (i, val) in downloadHistory.enumerated() {
                let x = w * Double(i) / Double(count - 1)
                let y = mid - (mid * min(val / maxVal, 1.0))
                if i == 0 { downLine.move(to: CGPoint(x: x, y: y)) }
                else { downLine.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(downLine, with: .color(downloadColor), lineWidth: 1.5)
        }

        // Upload (below center line)
        if !uploadHistory.isEmpty {
            var upFill = Path()
            upFill.move(to: CGPoint(x: 0, y: mid))
            for (i, val) in uploadHistory.enumerated() {
                let x = w * Double(i) / Double(count - 1)
                let y = mid + (mid * min(val / maxVal, 1.0))
                upFill.addLine(to: CGPoint(x: x, y: y))
            }
            upFill.addLine(to: CGPoint(x: w * Double(uploadHistory.count - 1) / Double(count - 1), y: mid))
            upFill.closeSubpath()
            context.fill(upFill, with: .color(uploadColor.opacity(0.3)))

            var upLine = Path()
            for (i, val) in uploadHistory.enumerated() {
                let x = w * Double(i) / Double(count - 1)
                let y = mid + (mid * min(val / maxVal, 1.0))
                if i == 0 { upLine.move(to: CGPoint(x: x, y: y)) }
                else { upLine.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(upLine, with: .color(uploadColor), lineWidth: 1.5)
        }
    }

    // Vertical: Y=time (top to bottom), download right of center, upload left of center
    private func drawVertical(context: GraphicsContext, size: CGSize, maxVal: Double, count: Int) {
        let w = size.width
        let h = size.height
        let mid = w / 2

        // Download (right of center)
        if !downloadHistory.isEmpty {
            var downFill = Path()
            downFill.move(to: CGPoint(x: mid, y: 0))
            for (i, val) in downloadHistory.enumerated() {
                let y = h * Double(i) / Double(count - 1)
                let x = mid + (mid * min(val / maxVal, 1.0))
                downFill.addLine(to: CGPoint(x: x, y: y))
            }
            downFill.addLine(to: CGPoint(x: mid, y: h * Double(downloadHistory.count - 1) / Double(count - 1)))
            downFill.closeSubpath()
            context.fill(downFill, with: .color(downloadColor.opacity(0.3)))

            var downLine = Path()
            for (i, val) in downloadHistory.enumerated() {
                let y = h * Double(i) / Double(count - 1)
                let x = mid + (mid * min(val / maxVal, 1.0))
                if i == 0 { downLine.move(to: CGPoint(x: x, y: y)) }
                else { downLine.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(downLine, with: .color(downloadColor), lineWidth: 1.5)
        }

        // Upload (left of center)
        if !uploadHistory.isEmpty {
            var upFill = Path()
            upFill.move(to: CGPoint(x: mid, y: 0))
            for (i, val) in uploadHistory.enumerated() {
                let y = h * Double(i) / Double(count - 1)
                let x = mid - (mid * min(val / maxVal, 1.0))
                upFill.addLine(to: CGPoint(x: x, y: y))
            }
            upFill.addLine(to: CGPoint(x: mid, y: h * Double(uploadHistory.count - 1) / Double(count - 1)))
            upFill.closeSubpath()
            context.fill(upFill, with: .color(uploadColor.opacity(0.3)))

            var upLine = Path()
            for (i, val) in uploadHistory.enumerated() {
                let y = h * Double(i) / Double(count - 1)
                let x = mid - (mid * min(val / maxVal, 1.0))
                if i == 0 { upLine.move(to: CGPoint(x: x, y: y)) }
                else { upLine.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(upLine, with: .color(uploadColor), lineWidth: 1.5)
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

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            if data.count > 1 {
                // Fill (rendered first, behind the line)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, value) in data.enumerated() {
                        let x = width * Double(index) / Double(data.count - 1)
                        let y = height * (1 - min(value, 1.0))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Line (on top)
                Path { path in
                    for (index, value) in data.enumerated() {
                        let x = width * Double(index) / Double(data.count - 1)
                        let y = height * (1 - min(value, 1.0))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color.opacity(0.9), lineWidth: 2)
            }
        }
    }
}

// MARK: - Rate Formatting

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

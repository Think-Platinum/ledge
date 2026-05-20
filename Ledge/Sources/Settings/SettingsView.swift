import SwiftUI
import UniformTypeIdentifiers

/// Settings window displayed on the primary monitor.
///
/// This is where the user configures Ledge — display selection, layout editing,
/// widget management, etc. It's a standard SwiftUI window (not a non-activating panel)
/// because settings interaction needs full keyboard/mouse focus.
struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @EnvironmentObject var displayManager: DisplayManager
    let layoutManager: LayoutManager
    let configStore: WidgetConfigStore

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink(destination: DisplaySettingsView()) {
                    Label("Display", systemImage: "display")
                }
                NavigationLink(destination: WidgetsAndLayoutView(layoutManager: layoutManager, configStore: configStore)) {
                    Label("Widgets & Layout", systemImage: "square.grid.2x2")
                }
                NavigationLink(destination: AppearanceSettingsView()) {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink(destination: DeveloperSettingsView()) {
                    Label("Developer", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink(destination: AboutView()) {
                    Label("About", systemImage: "info.circle")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Ledge")
        } detail: {
            DisplaySettingsView()
        }
        .environment(\.theme, themeManager.resolvedTheme)
    }
}

// MARK: - Display Settings

struct DisplaySettingsView: View {
    @EnvironmentObject var displayManager: DisplayManager

    /// True when macOS shows a menu bar on every display (the default).


    var body: some View {
        Form {
            Section("Xeneon Edge") {
                HStack {
                    Image(systemName: displayManager.isActive ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(displayManager.isActive ? .green : .red)
                    Text(displayManager.statusMessage)
                }

                if !displayManager.isActive, displayManager.xeneonScreen != nil {
                    Button("Show Panel") {
                        displayManager.showPanel()
                    }
                } else if displayManager.isActive {
                    Button("Hide Panel") {
                        displayManager.hidePanel()
                    }
                }

                Button("Re-scan Displays") {
                    displayManager.detectXenonEdge()
                }
            }

            Section("Touch Remapping") {
                LabeledContent("Accessibility") {
                    HStack {
                        Image(systemName: displayManager.accessibilityPermission == .granted
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(displayManager.accessibilityPermission == .granted ? .green : .orange)
                        Text(displayManager.accessibilityPermission.rawValue)
                    }
                }

                LabeledContent("Event Tap") {
                    HStack {
                        Image(systemName: displayManager.isTouchRemapperActive ? "hand.tap.fill" : "hand.tap")
                            .foregroundColor(displayManager.isTouchRemapperActive ? .green : .secondary)
                        Text(displayManager.isTouchRemapperActive ? "Active" : "Inactive")
                    }
                }

                LabeledContent("Calibration") {
                    HStack {
                        Image(systemName: (displayManager.calibrationState == .calibrated
                              || displayManager.calibrationState == .autoDetected)
                              ? "target" : "questionmark.circle")
                            .foregroundColor((displayManager.calibrationState == .calibrated
                              || displayManager.calibrationState == .autoDetected) ? .green : .secondary)
                        Text(displayManager.calibrationState.rawValue)
                    }
                }

                if let deviceID = displayManager.learnedDeviceID {
                    LabeledContent("Device ID") {
                        Text("\(deviceID)")
                            .font(.caption.monospaced())
                    }
                }

                if displayManager.deviceIDChangeCount > 0 {
                    LabeledContent("ID changes since launch") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(displayManager.deviceIDChangeCount)")
                                .font(.caption.monospaced())
                            if let at = displayManager.lastDeviceIDChangeAt,
                               let why = displayManager.lastDeviceIDChangeReason {
                                Text("last: \(why) — \(at.formatted(date: .omitted, time: .standard))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .help("How often the Xeneon Edge has been issued new IOKit registry IDs since launch — usually one per sleep/wake. Auto-recovered without user intervention.")
                }

                Text("macOS maps the Xeneon Edge touchscreen to the primary display. The touch remapper auto-detects the touchscreen via USB and redirects input to the correct screen.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !displayManager.isTouchRemapperActive {
                    Button("Enable Touch Remapping") {
                        displayManager.startTouchRemapper()
                    }
                    .disabled(displayManager.xeneonScreen == nil)
                } else {
                    if displayManager.calibrationState == .notStarted {
                        Button("Calibrate Touch (Manual)") {
                            displayManager.calibrateTouch()
                        }
                        .help("Touch the Xeneon Edge screen to identify the touchscreen device")
                    } else {
                        Button("Re-detect Device") {
                            displayManager.refreshTouchDeviceIDs(reason: "user")
                        }
                        .help("Re-run IOKit HID detection and update the touch device ID filter — without tearing down the event tap. The app does this automatically on wake and on display changes; this button is for manual override.")
                    }

                    Button("Disable Touch Remapping") {
                        displayManager.stopTouchRemapper()
                    }
                }

                Divider()

                Toggle("Block mouse on Edge display", isOn: $displayManager.isMouseGuardEnabled)
                    .disabled(!displayManager.isTouchRemapperActive || displayManager.touchRemapper.touchDeviceIDs.isEmpty)
                    .help("Prevents non-touchscreen mouse events from interacting with widgets on the Edge display")

                if displayManager.isMouseGuardEnabled && displayManager.mouseGuard.isActive {
                    LabeledContent("Mouse Guard") {
                        HStack {
                            Image(systemName: "shield.checkered")
                                .foregroundColor(.green)
                            Text("Active")
                        }
                    }
                }

                Toggle("Show touch indicator", isOn: $displayManager.showTouchIndicator)
                    .help("Shows a visual ripple at touch points on the Edge display")
            }

            Section("Connected Displays") {
                ForEach(Array(displayManager.allScreensInfo.enumerated()), id: \.offset) { index, info in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(info.name)
                                .font(.headline)
                            Text(info.resolution)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if info.isXenonEdge {
                            Text("Xeneon Edge")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Display")
    }
}

// MARK: - Widgets & Layout (Consolidated)

/// Unified view for managing widgets, layout, and pages.
/// Top: page selector and grid editor. Bottom: widget list with config, add/remove.
struct WidgetsAndLayoutView: View {
    let layoutManager: LayoutManager
    let configStore: WidgetConfigStore
    let registry = WidgetRegistry.shared

    @Environment(ThemeManager.self) private var themeManager

    @State private var selectedWidgetID: UUID?
    @State private var showAddWidget = false
    @State private var renamingPageID: UUID?
    @State private var renameText = ""
    @State private var showingPageImagePicker = false
    @State private var imagePickerPageID: UUID?
    @State private var showPositionSize = false

    var body: some View {
        VStack(spacing: 0) {
            // Page selector bar
            pageSelector
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Grid editor for active page
            InteractiveGridEditor(
                layoutManager: layoutManager,
                selectedWidgetID: $selectedWidgetID
            )
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .padding(.horizontal, 16)

            Divider()
                .padding(.top, 8)

            // Widget list and config
            ScrollView {
                VStack(spacing: 0) {
                    if let selectedID = selectedWidgetID,
                       let placement = layoutManager.activeLayout.placements.first(where: { $0.id == selectedID }) {
                        selectedWidgetDetail(placement)
                    } else {
                        widgetList
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Widgets & Layout")
        .sheet(isPresented: $showAddWidget) {
            AddWidgetSheet(layoutManager: layoutManager, configStore: configStore)
        }
        .fileImporter(
            isPresented: $showingPageImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                if let pageID = imagePickerPageID {
                    setPageBackground(pageID: pageID, path: url.path)
                }
            }
        }
    }

    // MARK: - Page Selector

    private var pageSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pages")
                    .font(.headline)
                Spacer()

                // Auto-rotation indicator
                if layoutManager.autoRotateEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                            .font(.system(size: 10))
                        Text("\(Int(layoutManager.autoRotateInterval))s")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(Capsule())
                }

                // Auto-rotation toggle
                Toggle("Auto-rotate", isOn: Binding(
                    get: { layoutManager.autoRotateEnabled },
                    set: { layoutManager.autoRotateEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

                Button {
                    let newPage = layoutManager.createLayout(name: "Page \(layoutManager.pageCount + 1)")
                    layoutManager.switchLayout(to: newPage)
                    selectedWidgetID = nil
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a new empty page")
            }

            // Page tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(layoutManager.savedLayouts.enumerated()), id: \.element.id) { index, layout in
                        let isActive = layout.id == layoutManager.activeLayout.id

                        Button {
                            layoutManager.switchLayout(to: layout)
                            selectedWidgetID = nil
                        } label: {
                            HStack(spacing: 6) {
                                if renamingPageID == layout.id {
                                    TextField("Name", text: $renameText)
                                        .textFieldStyle(.plain)
                                        .frame(width: 80)
                                        .onSubmit {
                                            layoutManager.renameLayout(id: layout.id, to: renameText)
                                            renamingPageID = nil
                                        }
                                } else {
                                    Text(layout.name)
                                        .lineLimit(1)
                                }
                                Text("(\(layout.placements.count))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isActive ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename") {
                                renameText = layout.name
                                renamingPageID = layout.id
                            }
                            Button("Duplicate Page") {
                                let newPage = layoutManager.duplicateLayout(
                                    layout,
                                    name: "\(layout.name) Copy"
                                )
                                layoutManager.switchLayout(to: newPage)
                                selectedWidgetID = nil
                            }
                            Divider()
                            Button("Set Background Image…") {
                                imagePickerPageID = layout.id
                                showingPageImagePicker = true
                            }
                            if layout.backgroundImagePath != nil {
                                Button("Remove Background") {
                                    setPageBackground(pageID: layout.id, path: nil)
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                layoutManager.deleteLayout(id: layout.id)
                            }
                            .disabled(isActive && layoutManager.pageCount <= 1)
                        }
                    }
                }
            }

            // Page background — visible inline control for the active page
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let bgPath = layoutManager.activeLayout.backgroundImagePath, !bgPath.isEmpty {
                    Text(URL(fileURLWithPath: bgPath).lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Remove") {
                        setPageBackground(pageID: layoutManager.activeLayout.id, path: nil)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                } else {
                    Text("No page background")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }

                Button("Set Background…") {
                    imagePickerPageID = layoutManager.activeLayout.id
                    showingPageImagePicker = true
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Widget List

    private var widgetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Widgets on \(layoutManager.activeLayout.name)")
                    .font(.headline)
                Spacer()
                Button {
                    showAddWidget = true
                } label: {
                    Label("Add Widget", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if layoutManager.activeLayout.placements.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No widgets on this page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Click \"Add Widget\" or tap a cell in the grid above.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                Text("Click a widget in the grid or list to select it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(layoutManager.activeLayout.placements) { placement in
                    let descriptor = registry.registeredTypes[placement.widgetTypeID]
                    Button {
                        selectedWidgetID = placement.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: descriptor?.iconSystemName ?? "questionmark.square")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(descriptor?.displayName ?? placement.widgetTypeID)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(placement.columnSpan)×\(placement.rowSpan) at (\(placement.column), \(placement.row))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color(.controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Page info
            Divider()
                .padding(.vertical, 4)

            HStack {
                Text("Grid: \(layoutManager.activeLayout.columns)×\(layoutManager.activeLayout.rows)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Page \(layoutManager.activePageIndex + 1) of \(layoutManager.pageCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Selected Widget Detail

    @ViewBuilder
    private func selectedWidgetDetail(_ placement: WidgetPlacement) -> some View {
        let descriptor = registry.registeredTypes[placement.widgetTypeID]
        let grid = layoutManager.activeLayout

        VStack(alignment: .leading, spacing: 12) {
            // Header with back button
            HStack {
                Button {
                    selectedWidgetID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                        Text("Back")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text(descriptor?.displayName ?? placement.widgetTypeID)
                    .font(.headline)

                Spacer()

                Button(role: .destructive) {
                    layoutManager.removeWidget(id: placement.id)
                    selectedWidgetID = nil
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Position & Size (collapsed by default — mainly for fine-tuning)
            DisclosureGroup("Position & Size", isExpanded: $showPositionSize) {
                let colBinding = Binding<Int>(
                    get: { placement.column },
                    set: { var p = placement; p.column = $0; layoutManager.updateWidget(p) }
                )
                let rowBinding = Binding<Int>(
                    get: { placement.row },
                    set: { var p = placement; p.row = $0; layoutManager.updateWidget(p) }
                )
                let colSpanBinding = Binding<Int>(
                    get: { placement.columnSpan },
                    set: { var p = placement; p.columnSpan = $0; layoutManager.updateWidget(p) }
                )
                let rowSpanBinding = Binding<Int>(
                    get: { placement.rowSpan },
                    set: { var p = placement; p.rowSpan = $0; layoutManager.updateWidget(p) }
                )
                VStack(spacing: 8) {
                    HStack {
                        Text("Column")
                        Spacer()
                        Stepper("\(placement.column)", value: colBinding,
                                in: 0...(grid.columns - placement.columnSpan))
                    }
                    HStack {
                        Text("Row")
                        Spacer()
                        Stepper("\(placement.row)", value: rowBinding,
                                in: 0...(grid.rows - placement.rowSpan))
                    }
                    Divider()
                    HStack {
                        Text("Width")
                        Spacer()
                        Stepper("\(placement.columnSpan) cols", value: colSpanBinding,
                                in: 1...(grid.columns - placement.column))
                    }
                    HStack {
                        Text("Height")
                        Spacer()
                        Stepper("\(placement.rowSpan) rows", value: rowSpanBinding,
                                in: 1...(grid.rows - placement.row))
                    }
                }
                .font(.system(size: 13))
                .padding(.top, 4)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(8)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Widget-specific settings
            if let settingsView = registry.createSettingsView(
                typeID: placement.widgetTypeID,
                instanceID: placement.id,
                configStore: configStore
            ) {
                GroupBox("Widget Settings") {
                    settingsView
                        .padding(8)
                }
            }
        }
    }

    // MARK: - Helpers

    private func setPageBackground(pageID: UUID, path: String?) {
        if let index = layoutManager.savedLayouts.firstIndex(where: { $0.id == pageID }) {
            layoutManager.savedLayouts[index].backgroundImagePath = path
            if layoutManager.activeLayout.id == pageID {
                layoutManager.activeLayout.backgroundImagePath = path
            }
            layoutManager.save()
        }
    }
}

// MARK: - Add Widget Sheet (Visual Gallery)

struct AddWidgetSheet: View {
    let layoutManager: LayoutManager
    let configStore: WidgetConfigStore
    let registry = WidgetRegistry.shared

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCategory: WidgetCategory? = nil
    @State private var hoveredWidget: String? = nil

    /// Widget categories for filtering
    enum WidgetCategory: String, CaseIterable {
        case media = "Media"
        case productivity = "Productivity"
        case system = "System"
        case smart = "Smart Home"
        case info = "Info"
        case web = "Web"
    }

    /// Map widget type IDs to categories
    private static let categoryMap: [String: WidgetCategory] = [
        "com.ledge.spotify": .media,
        "com.ledge.system-audio": .media,
        "com.ledge.google-meet": .media,
        "com.ledge.calendar": .productivity,
        "com.ledge.clock": .info,
        "com.ledge.datetime": .info,
        "com.ledge.weather": .info,
        "com.ledge.system-performance": .system,
        "com.ledge.homeassistant": .smart,
        "com.ledge.web": .web,
    ]

    /// Category color for each widget type
    private static let categoryColors: [WidgetCategory: Color] = [
        .media: .green,
        .productivity: .blue,
        .system: .orange,
        .smart: .purple,
        .info: .cyan,
        .web: .indigo,
    ]

    private var filteredWidgets: [WidgetDescriptor] {
        var widgets = registry.allTypes
        if let category = selectedCategory {
            widgets = widgets.filter { Self.categoryMap[$0.typeID] == category }
        }
        if !searchText.isEmpty {
            widgets = widgets.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
        return widgets
    }

    /// Categories that actually have widgets in them
    private var activeCategories: [WidgetCategory] {
        WidgetCategory.allCases.filter { category in
            registry.allTypes.contains { Self.categoryMap[$0.typeID] == category }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Widget Gallery")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Search + category filters
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search widgets...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Category pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryPill(label: "All", category: nil)
                        ForEach(activeCategories, id: \.self) { category in
                            categoryPill(label: category.rawValue, category: category)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Widget grid
            if filteredWidgets.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No widgets match your search")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12),
                        ],
                        spacing: 12
                    ) {
                        ForEach(filteredWidgets, id: \.typeID) { descriptor in
                            widgetCard(descriptor)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 520, height: 560)
        .background(.background)
    }

    // MARK: - Category Pill

    private func categoryPill(label: String, category: WidgetCategory?) -> some View {
        let isSelected = (category == selectedCategory) || (category == nil && selectedCategory == nil)
        let pillColor = category.flatMap { Self.categoryColors[$0] } ?? .primary

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? pillColor.opacity(0.2) : Color.clear)
                .foregroundStyle(isSelected ? pillColor : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? pillColor.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Widget Card

    private func widgetCard(_ descriptor: WidgetDescriptor) -> some View {
        let category = Self.categoryMap[descriptor.typeID] ?? .info
        let accentColor = Self.categoryColors[category] ?? .accentColor
        let isHovered = hoveredWidget == descriptor.typeID
        let isAlreadyAdded = layoutManager.activeLayout.placements.contains {
            $0.widgetTypeID == descriptor.typeID
        }

        return Button {
            addWidget(descriptor)
            dismiss()
        } label: {
            HStack(spacing: 0) {
                // Left side: widget preview thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.windowBackgroundColor).opacity(0.6))

                    // Render the actual widget scaled down as a preview
                    descriptor.viewFactory(UUID(), configStore)
                        .frame(width: 320, height: 200)
                        .scaleEffect(0.35, anchor: .center)
                        .frame(width: 112, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .allowsHitTesting(false)
                }
                .frame(width: 112, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
                .padding(.trailing, 12)

                // Right side: info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center) {
                        // Icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(accentColor.opacity(0.15))
                                .frame(width: 24, height: 24)
                            Image(systemName: descriptor.iconSystemName)
                                .font(.system(size: 12))
                                .foregroundStyle(accentColor)
                        }

                        Text(descriptor.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer()

                        Text("\(descriptor.defaultSize.columns)×\(descriptor.defaultSize.rows)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }

                    Text(descriptor.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    HStack {
                        Text(category.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.8))

                        Spacer()

                        if isAlreadyAdded {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                Text("Added")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 110)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? accentColor.opacity(0.06) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? accentColor.opacity(0.3) : Color.secondary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredWidget = hovering ? descriptor.typeID : nil
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Actions

    private func addWidget(_ descriptor: WidgetDescriptor) {
        let placement = WidgetPlacement(
            id: UUID(),
            widgetTypeID: descriptor.typeID,
            column: 0,
            row: 0,
            columnSpan: descriptor.defaultSize.columns,
            rowSpan: descriptor.defaultSize.rows,
            configuration: descriptor.defaultConfiguration
        )
        layoutManager.addWidget(placement)
    }
}

// (LayoutEditorView has been consolidated into WidgetsAndLayoutView above)

// MARK: - Interactive Grid Editor

struct InteractiveGridEditor: View {
    let layoutManager: LayoutManager
    @Binding var selectedWidgetID: UUID?

    /// During a move drag, tracks the raw pixel offset from the widget's original position.
    /// The widget renders at its stored grid position PLUS this offset, giving smooth mouse-tracking.
    /// On release, the offset is snapped to the nearest grid cell and committed to the model.
    @State private var dragOffset: CGSize = .zero
    @State private var draggingWidgetID: UUID?

    /// During a resize drag, tracks the raw pixel delta from the widget's original size.
    /// The widget renders its stored span PLUS this delta in pixels, giving smooth mouse-tracking.
    /// On release, the delta is snapped to the nearest cell-aligned span and committed to the model.
    @State private var resizeDelta: CGSize = .zero
    @State private var resizingWidgetID: UUID?

    private let widgetColors: [Color] = [
        .blue, .purple, .green, .orange, .pink, .cyan, .indigo, .teal, .mint, .yellow
    ]

    var body: some View {
        GeometryReader { geometry in
            let layout = layoutManager.activeLayout
            let gap: CGFloat = 3
            let cellW = (geometry.size.width - CGFloat(layout.columns - 1) * gap) / CGFloat(layout.columns)
            let cellH = (geometry.size.height - CGFloat(layout.rows - 1) * gap) / CGFloat(layout.rows)

            ZStack(alignment: .topLeading) {
                // Grid background cells
                ForEach(0..<layout.columns, id: \.self) { col in
                    ForEach(0..<layout.rows, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: cellW, height: cellH)
                            .offset(
                                x: CGFloat(col) * (cellW + gap),
                                y: CGFloat(row) * (cellH + gap)
                            )
                    }
                }

                // Widget placements
                ForEach(Array(layout.placements.enumerated()), id: \.element.id) { index, placement in
                    let isSelected = placement.id == selectedWidgetID
                    let isDragging = placement.id == draggingWidgetID
                    let isResizing = placement.id == resizingWidgetID
                    let isActive = isDragging || isResizing
                    let descriptor = WidgetRegistry.shared.registeredTypes[placement.widgetTypeID]
                    let color = widgetColors[index % widgetColors.count]

                    // Always use the stored (cell-based) placement for base position/size.
                    // During a drag/resize, add the raw pixel offset so the widget tracks the
                    // mouse smoothly. Snap-to-grid only happens on release (onEnded).
                    let colSpanF = CGFloat(placement.columnSpan)
                    let rowSpanF = CGFloat(placement.rowSpan)
                    let colF = CGFloat(placement.column)
                    let rowF = CGFloat(placement.row)
                    let baseW: CGFloat = colSpanF * cellW + (colSpanF - 1) * gap
                    let baseH: CGFloat = rowSpanF * cellH + (rowSpanF - 1) * gap
                    let baseX: CGFloat = colF * (cellW + gap)
                    let baseY: CGFloat = rowF * (cellH + gap)

                    let w: CGFloat = isResizing ? max(cellW, baseW + resizeDelta.width) : baseW
                    let h: CGFloat = isResizing ? max(cellH, baseH + resizeDelta.height) : baseH
                    let x: CGFloat = isDragging ? baseX + dragOffset.width : baseX
                    let y: CGFloat = isDragging ? baseY + dragOffset.height : baseY

                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color.opacity(isSelected ? 0.5 : 0.3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(isSelected ? color : color.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                            )

                        VStack(spacing: 2) {
                            Image(systemName: descriptor?.iconSystemName ?? "questionmark.square")
                                .font(.system(size: 14))
                            Text(descriptor?.displayName ?? "?")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(isSelected ? .white : .primary)

                        // Resize handle — only the 18x18 corner icon is interactive.
                        // The gesture sits on the Image itself (not the surrounding VStack)
                        // so the body-drag stays usable when the user clicks anywhere except
                        // the handle. Both this gesture and the body's drag use
                        // .highPriorityGesture; SwiftUI's child-wins-over-parent rule for
                        // same-priority gestures means the handle wins when the click lands
                        // inside its 18x18 hit area.
                        if isSelected {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Image(systemName: "arrow.down.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                        .frame(width: 18, height: 18)
                                        .background(color.opacity(0.8))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .contentShape(Rectangle())
                                        .highPriorityGesture(
                                            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                                                .onChanged { value in
                                                    if resizingWidgetID != placement.id {
                                                        var t = Transaction()
                                                        t.disablesAnimations = true
                                                        withTransaction(t) {
                                                            resizingWidgetID = placement.id
                                                            resizeDelta = value.translation
                                                        }
                                                    } else {
                                                        resizeDelta = value.translation
                                                    }
                                                }
                                                .onEnded { value in
                                                    let cellStep: CGFloat = cellW + gap
                                                    let cellStepH: CGFloat = cellH + gap
                                                    let deltaColF: CGFloat = value.translation.width / cellStep
                                                    let deltaRowF: CGFloat = value.translation.height / cellStepH
                                                    let rawCols: CGFloat = CGFloat(placement.columnSpan) + deltaColF
                                                    let rawRows: CGFloat = CGFloat(placement.rowSpan) + deltaRowF
                                                    let maxCols: Int = layout.columns - placement.column
                                                    let maxRows: Int = layout.rows - placement.row
                                                    let newCols: Int = max(1, min(maxCols, Int(rawCols.rounded())))
                                                    let newRows: Int = max(1, min(maxRows, Int(rawRows.rounded())))
                                                    var p = placement
                                                    p.columnSpan = newCols
                                                    p.rowSpan = newRows
                                                    layoutManager.updateWidget(p)
                                                    resizingWidgetID = nil
                                                    resizeDelta = .zero
                                                }
                                        )
                                }
                            }
                            .padding(2)
                            .allowsHitTesting(true)
                        }
                    }
                    .frame(width: w, height: h)
                    .offset(x: x, y: y)
                    // Suppress all animation during active drag/resize: use Transaction
                    // to hard-cut every frame. The animation modifiers below only apply
                    // when the gesture is idle, giving the snap-to-grid landing spring.
                    // NOTE: .animation(_:value:) evaluates the condition at *render time*,
                    // so it can lag one frame on gesture start. The withTransaction call
                    // in onChanged prevents that first animated frame for both w/h and x/y.
                    .transaction { t in
                        if isActive { t.animation = nil }
                    }
                    .animation(.easeOut(duration: 0.15), value: x)
                    .animation(.easeOut(duration: 0.15), value: y)
                    .animation(.easeOut(duration: 0.15), value: w)
                    .animation(.easeOut(duration: 0.15), value: h)
                    .zIndex(isDragging || isSelected ? 10 : 0)
                    .opacity(isDragging ? 0.8 : 1.0)
                    // Use .simultaneousGesture for the tap so it does NOT delay the
                    // drag recogniser. With plain .onTapGesture followed by .gesture,
                    // SwiftUI on macOS makes the drag wait for the tap deadline (~0.3s)
                    // before recognising — the mouse has already moved during that wait,
                    // so the first onChanged fires with a large accumulated translation
                    // that causes a visible jump.
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selectedWidgetID = placement.id
                        }
                    )
                    // highPriorityGesture: drag wins over the tap gesture so it starts
                    // tracking immediately without waiting for tap disambiguation.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { value in
                                // DIAGNOSTIC — remove once confirmed working:
                                // print("BODY onChanged: translation=\(value.translation), resizingID=\(String(describing: resizingWidgetID))")

                                // Ignore body-drag events when a resize is in progress
                                // (the resize handle sits inside the widget frame).
                                guard resizingWidgetID == nil else { return }
                                if draggingWidgetID != placement.id {
                                    // First event: atomically set ID + offset with animation
                                    // disabled so there is no single eased frame at start.
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) {
                                        draggingWidgetID = placement.id
                                        selectedWidgetID = placement.id
                                        dragOffset = value.translation
                                    }
                                } else {
                                    dragOffset = value.translation
                                }
                            }
                            .onEnded { value in
                                // DIAGNOSTIC — remove once confirmed working:
                                // print("BODY onEnded: translation=\(value.translation)")

                                guard resizingWidgetID == nil else { return }
                                // Snap on release: find the nearest grid cell for the widget origin.
                                let cellStep: CGFloat = cellW + gap
                                let cellStepH: CGFloat = cellH + gap
                                let deltaColF: CGFloat = value.translation.width / cellStep
                                let deltaRowF: CGFloat = value.translation.height / cellStepH
                                let rawCol: CGFloat = CGFloat(placement.column) + deltaColF
                                let rawRow: CGFloat = CGFloat(placement.row) + deltaRowF
                                let maxCol: Int = layout.columns - placement.columnSpan
                                let maxRow: Int = layout.rows - placement.rowSpan
                                let newCol: Int = max(0, min(maxCol, Int(rawCol.rounded())))
                                let newRow: Int = max(0, min(maxRow, Int(rawRow.rounded())))
                                var p = placement
                                p.column = newCol
                                p.row = newRow
                                layoutManager.updateWidget(p)
                                draggingWidgetID = nil
                                dragOffset = .zero
                            }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// (PagesSettingsView has been consolidated into WidgetsAndLayoutView above)

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var showingImagePicker = false

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Mode", selection: Binding(
                    get: { themeManager.mode },
                    set: { themeManager.mode = $0 }
                )) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                if themeManager.mode == .auto {
                    Text("Auto follows the system appearance — Liquid Glass in dark mode, Light in light mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if themeManager.mode == .liquidGlass {
                    Text("Liquid Glass uses frosted blur backgrounds with specular highlights for a glass-morphism look. Works best with a background image.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Hide Widget Background when the active theme forces its own style
            // (e.g. Liquid Glass always uses blur)
            if themeManager.resolvedTheme.preferredBackgroundStyle == nil {
                Section("Widget Background") {
                    Picker("Style", selection: Binding(
                        get: { themeManager.widgetBackgroundStyle },
                        set: { themeManager.widgetBackgroundStyle = $0 }
                    )) {
                        ForEach(WidgetBackgroundStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    switch themeManager.widgetBackgroundStyle {
                    case .solid:
                        Text("Widgets have a solid background from the active theme.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .blur:
                        Text("Widgets blur the content behind them, creating a frosted glass effect. Works best with a background image.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .transparent:
                        Text("Widgets have no background — content floats directly over the dashboard background.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Dashboard Background") {
                Picker("Background", selection: Binding(
                    get: { themeManager.dashboardBackgroundMode },
                    set: { themeManager.dashboardBackgroundMode = $0 }
                )) {
                    ForEach(DashboardBackgroundMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                if themeManager.dashboardBackgroundMode == .image {
                    HStack {
                        if !themeManager.backgroundImagePath.isEmpty {
                            Text(URL(fileURLWithPath: themeManager.backgroundImagePath).lastPathComponent)
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No image selected")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Choose Image...") {
                            chooseBackgroundImage()
                        }
                    }

                    if let image = themeManager.backgroundImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Text("For best results, use a 2560×720 image. Corsair iCUE includes excellent wallpapers for the Xeneon Edge.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Visual Effects") {
                Picker("Effect", selection: Binding(
                    get: { themeManager.visualEffect },
                    set: { themeManager.visualEffect = $0 }
                )) {
                    ForEach(VisualEffectMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if themeManager.visualEffect != .off {
                    Picker("Interval", selection: Binding(
                        get: { themeManager.visualEffectInterval },
                        set: { themeManager.visualEffectInterval = $0 }
                    )) {
                        Text("30 seconds").tag(30.0 as TimeInterval)
                        Text("1 minute").tag(60.0 as TimeInterval)
                        Text("2 minutes").tag(120.0 as TimeInterval)
                        Text("5 minutes").tag(300.0 as TimeInterval)
                    }

                    Text(themeManager.visualEffect.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Preview Effect") {
                        NotificationCenter.default.post(name: .ledgePreviewVisualEffect, object: nil)
                    }
                }
            }

            Section("Preview") {
                ThemePreviewCard(theme: themeManager.resolvedTheme)
                    .frame(height: 120)
            }

            Section("All Themes") {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        let isActive = themeManager.mode == mode
                        VStack(spacing: 6) {
                            ThemePreviewCard(theme: mode == .auto
                                ? (themeManager.systemIsDark ? .liquidGlass : .light)
                                : mode.theme
                            )
                            .frame(height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
                            )

                            Text(mode.rawValue)
                                .font(.caption)
                                .foregroundColor(isActive ? .accentColor : .secondary)
                        }
                        .onTapGesture {
                            themeManager.mode = mode
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image for the Xeneon Edge dashboard"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            themeManager.backgroundImagePath = url.path
        }
    }
}

// MARK: - Theme Preview Card

struct ThemePreviewCard: View {
    let theme: LedgeTheme

    var body: some View {
        ZStack {
            theme.dashboardBackground

            HStack(spacing: 6) {
                mockWidget {
                    VStack(spacing: 4) {
                        Text("10:54")
                            .font(.system(size: 14, weight: .light, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("Thursday")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                mockWidget {
                    VStack(spacing: 4) {
                        Image(systemName: "cloud.sun.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.primaryText)
                            .symbolRenderingMode(.hierarchical)
                        Text("-1°C")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                mockWidget {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meeting")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text("10:30 - 11:00")
                            .font(.system(size: 7))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Renders a mock widget tile with the theme's chrome — border, optional glass highlight, shadow.
    private func mockWidget<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let cr: CGFloat = 6
        return RoundedRectangle(cornerRadius: cr)
            .fill(theme.widgetBackground)
            .overlay(content())
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: cr)
                        .strokeBorder(theme.widgetBorderColor, lineWidth: theme.widgetBorderWidth)

                    if theme.glassInnerGlow {
                        RoundedRectangle(cornerRadius: cr - 0.5, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        theme.glassHighlightColor,
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                            .padding(0.5)
                    }
                }
            )
            .shadow(
                color: theme.glassShadowRadius > 0 ? theme.glassShadowColor.opacity(0.5) : .clear,
                radius: theme.glassShadowRadius > 0 ? 4 : 0,
                y: 2
            )
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Ledge")
                .font(.largeTitle)
            Text("A macOS widget dashboard for the Corsair Xeneon Edge")
                .foregroundColor(.secondary)
            Text("Phase 1 — Widget Framework")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by the Settings "Preview Effect" button; DashboardView listens and triggers the active effect.
    static let ledgePreviewVisualEffect = Notification.Name("ledgePreviewVisualEffect")
}

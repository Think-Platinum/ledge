import Foundation
import SwiftUI  // For Array.move(fromOffsets:toOffset:) used in page reordering
import os.log

/// Manages the active widget layout and persists layouts to disk.
///
/// Stores layouts as JSON in `~/Library/Application Support/Ledge/layouts/`.
/// On first launch, creates and saves the default layout.
@Observable
class LayoutManager {

    private let logger = Logger(subsystem: "com.ledge.app", category: "LayoutManager")
    private let directory: URL
    private let activeLayoutFile: URL

    /// The currently active layout rendered on the Xeneon Edge.
    var activeLayout: WidgetLayout

    /// All saved layouts (these are the "pages" when swiping on the Edge).
    var savedLayouts: [WidgetLayout] = []

    /// Index of the currently active layout within `savedLayouts`.
    /// Used for page indicator and swipe navigation on the Edge.
    var activePageIndex: Int {
        savedLayouts.firstIndex(where: { $0.id == activeLayout.id }) ?? 0
    }

    /// Total number of pages (saved layouts).
    var pageCount: Int { savedLayouts.count }

    // MARK: - Auto-Rotation

    /// Whether pages automatically rotate on a timer.
    var autoRotateEnabled: Bool = false {
        didSet {
            saveKey(autoRotateEnabledKey, value: autoRotateEnabled)
            if autoRotateEnabled { startAutoRotation() } else { stopAutoRotation() }
        }
    }

    /// Interval in seconds between automatic page changes.
    var autoRotateInterval: TimeInterval = 30 {
        didSet {
            saveKey(autoRotateIntervalKey, value: autoRotateInterval)
            if autoRotateEnabled { startAutoRotation() }  // restart with new interval
        }
    }

    private var autoRotateTimer: Timer?
    private let autoRotateEnabledKey = "com.ledge.autoRotateEnabled"
    private let autoRotateIntervalKey = "com.ledge.autoRotateInterval"

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = appSupport.appendingPathComponent("Ledge/layouts", isDirectory: true)
        activeLayoutFile = directory.appendingPathComponent("active.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Load active layout or use default
        if let data = try? Data(contentsOf: activeLayoutFile),
           let layout = try? JSONDecoder().decode(WidgetLayout.self, from: data) {
            // Migrate old layouts (10x3) to the new denser grid (20x6)
            if layout.columns < 20 {
                activeLayout = Self.migrateLayout(layout)
                logger.info("Migrated layout '\(layout.name)' from \(layout.columns)x\(layout.rows) to \(self.activeLayout.columns)x\(self.activeLayout.rows)")
            } else {
                activeLayout = layout
            }
        } else {
            activeLayout = WidgetLayout.defaultLayout
        }

        loadSavedLayouts()

        // Migrate any saved layouts that are still on the old grid
        savedLayouts = savedLayouts.map { layout in
            if layout.columns < 20 {
                return Self.migrateLayout(layout)
            }
            return layout
        }

        // Persist immediately so widget instance UUIDs are stable across launches.
        // Without this, the default layout's UUIDs would be regenerated on every
        // launch (since WidgetLayout.defaultLayout creates new UUIDs), orphaning
        // any saved widget configs.
        save()

        // Restore auto-rotation settings
        if UserDefaults.standard.object(forKey: autoRotateEnabledKey) != nil {
            autoRotateEnabled = UserDefaults.standard.bool(forKey: autoRotateEnabledKey)
        }
        let savedInterval = UserDefaults.standard.double(forKey: autoRotateIntervalKey)
        if savedInterval > 0 { autoRotateInterval = savedInterval }

        if autoRotateEnabled { startAutoRotation() }
    }

    // MARK: - Widget Management

    /// Add a widget placement to the active layout.
    func addWidget(_ placement: WidgetPlacement) {
        activeLayout.placements.append(placement)
        save()
    }

    /// Remove a widget placement from the active layout by its ID.
    func removeWidget(id: UUID) {
        activeLayout.placements.removeAll { $0.id == id }
        save()
    }

    /// Update a widget placement in the active layout.
    func updateWidget(_ placement: WidgetPlacement) {
        if let index = activeLayout.placements.firstIndex(where: { $0.id == placement.id }) {
            activeLayout.placements[index] = placement
            save()
        }
    }

    // MARK: - Layout Management

    /// Switch to a different saved layout.
    func switchLayout(to layout: WidgetLayout) {
        activeLayout = layout
        save()
    }

    /// Switch to the next page (layout). Wraps around to the first page.
    func nextPage() {
        guard savedLayouts.count > 1 else { return }
        let nextIndex = (activePageIndex + 1) % savedLayouts.count
        switchLayout(to: savedLayouts[nextIndex])
        logger.info("Switched to page \(nextIndex + 1)/\(self.savedLayouts.count): \(self.activeLayout.name)")
    }

    /// Switch to the previous page (layout). Wraps around to the last page.
    func previousPage() {
        guard savedLayouts.count > 1 else { return }
        let prevIndex = (activePageIndex - 1 + savedLayouts.count) % savedLayouts.count
        switchLayout(to: savedLayouts[prevIndex])
        logger.info("Switched to page \(prevIndex + 1)/\(self.savedLayouts.count): \(self.activeLayout.name)")
    }

    /// Switch to a specific page by index.
    func switchToPage(_ index: Int) {
        guard index >= 0 && index < savedLayouts.count else { return }
        switchLayout(to: savedLayouts[index])
    }

    /// Save the active layout to disk.
    func save() {
        do {
            let data = try JSONEncoder().encode(activeLayout)
            try data.write(to: activeLayoutFile, options: .atomic)
        } catch {
            logger.error("Failed to save active layout: \(error.localizedDescription)")
        }

        // Also save to the layouts list
        if let index = savedLayouts.firstIndex(where: { $0.id == activeLayout.id }) {
            savedLayouts[index] = activeLayout
        } else {
            savedLayouts.append(activeLayout)
        }
        saveSavedLayouts()
    }

    /// Create a new empty layout with the given name.
    /// Uses the same grid dimensions as the active layout but starts with no widgets.
    func createLayout(name: String) -> WidgetLayout {
        let layout = WidgetLayout(
            id: UUID(),
            name: name,
            columns: activeLayout.columns,
            rows: activeLayout.rows,
            placements: [],  // Empty — user adds widgets to the new page
            backgroundImagePath: nil
        )
        savedLayouts.append(layout)
        saveSavedLayouts()
        return layout
    }

    /// Create a new layout by duplicating an existing one.
    func duplicateLayout(_ source: WidgetLayout, name: String) -> WidgetLayout {
        let layout = WidgetLayout(
            id: UUID(),
            name: name,
            columns: source.columns,
            rows: source.rows,
            placements: source.placements.map { p in
                // New UUIDs for each placement so widget configs are independent
                WidgetPlacement(
                    id: UUID(),
                    widgetTypeID: p.widgetTypeID,
                    column: p.column,
                    row: p.row,
                    columnSpan: p.columnSpan,
                    rowSpan: p.rowSpan,
                    configuration: p.configuration
                )
            },
            backgroundImagePath: source.backgroundImagePath
        )
        savedLayouts.append(layout)
        saveSavedLayouts()
        return layout
    }

    /// Delete a saved layout by ID. Cannot delete the active layout.
    func deleteLayout(id: UUID) {
        guard id != activeLayout.id else {
            logger.warning("Cannot delete the active layout")
            return
        }
        savedLayouts.removeAll { $0.id == id }
        saveSavedLayouts()
    }

    // MARK: - Auto-Rotation

    private func startAutoRotation() {
        stopAutoRotation()
        guard savedLayouts.count > 1 else { return }
        autoRotateTimer = Timer.scheduledTimer(withTimeInterval: autoRotateInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.35)) {
                    self?.nextPage()
                }
            }
        }
        logger.info("Auto-rotation started: \(self.autoRotateInterval)s interval")
    }

    private func stopAutoRotation() {
        autoRotateTimer?.invalidate()
        autoRotateTimer = nil
    }

    /// Reset the auto-rotation timer (e.g. after a manual swipe).
    func resetAutoRotationTimer() {
        if autoRotateEnabled { startAutoRotation() }
    }

    /// Restart auto-rotation if enabled (e.g. after adding/removing pages).
    private func restartAutoRotationIfNeeded() {
        if autoRotateEnabled { startAutoRotation() }
    }

    // MARK: - Page Reordering

    /// Move a page from one index to another.
    func movePage(from source: IndexSet, to destination: Int) {
        savedLayouts.move(fromOffsets: source, toOffset: destination)
        saveSavedLayouts()
    }

    /// Rename a saved layout.
    func renameLayout(id: UUID, to newName: String) {
        if let index = savedLayouts.firstIndex(where: { $0.id == id }) {
            savedLayouts[index].name = newName
            if activeLayout.id == id { activeLayout.name = newName }
            saveSavedLayouts()
            save()
        }
    }

    private func saveKey(_ key: String, value: some Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: - Migration

    /// Migrate a layout from the old grid density to 20x6 by doubling all coordinates.
    /// Preserves the exact same visual arrangement while enabling finer-grained sizing.
    private static func migrateLayout(_ layout: WidgetLayout) -> WidgetLayout {
        let scale = 2
        return WidgetLayout(
            id: layout.id,
            name: layout.name,
            columns: layout.columns * scale,
            rows: layout.rows * scale,
            placements: layout.placements.map { p in
                WidgetPlacement(
                    id: p.id,
                    widgetTypeID: p.widgetTypeID,
                    column: p.column * scale,
                    row: p.row * scale,
                    columnSpan: p.columnSpan * scale,
                    rowSpan: p.rowSpan * scale,
                    configuration: p.configuration
                )
            },
            backgroundImagePath: layout.backgroundImagePath
        )
    }

    // MARK: - Persistence

    private func loadSavedLayouts() {
        let listFile = directory.appendingPathComponent("layouts-list.json")
        guard let data = try? Data(contentsOf: listFile),
              let layouts = try? JSONDecoder().decode([WidgetLayout].self, from: data) else {
            // First launch — save the default
            savedLayouts = [activeLayout]
            saveSavedLayouts()
            return
        }
        savedLayouts = layouts
    }

    private func saveSavedLayouts() {
        let listFile = directory.appendingPathComponent("layouts-list.json")
        do {
            let data = try JSONEncoder().encode(savedLayouts)
            try data.write(to: listFile, options: .atomic)
        } catch {
            logger.error("Failed to save layouts list: \(error.localizedDescription)")
        }
    }
}

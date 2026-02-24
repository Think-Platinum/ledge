import CoreGraphics
import os.lock
import Foundation

/// Rolling buffer of recent touch events for diagnostics.
///
/// The flight recorder captures the last N touch events with full context:
/// coordinates, device ID, delivery status, and latency. It's the data source
/// for the Touch Diagnostics widget and provides post-mortem debugging when
/// touch drops or crashes occur.
///
/// Thread-safe: the CGEventTap callback (nonisolated, event tap thread) appends
/// entries while the widget (MainActor) reads them. Access is serialised via
/// `OSAllocatedUnfairLock`.
final class TouchFlightRecorder: @unchecked Sendable {

    // MARK: - Types

    /// The delivery outcome of a touch event.
    enum DeliveryStatus: String, Sendable {
        case delivered  = "✓"
        case dropped    = "⚠"  // Remap failed or panel missing
        case suppressed = "–"  // Intentionally suppressed (hover noise)
    }

    /// A single recorded touch event.
    struct Entry: Sendable {
        let timestamp: Date
        let sequenceID: UInt64
        let deviceID: Int64
        let originalPoint: CGPoint
        let remappedPoint: CGPoint?
        let eventType: EventKind
        let deliveryStatus: DeliveryStatus
        /// Time from CGEvent arrival to panel.sendEvent dispatch (milliseconds).
        var deliveryLatencyMs: Double?
    }

    /// Simplified event type for recording (avoids importing CoreGraphics enums everywhere).
    enum EventKind: String, Sendable {
        case down  = "↓"
        case drag  = "↔"
        case up    = "↑"
        case move  = "→"
        case other = "?"

        init(cgEventType rawValue: UInt32) {
            switch rawValue {
            case 1:  self = .down   // kCGEventLeftMouseDown
            case 2:  self = .up     // kCGEventLeftMouseUp
            case 6:  self = .drag   // kCGEventLeftMouseDragged
            case 5:  self = .move   // kCGEventMouseMoved
            default: self = .other
            }
        }
    }

    // MARK: - Configuration

    /// Maximum entries retained in the ring buffer.
    let capacity: Int

    // MARK: - Storage

    /// Lock-protected ring buffer.
    private let lock = OSAllocatedUnfairLock(initialState: RingState())

    /// Internal state protected by the lock.
    private struct RingState {
        var buffer: [Entry] = []
        var totalRecorded: UInt64 = 0
        var totalDropped: UInt64 = 0
        /// Timestamps of recent events for rate calculation (last 2 seconds).
        var recentTimestamps: [Date] = []
    }

    // MARK: - Init

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    // MARK: - Recording

    /// Append a new entry to the ring buffer. Thread-safe.
    func append(_ entry: Entry) {
        lock.withLock { state in
            state.buffer.append(entry)
            if state.buffer.count > capacity {
                state.buffer.removeFirst(state.buffer.count - capacity)
            }
            state.totalRecorded += 1
            if entry.deliveryStatus == .dropped {
                state.totalDropped += 1
            }

            // Track timestamps for rate calculation (keep last 2 seconds)
            let now = entry.timestamp
            state.recentTimestamps.append(now)
            let cutoff = now.addingTimeInterval(-2.0)
            state.recentTimestamps.removeAll { $0 < cutoff }
        }
    }

    // MARK: - Reading

    /// Snapshot of the most recent entries. Thread-safe.
    /// - Parameter count: Maximum number of entries to return (from most recent).
    func recentEntries(count: Int = 20) -> [Entry] {
        lock.withLock { state in
            if state.buffer.count <= count {
                return state.buffer
            }
            return Array(state.buffer.suffix(count))
        }
    }

    /// All entries in the buffer. Thread-safe.
    var allEntries: [Entry] {
        lock.withLock { state in state.buffer }
    }

    /// Total events recorded since launch.
    var totalRecorded: UInt64 {
        lock.withLock { state in state.totalRecorded }
    }

    /// Total dropped events since launch.
    var totalDropped: UInt64 {
        lock.withLock { state in state.totalDropped }
    }

    /// Current events-per-second rate (based on last 2 seconds of data).
    var eventsPerSecond: Double {
        lock.withLock { state in
            guard state.recentTimestamps.count >= 2,
                  let first = state.recentTimestamps.first,
                  let last = state.recentTimestamps.last else {
                return 0
            }
            let interval = last.timeIntervalSince(first)
            guard interval > 0 else { return 0 }
            return Double(state.recentTimestamps.count) / interval
        }
    }

    /// Average delivery latency across all entries that have a latency value (milliseconds).
    var averageLatencyMs: Double? {
        lock.withLock { state in
            let latencies = state.buffer.compactMap(\.deliveryLatencyMs)
            guard !latencies.isEmpty else { return nil }
            return latencies.reduce(0, +) / Double(latencies.count)
        }
    }

    /// Update the delivery latency for the most recent entry matching the given sequence ID.
    /// Called from the panel's delivery confirmation callback to measure CGEventTap → sendEvent delay.
    func updateLatency(sequenceID: UInt64, latencyMs: Double) {
        lock.withLock { state in
            // Search from the end (most recent) since the matching entry is almost always the last one
            if let index = state.buffer.lastIndex(where: { $0.sequenceID == sequenceID }) {
                state.buffer[index].deliveryLatencyMs = latencyMs
            }
        }
    }

    /// Clear all recorded data. Thread-safe.
    func clearAll() {
        lock.withLock { state in
            state.buffer.removeAll()
            state.totalRecorded = 0
            state.totalDropped = 0
            state.recentTimestamps.removeAll()
        }
    }
}

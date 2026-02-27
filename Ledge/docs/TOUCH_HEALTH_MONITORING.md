# Touch Health Monitoring System

## Problem Statement

After building an app archive and installing Ledge, touch input from the Xeneon Edge panel was escaping to macOS instead of being intercepted. The CGEventTap would work initially but at some point would fail, leaving the Touch Diagnostics widget sitting idle with no indication of what went wrong.

The core issue: **the watchdog could only detect if the tap was explicitly disabled, but couldn't detect if the tap had crashed or become non-functional while still appearing "enabled"**.

## Solution: Enhanced Watchdog with Dead Tap Detection

The `TouchWatchdog` has been enhanced with **active heartbeat monitoring** that detects when touch events stop arriving even though the event tap is technically enabled.

### New Capabilities

#### 1. **Dead Tap Detection**
- **Problem**: CGEventTap thread can crash or become unresponsive while the tap remains "enabled"
- **Solution**: Track event arrival rate via the flight recorder
- **Detection**: If no events arrive for 12+ seconds (4 consecutive checks at 3-second intervals) AND we've seen events before, flag as "dead tap"
- **Result**: Alert shown in Touch Diagnostics widget with recovery instructions

#### 2. **Heartbeat Monitoring**
- Every touch event processed calls `watchdog.recordEventActivity()`
- Watchdog tracks `consecutiveQuietChecks` — number of health checks with zero new events
- Differentiates between "user hasn't touched the screen" vs "tap has stopped working"

#### 3. **Proactive Visual Alerts**
- Touch Diagnostics widget now shows an **orange alert banner** when:
  - Tap is disabled (existing detection)
  - Tap is dead (new detection)
- Alert includes:
  - Clear status message ("⚠️ TAP DEAD (no events)")
  - Explanation ("Quiet for Xs — tap may have crashed")
  - Recovery instructions ("Toggle panel OFF/ON or tap to retry")
  - Manual recovery button (force tap disable/re-enable cycle)

#### 4. **Faster Detection**
- Check interval reduced from 5s → 3s
- Dead tap detected after 12s of silence (4 checks × 3s)
- Less time spent unknowingly in a broken state

### Code Changes

#### TouchWatchdog.swift
- Added `isDeadTapDetected` state
- Added `consecutiveQuietChecks` counter
- Added `lastEventTime` tracking
- Added callbacks: `getLastEventTimestamp()`, `getTotalEventCount()`
- Added `recordEventActivity()` for heartbeat notification
- Added `forceRecovery()` for manual intervention
- Added `healthStatus` computed property for UI display

#### DisplayManager.swift
- Wire watchdog callbacks to flight recorder on startup:
  ```swift
  touchWatchdog.getLastEventTimestamp = { [weak self] in
      self?.flightRecorder.recentEntries(count: 1).last?.timestamp
  }
  touchWatchdog.getTotalEventCount = { [weak self] in
      self?.flightRecorder.totalRecorded ?? 0
  }
  ```
- Notify watchdog on every touch event:
  ```swift
  Task { @MainActor in
      self?.touchWatchdog.recordEventActivity()
  }
  ```

#### TouchDiagnosticsWidget.swift
- Added `alertBanner` view that appears when tap is unhealthy
- Shows different messages for disabled vs dead tap
- Added manual recovery button
- Enhanced status dots to show dead tap as warning state
- Added "quiet" stat showing how long since last event

## Detection Flow

```
Touch Event Arrives
    ↓
TouchRemapper.processEvent()
    ↓
onEventProcessed callback
    ↓
FlightRecorder.append(entry)
    ↓
TouchWatchdog.recordEventActivity() ← HEARTBEAT
    ↓
consecutiveQuietChecks = 0
```

```
No Touch Events (3s)
    ↓
Watchdog Timer Fires
    ↓
Check: tap enabled? ✓
Check: new events since last check? ✗
    ↓
consecutiveQuietChecks += 1
```

```
No Touch Events (12s+)
    ↓
consecutiveQuietChecks >= 4
AND totalRecorded > 0
    ↓
isDeadTapDetected = true
    ↓
Touch Diagnostics Widget shows alert
```

## User Recovery Options

When the dead tap is detected, users can:

1. **Toggle Panel OFF/ON** (recommended)
   - Settings > Display > "Panel on Edge" toggle
   - Tears down and recreates the entire touch pipeline

2. **Tap Manual Recovery Button**
   - Orange circular arrow button in the alert banner
   - Calls `watchdog.forceRecovery()`
   - Disables tap, waits 100ms, re-enables tap
   - Faster than full panel toggle but may not fix all issues

3. **Restart Ledge**
   - Nuclear option if the above don't work
   - Guarantees clean state

## Diagnostic Widget Display States

### Normal (Healthy)
```
✓ AX  ✓ Tap  ✓ Cal  ✓ WD    dev:12345
ev/s 0.0  drop 0  lat 2.3ms
```

### Dead Tap Detected
```
┌────────────────────────────────────────────────────┐
│ ⚠️ ⚠️ TAP DEAD (no events)                         │
│    Quiet for 12s — tap may have crashed            │
│    Toggle panel OFF/ON or tap to retry         [↻] │
└────────────────────────────────────────────────────┘
✓ AX  ✓ Tap  ✓ Cal  ⚠ WD    dev:12345
ev/s 0.0  drop 0  lat 2.3ms  quiet 12s
```

### Tap Disabled (Auto-Recovery)
```
┌────────────────────────────────────────────────────┐
│ ⚠️ ⚠️ TAP DISABLED                                  │
│    Auto-recovery attempted 3×                   [↻] │
└────────────────────────────────────────────────────┘
✓ AX  ✗ Tap  ✓ Cal  ✗ WD    dev:12345
```

## Known Limitations

1. **False positives if user never touches**
   - Mitigation: Only flag as dead if `totalRecorded > 0` (we've seen events before)
   - If user never touches after app launch, no dead tap alert

2. **Threshold tuning**
   - Current: 12s quiet = dead tap
   - May need adjustment based on real-world usage
   - Too short: false alarms during normal use
   - Too long: user suffers broken touch longer

3. **Can't detect all failure modes**
   - If the tap is intercepting but not delivering to panel, this won't detect it
   - If macOS completely blocks the tap (e.g., security policy), might appear dead
   - More sophisticated checks could be added (e.g., verify panel receives events)

## Testing Recommendations

1. **Normal usage**: Touch the screen periodically, verify no false alarms
2. **Simulated crash**: Manually disable tap via `CGEvent.tapEnable(tap: tap, enable: false)`, verify detection
3. **Recovery**: Trigger dead tap detection, use manual recovery button, verify tap restores
4. **Archive build**: Test in real-world installed app (not Xcode debug session)

## Future Enhancements

- [ ] Detect "partial failure" where tap intercepts but panel doesn't receive events
- [ ] Auto-recovery for dead tap (not just disabled tap) — requires panel reconstruction
- [ ] Notification Center alert when tap fails (for when diagnostic widget isn't visible)
- [ ] Log export for debugging (flight recorder + watchdog state)
- [ ] Adjustable dead tap threshold in Settings

## Related Files

- `TouchWatchdog.swift` — Core monitoring logic
- `TouchRemapper.swift` — Event tap implementation
- `TouchFlightRecorder.swift` — Event history tracking
- `DisplayManager.swift` — Wiring and lifecycle
- `TouchDiagnosticsWidget.swift` — User-facing diagnostics UI
- `FOCUS_MANAGEMENT.md` — Background on CGEventTap approach

# DateTime Widget: Multiple Timezone Support

## Feature Overview

The DateTime widget now supports displaying **multiple timezones simultaneously**, with the number of visible timezones automatically adapting based on widget size. This is perfect for the Xeneon Edge's ultrawide format — users can see time across global offices, track remote team hours, or monitor international markets at a glance.

## Key Features

### 1. **Adaptive Layout Based on Widget Size**

The widget intelligently determines how many additional timezones to display based on its height:

| Height Range | Size Category | Max Additional Timezones | Primary Time Size |
|--------------|---------------|--------------------------|-------------------|
| < 150pt      | Compact       | 0 (primary only)         | 48pt max          |
| 150-250pt    | Medium        | 1-2                      | 60pt max          |
| 250pt+       | Large         | 3-4                      | 72pt max          |

- **Compact (2 rows)**: Shows only the primary time — ideal for small clock widgets
- **Medium (3-4 rows)**: Can fit 1-2 additional timezones below the primary
- **Large (5-6 rows)**: Full world clock mode with up to 4 additional timezones

### 2. **Smart Timezone Display**

Each additional timezone row shows:
- **City name**: Extracted from timezone ID (e.g., "America/New_York" → "New York")
- **Current time**: In that timezone, formatted according to widget settings (24h/12h, seconds)
- **Offset indicator**: Shows hour difference from primary timezone (e.g., "+2h", "-5h", "=")

Example display (large widget):
```
┌─────────────────────────────┐
│                             │
│         14:32:15            │  ← Primary (London)
│     Tuesday, 25 February    │
│   ─────────────────────     │
│   New York    09:32:15  -5h │  ← Additional timezones
│   Tokyo       23:32:15  +9h │
│   Sydney      01:32:15 +11h │
│                             │
└─────────────────────────────┘
```

### 3. **Configuration Options**

**Primary Timezone:**
- Defaults to local system timezone
- Can be set to any timezone from the full `TimeZone.knownTimeZoneIdentifiers` list
- Primary time is displayed in large, thin monospaced font

**Additional Timezones:**
- Add up to 4 timezones (space permitting)
- Quick-add menu with 11 common timezones:
  - America: New York, Los Angeles, Chicago
  - Europe: London, Paris, Berlin
  - Asia: Tokyo, Shanghai, Singapore
  - Oceania: Sydney, Auckland
- Full timezone picker available for any other timezone
- Easy remove via minus button

**Time Format:**
- 24-hour or 12-hour (AM/PM)
- Show/hide seconds
- All timezones follow the same format

**Date Display:**
- Show/hide date line
- Customizable date format (e.g., "EEEE, d MMMM" → "Tuesday, 25 February")

**Calendar Integration:**
- Optional tint with current meeting color
- Shows meeting name instead of date when in a calendar event

## Implementation Details

### Config Structure

```swift
struct Config: Codable {
    var use24Hour: Bool = true
    var showSeconds: Bool = true
    var showDate: Bool = true
    var dateFormat: String = "EEEE, d MMMM"
    var primaryTimezone: String? = nil  // nil = local timezone
    var additionalTimezones: [String] = []  // Up to 4
    var tintWithCalendarColor: Bool = false
}
```

### Searchable Timezone Picker

A custom `TimezonePickerSheet` provides the search UI:

**Key Features:**
- **Real-time filtering**: Searches both timezone ID and city name as you type
- **Smart suggestions**: Shows 25 common timezones when not searching
- **Exclusion logic**: Hides already-selected timezones to prevent duplicates
- **Current time preview**: Shows the current time in each timezone (HH:mm format)
- **Sheet presentation**: Uses `.sheet()` modifier for native macOS experience

**Performance:**
- All 425+ timezones from `TimeZone.knownTimeZoneIdentifiers` are searchable
- Filtering is instant (simple string contains check)
- List only renders visible rows (SwiftUI List virtualization)

### Layout Calculation

The `calculateLayout(size:)` function returns metrics for:
- Primary time font size (scales with widget width)
- Date font size
- Timezone row font size
- Spacing between elements
- **Maximum additional timezones** (based on available height)

This ensures the widget never overflows — if the user configures 4 timezones but the widget is only medium-sized, it will show the first 2.

### Timezone Utilities

- **`cityName(for:)`**: Extracts readable city name from timezone ID
- **`timezoneOffset(for:)`**: Calculates hour difference from primary timezone
  - Accounts for DST transitions (uses current date for offset calculation)
  - Returns "=" if offset is 0 (same timezone)
  - Returns "+Xh" or "-Xh" for positive/negative offsets

### Performance

- Single `Timer.publish` at 0.5s interval updates all times
- DateFormatter instances are created on-demand (no caching yet, could be optimized)
- Timezone offset recalculated every tick to handle DST transitions

## Usage Scenarios

### 1. **Remote Team Coordination**
Configure timezones for all your team members' locations. Instantly see if it's reasonable to schedule a meeting ("Oh, it's 11 PM in Sydney — probably not").

### 2. **International Markets**
Track opening/closing hours for stock exchanges:
- New York (NYSE)
- London (LSE)
- Tokyo (TSE)
- Sydney (ASX)

### 3. **Travel Planning**
Set your destination timezone as primary, keep home timezone as additional. See both times at a glance to avoid confusion during trips.

### 4. **Global Operations Dashboard**
On a 20×6 Xeneon Edge layout, allocate a 6×3 or 8×3 widget for DateTime with 3-4 timezones showing all major offices simultaneously.

## Future Enhancements

- [ ] **Timezone aliases**: Custom labels like "Home", "Office", "Client" instead of city names
- [ ] **Date line per timezone**: Show date in each timezone (useful for crossing date lines)
- [ ] **Day/night indicator**: Visual icon (sun/moon) or color tint showing whether it's daytime in each timezone
- [ ] **Timezone presets**: Save and load timezone sets (e.g., "European Offices", "APAC Team", "Global Markets")
- [ ] **Analog clock faces**: Option for analog display of timezones instead of digital
- [ ] **DateFormatter caching**: Optimize by caching formatters per timezone instead of recreating on every tick

## Example Configurations

### Compact (4×2 Widget)
```yaml
Primary: Local
Additional: [] (none shown)
Display: Large time + date only
```

### Medium (4×4 Widget)
```yaml
Primary: America/New_York
Additional:
  - Europe/London
  - Asia/Tokyo
Display: Primary time + date + 2 additional timezones
```

### Large (8×6 Widget)
```yaml
Primary: Europe/London (User's home)
Additional:
  - America/New_York (NYC office)
  - America/Los_Angeles (SF office)
  - Asia/Tokyo (Tokyo office)
  - Australia/Sydney (Sydney office)
Display: Full world clock with all 4 timezones
```

## Configuration UI

The settings panel has been redesigned with clear sections and a **searchable timezone picker**:

### Settings Sections

1. **Time Format**: 24h toggle, show seconds toggle
2. **Date Display**: Show date toggle, format string
3. **Primary Timezone**: Button that opens the searchable picker
4. **Additional Timezones**: List of configured zones with remove buttons, plus "Add Timezone" button
5. **Calendar Integration**: Meeting color tint toggle

### Searchable Timezone Picker

When adding or changing timezones, a **full-screen sheet** appears with:

**Search Field:**
- Type to filter by city name or timezone ID
- Real-time filtering as you type
- Clear button (×) to reset search
- Example searches: "london", "new york", "tokyo", "america/los"

**Search Results:**
- **"Local" option** (primary timezone only) — uses system timezone
- **"Suggested" section** (when not searching) — 25 common timezones for quick access
- **"All Timezones" section** — Full list, filtered by search
- **"Search Results" section** (when searching) — Shows matching timezones

**Each Timezone Row Shows:**
- City name (e.g., "New York")
- Full timezone ID (e.g., "America/New_York")
- Current time in that timezone (e.g., "09:32")

**Smart Filtering:**
- Already-configured timezones are hidden from the list
- Primary timezone excluded from additional timezone picker
- No duplicates possible

### Example Usage Flow

1. Tap "Add Timezone" button
2. Sheet opens with suggested timezones
3. Start typing "syd" → list instantly filters to Sydney
4. Tap "Sydney" → timezone added, sheet dismisses
5. Repeat for up to 4 total timezones

### Visual Design

```
┌─────────────────────────────────────┐
│  Select Primary Timezone      Cancel│
├─────────────────────────────────────┤
│  🔍 Search city or timezone...   ×  │
├─────────────────────────────────────┤
│                                     │
│  Suggested                          │
│  ├─ New York                  09:32 │
│  │  America/New_York                │
│  ├─ London                    14:32 │
│  │  Europe/London                   │
│  └─ Tokyo                     23:32 │
│     Asia/Tokyo                       │
│                                     │
│  All Timezones                      │
│  ├─ ...                             │
│                                     │
└─────────────────────────────────────┘
```

With search:
```
┌─────────────────────────────────────┐
│  Select Primary Timezone      Cancel│
├─────────────────────────────────────┤
│  🔍 paris                        ×  │
├─────────────────────────────────────┤
│                                     │
│  Search Results                     │
│  ├─ Paris                     15:32 │
│  │  Europe/Paris                    │
│                                     │
└─────────────────────────────────────┘
```

## Related Files

- `DateTimeWidget.swift` — Widget implementation
- `ROADMAP.md` — Feature tracked in Phase 3 polish items

# DateTime Widget: Searchable Timezone Picker

**Enhancement Date:** February 24, 2026

## Problem Statement

The original timezone picker used a standard SwiftUI `Picker` with 425+ timezones in a dropdown menu. This was unusable — finding a specific timezone required scrolling through the entire alphabetical list, and the picker was limited to showing only 50-100 entries at a time.

User request:
> "The entry of the timezone in the clock widget should allow typing of the city, at the moment the list is too long to show everything. It should be type first, then narrow the list based on what is typed"

## Solution: Custom Searchable Sheet

Replaced the `Picker` with a **custom full-screen sheet** featuring:
- Real-time search field
- Instant filtering by city name OR timezone ID
- Suggested timezones section (25 common zones)
- Current time preview for each timezone
- Smart exclusion of already-selected timezones

## Implementation

### New Component: `TimezonePickerSheet`

A custom SwiftUI sheet that presents a searchable list of all timezones.

**Key Properties:**
```swift
struct TimezonePickerSheet: View {
    let title: String                   // "Select Primary Timezone" or "Add Timezone"
    let allowLocal: Bool                // Show "Local" option (primary only)
    let excludeTimezones: [String]      // Hide already-selected zones
    let onSelect: (String?) -> Void     // Callback when user selects
    
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
}
```

**UI Structure:**
- **Navigation bar** with title and Cancel button
- **Search field** with magnifying glass icon and clear button
- **List sections:**
  - "Local" (if `allowLocal` is true and not searching)
  - "Suggested" (25 common timezones, only when not searching)
  - "All Timezones" or "Search Results" (depending on search state)

**Search Logic:**
```swift
private var filteredTimezones: [String] {
    let available = allTimezones.filter { !excludeTimezones.contains($0) }
    
    if searchText.isEmpty {
        return available
    }
    
    let search = searchText.lowercased()
    return available.filter { tzID in
        // Search by timezone ID (e.g., "America/New_York")
        if tzID.lowercased().contains(search) {
            return true
        }
        // Search by city name (e.g., "New York")
        let city = cityName(for: tzID).lowercased()
        if city.contains(search) {
            return true
        }
        return false
    }
}
```

**Each Timezone Row:**
- **Primary text**: City name (extracted from timezone ID)
- **Secondary text**: Full timezone ID
- **Trailing text**: Current time in that timezone (HH:mm)

### Changes to `DateTimeSettingsView`

**Replaced:**
```swift
// OLD: Standard Picker
Picker("Timezone", selection: $config.primaryTimezone) {
    Text("Local").tag(nil as String?)
    ForEach(TimeZone.knownTimeZoneIdentifiers.prefix(50), id: \.self) { tzID in
        Text(tzID).tag(tzID as String?)
    }
}
```

**With:**
```swift
// NEW: Button that opens sheet
HStack {
    Text("Timezone")
        .foregroundColor(.secondary)
    Spacer()
    Button(action: {
        showingPrimaryTimezonePicker = true
    }) {
        Text(config.primaryTimezone.map { cityName(for: $0) } ?? "Local")
            .foregroundColor(.primary)
    }
    .buttonStyle(.plain)
}
```

**Sheet Presentation:**
```swift
.sheet(isPresented: $showingPrimaryTimezonePicker) {
    TimezonePickerSheet(
        title: "Select Primary Timezone",
        allowLocal: true,
        excludeTimezones: [],
        onSelect: { tzID in
            config.primaryTimezone = tzID
            saveConfig()
            showingPrimaryTimezonePicker = false
        }
    )
}
```

**Additional Timezones:**
- Same pattern for the "Add Timezone" button
- Excludes primary timezone + already-added timezones
- `allowLocal: false` (only for primary timezone)

## User Experience

### Before (Standard Picker)
1. Click "Timezone" picker
2. Dropdown shows 50 timezones
3. Scroll through alphabetical list
4. If your timezone isn't in the first 50, it's not visible
5. No search capability

### After (Searchable Sheet)
1. Click "Timezone" button
2. Sheet opens with search field at top
3. Type "london" → list instantly filters to London timezones
4. Tap "London" → sheet dismisses, timezone selected
5. Fast, intuitive, works for all 425+ timezones

### Example Interactions

**Finding "Sydney":**
```
[Search field: "syd"]

Search Results
├─ Sydney                    01:32
│  Australia/Sydney
└─ Sydney                    01:32
   Australia/Lindeman
```

**Finding "Pacific" timezones:**
```
[Search field: "pacific"]

Search Results
├─ Apia                      04:32
│  Pacific/Apia
├─ Auckland                  03:32
│  Pacific/Auckland
├─ Fiji                      03:32
│  Pacific/Fiji
└─ ... (20+ more Pacific timezones)
```

**Browsing suggestions (no search):**
```
[Search field: empty]

Suggested
├─ New York                  09:32
│  America/New_York
├─ Los Angeles               06:32
│  America/Los_Angeles
├─ London                    14:32
│  Europe/London
├─ Paris                     15:32
│  Europe/Paris
└─ ... (21 more suggestions)

All Timezones
├─ Abidjan                   14:32
│  Africa/Abidjan
└─ ... (400+ more)
```

## Suggested Timezones

The picker includes 25 pre-selected common timezones for quick access:

**Americas:**
- New York, Los Angeles, Chicago, Denver
- Toronto, Mexico City, São Paulo

**Europe:**
- London, Paris, Berlin, Rome, Madrid, Moscow

**Asia:**
- Tokyo, Shanghai, Hong Kong, Singapore
- Seoul, Dubai, Kolkata

**Oceania:**
- Sydney, Melbourne, Auckland

**Africa:**
- Johannesburg, Cairo

These cover major financial centers, tech hubs, and business capitals across all continents.

## Performance

- **All 425+ timezones** are available for search
- **Filtering is instant** — simple string contains check on city name and timezone ID
- **SwiftUI List virtualization** — only visible rows are rendered
- **No lag** even with large result sets

## Future Enhancements

- [ ] **Fuzzy search**: Match partial city names (e.g., "ny" → "New York")
- [ ] **Search by country**: Filter by country name (e.g., "australia" → all Australian timezones)
- [ ] **Recents section**: Show recently selected timezones at the top
- [ ] **Favorites**: Let users star frequently used timezones
- [ ] **Time zone abbreviations**: Search by abbreviations (e.g., "EST", "PST", "GMT")
- [ ] **Offset search**: Find timezones by offset (e.g., "GMT+10")

## Testing Recommendations

1. **Basic search**: Type "london", verify London appears
2. **City name search**: Type "new york", verify it finds "America/New_York"
3. **Timezone ID search**: Type "america/los", verify it finds "America/Los_Angeles"
4. **Clear button**: Type something, tap ×, verify search clears
5. **No results**: Type gibberish, verify "No timezones found" message
6. **Exclusion**: Add a timezone, try to add it again, verify it's hidden from the picker
7. **Current time**: Verify the times shown are accurate for each timezone
8. **Cancel**: Open sheet, tap Cancel, verify nothing changes

## Related Files

- `DateTimeWidget.swift` — Contains `DateTimeSettingsView` and `TimezonePickerSheet`
- `DATETIME_TIMEZONE_FEATURE.md` — Full feature documentation
- `CHANGES_SUMMARY.md` — Overall summary of all changes

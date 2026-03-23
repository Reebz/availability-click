---
title: "feat: Calendar Click — macOS menu bar availability copier"
type: feat
status: active
date: 2026-03-24
origin: docs/brainstorms/2026-03-24-calendar-click-brainstorm.md
---

# feat: Calendar Click — macOS Menu Bar Availability Copier

## Enhancement Summary

**Deepened on:** 2026-03-24
**Research agents used:** EventKit best practices, NSStatusItem patterns, time formatting edge cases, architecture review, security audit, spec flow analysis

### Key Improvements
1. Concrete Swift code patterns for left-click/right-click wiring, EventKit access, and icon animation
2. Event filtering rules: exclude declined/cancelled events, honor `event.availability` property
3. Range semantics fully defined (next week = next Mon-Fri, fortnight = 14 calendar days, etc.)
4. 47 edge cases identified and resolved (DST, midnight events, weekend clicks, rapid double-click)
5. Security hardened: App Sandbox enabled, auth checked per-query, Hardened Runtime for notarization

### Design Decisions Made During Deepening
- **No-availability feedback:** Flash X-mark icon instead of macOS notification (avoids notification permission)
- **Working hours storage:** Minutes-since-midnight (Int) instead of hour (Int) — supports 8:30am start
- **AvailabilityFormatter is pure:** Clipboard write happens in the coordinator, not the formatter
- **Settings use `@AppStorage` directly** — no `@Observable` wrapper needed at this scale
- **All-day events do NOT block time** — they represent dates, not time slots (vacations are out of scope for V1)
- **Brainstorm format correction:** `2pm-3pm` → `2-3pm` (same-period suffix elision rule applies)

---

## Overview

A native macOS menu bar app that copies formatted calendar availability to the clipboard in one click. Left-click copies, right-click offers extended date ranges, Cmd+V pastes into any email or chat. Reads all calendars via EventKit — no OAuth, no API keys, no Calendly links.

(see brainstorm: docs/brainstorms/2026-03-24-calendar-click-brainstorm.md)

## Proposed Solution

A Swift menu bar app (no Dock icon) using NSStatusItem for the menu bar presence, EventKit for calendar access, SwiftUI for the settings window, and UserDefaults for persistence.

## Technical Approach

### Architecture

```
CalendarClick/
├── CalendarClickApp.swift          # @main App entry, NSApplicationDelegateAdaptor, Settings scene
├── AppDelegate.swift               # NSStatusItem setup, owns the copy pipeline
├── Models/
│   ├── AppSettings.swift           # @AppStorage constants + validation
│   └── TimeSlot.swift              # struct TimeSlot { start: Date, end: Date }
├── Services/
│   ├── CalendarService.swift       # EKEventStore singleton, permission, event fetching
│   ├── AvailabilityService.swift   # Inverts busy events → free slots per day
│   └── AvailabilityFormatter.swift # Pure function: [Date: [TimeSlot]] → String
├── Views/
│   ├── SettingsView.swift          # SwiftUI settings window
│   └── CalendarPickerView.swift    # Calendar checklist with color dots
├── Utilities/
│   └── StatusItemController.swift  # Menu bar icon, click handling, checkmark animation
├── Assets.xcassets/                # Menu bar template image (18x18 @1x, 36x36 @2x)
├── CalendarClick.entitlements      # App Sandbox + calendar access
└── Info.plist                      # LSUIElement, NSCalendarsFullAccessUsageDescription
```

### Key Technical Decisions

**App lifecycle:** SwiftUI `@main` App with `NSApplicationDelegateAdaptor(AppDelegate.self)`. No `MenuBarExtra` — it cannot distinguish left-click from right-click. `LSUIElement = true` hides the Dock icon.

```swift
@main
struct CalendarClickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView() }
    }
}
```

**Menu bar interaction (NSStatusItem):**

Left-click triggers the copy pipeline. Right-click shows an NSMenu. The pattern uses `sendAction(on:)` to receive both event types, then branches:

```swift
button.sendAction(on: [.leftMouseUp, .rightMouseUp])

@objc func handleClick(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
        // Temporarily assign menu, trigger, clear
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    } else {
        copyAvailability(range: .default)
    }
}
```

**Right-click menu items:** "Next week", "Next fortnight", "Next 30 days", separator, "Settings...", "Quit"

**Pipeline ownership:** `AppDelegate` owns the full copy pipeline: CalendarService → AvailabilityService → AvailabilityFormatter → clipboard → StatusItemController feedback. `StatusItemController` handles only the icon and animation — it is not a coordinator.

### EventKit Access

**Singleton EKEventStore** — Apple mandates one instance per app. Multiple stores cause inconsistent data.

```swift
@MainActor
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()
}
```

**Permission request (macOS 14+):**

```swift
func requestAccess() async throws -> Bool {
    try await store.requestFullAccessToEvents()
}
```

**Required Info.plist keys:**
```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Calendar Click reads your events to calculate your availability.</string>
```

**Auth check before every query** — not just at startup. Permission can be revoked while the app is running:

```swift
func ensureAccess() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    return status == .fullAccess || status == .authorized
}
```

**Fetch events asynchronously** — `events(matching:)` is synchronous and can take 100-500ms for 30 days:

```swift
func fetchEvents(from start: Date, to end: Date, calendars: [EKCalendar]?) async -> [EKEvent] {
    await Task.detached(priority: .userInitiated) { [store] in
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
    }.value
}
```

**Stale data:** Listen for `EKEventStoreChanged`, debounce (500ms), call `store.reset()`. Do not hold references to EKEvent objects across resets.

### Event Filtering Rules

Not all events should block time. Filter before availability calculation:

| Event property | Block time? | Rationale |
|---|---|---|
| `isAllDay == true` | No | Represents a date, not a time slot |
| Midnight-to-midnight (not flagged all-day) | No | Same as all-day |
| `attendee.participantStatus == .declined` | No | User won't attend |
| `event.status == .canceled` | No | Event cancelled |
| `event.availability == .free` | No | "Focus time" blocks marked free |
| `attendee.participantStatus == .tentative` | Yes (V1) | Conservative — block it |
| `attendee.participantStatus == .accepted` | Yes | Confirmed busy |
| No attendees (user's own event) | Yes | User created it |

```swift
func shouldBlockTime(_ event: EKEvent) -> Bool {
    if event.isAllDay { return false }
    if event.status == .canceled { return false }
    if event.availability == .free { return false }

    if let attendees = event.attendees, !attendees.isEmpty,
       let me = attendees.first(where: { $0.isCurrentUser }),
       me.participantStatus == .declined {
        return false
    }
    return true
}
```

### Range Semantics

| Menu item | Definition | Example (clicked Wed Mar 26) |
|---|---|---|
| Default (left-click) | Configurable: "This week" or "Next N business days" | Depends on setting |
| "This week" mode | Mon-Fri of current calendar week. If all remaining time has passed (Fri after hours, weekend), auto-roll to next Mon-Fri | Wed-Fri Mar 26-28 |
| "Next N business days" | N working days starting from today (if viable slots remain after buffer) or next business day. Skips non-working days | Next 3 = Wed Mar 26, Thu Mar 27, Fri Mar 28 |
| Next week | The following Mon-Fri (never includes current week) | Mon Mar 31 - Fri Apr 4 |
| Next fortnight | 14 calendar days starting from next Monday, filtered to working days only | Mon Mar 31 - Fri Apr 11 (10 business days) |
| Next 30 days | 30 calendar days from tomorrow, filtered to working days only | Thu Mar 27 - Fri Apr 24 |

**"This week" auto-roll:** If clicked Friday after working hours or on a weekend, automatically show next Mon-Fri instead of empty results.

**"Next N business days" and today:** Include today if viable slots remain after applying the buffer. If buffer eliminates all of today, start counting from the next business day. Today still counts as day 1 if it has any remaining slots.

### Availability Calculation Algorithm

```
1. Determine date range (from range semantics table above)
2. Fetch all events for the full range in one query (pass selected calendars)
3. Filter events through shouldBlockTime()
4. Slice multi-day events into per-day segments (clamp to working hours)
5. For each business day in range:
   a. Start with full working hours as one free block
   b. If day == today:
      effectiveStart = max(workStart, now + buffer)
      if effectiveStart >= workEnd: skip day
   c. For each event on this day, sorted by start:
      - Clamp event start/end to working hours window
      - Subtract clamped interval from free blocks (split if needed)
   d. Filter out blocks < minimumSlotDuration (30 min)
6. Return [Date: [TimeSlot]] for non-empty days
```

**Multi-day event slicing:**
```swift
func sliceEventIntoDays(_ event: EKEvent) -> [(day: Date, start: Date, end: Date)] {
    var slices: [(Date, Date, Date)] = []
    let cal = Calendar.current
    var cursor = cal.startOfDay(for: event.startDate)
    while cursor < event.endDate {
        let nextDay = cal.date(byAdding: .day, value: 1, to: cursor)!
        let sliceStart = max(event.startDate, cursor)
        let sliceEnd = min(event.endDate, nextDay)
        slices.append((cursor, sliceStart, sliceEnd))
        cursor = nextDay
    }
    return slices
}
```

**Recurring events:** `predicateForEvents` automatically expands recurring events into individual occurrences. No manual recurrence walking needed.

### Time Formatting Rules

**Time display (shortest readable form):**
- On-the-hour: `9am`, `2pm` (drop `:00`)
- Has minutes: `9:30am`, `10:15am`
- Same AM/PM period: `9-10:30am` (omit suffix on start)
- Cross AM/PM: `9am-1pm`, `11:30am-12pm` (show both suffixes)
- 12pm = noon, 12am = midnight (not "noon"/"midnight" — breaks visual pattern)
- `11:30am-12pm` → both suffixes shown (AM→PM cross)
- `12-1pm` → same period, start suffix elided (both PM)

**Date header:** `EEE MMM d` format with `en_US_POSIX` locale → `Mon Mar 25:`, `Wed Apr 2:`

**No year displayed.** Chronological ordering handles December→January rollover.

**AvailabilityFormatter is a pure function** — takes `[Date: [TimeSlot]]` and settings, returns `String`. Clipboard write happens in AppDelegate.

### Settings Storage

Use `@AppStorage` directly in SwiftUI views — no `@Observable` wrapper needed at this scale.

| Key | Type | Default | Notes |
|---|---|---|---|
| `workingHoursStart` | Int | 540 (9:00) | **Minutes since midnight** — supports 8:30am (510) |
| `workingHoursEnd` | Int | 1020 (17:00) | Minutes since midnight |
| `workingDays` | [Int] | [2,3,4,5,6] | Swift Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat |
| `todayBufferMinutes` | Int | 60 | Preset options: 0, 30, 60, 120, 240 |
| `minimumSlotMinutes` | Int | 30 | Fixed for V1 |
| `defaultRangeMode` | String | "businessDays" | "thisWeek" or "businessDays" |
| `defaultBusinessDays` | Int | 5 | Slider 2-5, integer detents only |
| `showTimeZone` | Bool | false | Appends `(AEST)` etc. |
| `selectedCalendarIDs` | [String] | [] (all) | Empty = all calendars selected |
| `launchAtLogin` | Bool | false | Drives SMAppService |

**Validation on read:** Clamp all values to valid ranges when reading from UserDefaults. Example: `workingHoursStart` clamped to 0...1439, `defaultBusinessDays` to 2...5. Prevents crashes from manually edited plist.

**Stale calendar IDs:** Silently skip saved IDs that no longer match any EventKit calendar. If all saved IDs are stale, fall back to all calendars.

### Security

**Entitlements:**
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.personal-information.calendars</key>
<true/>
<!-- NO network entitlements — OS-enforced zero exfiltration -->
```

- **App Sandbox enabled** — no filesystem access outside container, no network
- **Hardened Runtime enabled** — required for notarization, prevents code injection
- **Zero third-party dependencies** — every dependency is a potential network vector
- **Auth status checked per-query** — handles mid-session revocation
- **Denied-permission alert debounced** — once per session, not per click

## Implementation Phases

### Phase 1: Scaffold + Menu Bar Presence

Create the Xcode project and get a working menu bar icon with left-click/right-click differentiation.

**Files:**
- `CalendarClickApp.swift` — `@main` App with `NSApplicationDelegateAdaptor`, `Settings` scene
- `AppDelegate.swift` — Creates `StatusItemController`, will later own the copy pipeline
- `Utilities/StatusItemController.swift` — `NSStatusItem` with `sendAction(on: [.leftMouseUp, .rightMouseUp])`, event-type branching
- `Assets.xcassets` — Template image: 18x18 @1x, 36x36 @2x, black + alpha only, `isTemplate = true`
- `Info.plist` — `LSUIElement = true`, `NSCalendarsFullAccessUsageDescription`
- `CalendarClick.entitlements` — App Sandbox + calendar entitlement

**Key pattern — opening Settings from NSMenu:**
```swift
NSApp.setActivationPolicy(.regular)
NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
NSApp.activate(ignoringOtherApps: true)
// Observe NSWindow.willCloseNotification to re-hide: NSApp.setActivationPolicy(.accessory)
```

**Acceptance criteria:**
- [ ] App launches with no Dock icon (`LSUIElement`)
- [ ] Menu bar icon visible with template image
- [ ] Left-click prints "copy triggered" to console
- [ ] Right-click shows NSMenu: Next week / Next fortnight / Next 30 days / --- / Settings... / Quit
- [ ] Settings... opens SwiftUI Settings window (empty for now)
- [ ] Quit terminates app
- [ ] App Sandbox + Hardened Runtime enabled in project settings

### Phase 2: EventKit Integration

Connect to the calendar system and fetch events.

**Files:**
- `Services/CalendarService.swift` — Singleton `EKEventStore`, `requestFullAccessToEvents`, calendar enumeration, async event fetching, `EKEventStoreChanged` observation with debounce
- `Models/TimeSlot.swift` — `struct TimeSlot { let start: Date; let end: Date; var duration: TimeInterval }`

**Acceptance criteria:**
- [ ] Requests calendar permission on first launch
- [ ] Checks `authorizationStatus(for: .event)` before every query
- [ ] Handles `.fullAccess`, `.denied`, `.notDetermined`, `.restricted` explicitly (switch, no default)
- [ ] Can enumerate all calendars (name, color via `CGColor`, identifier)
- [ ] Can fetch events for a given date range and calendar set asynchronously (`Task.detached`)
- [ ] Handles denied permission gracefully (debounced alert → System Settings)
- [ ] Observes `EKEventStoreChanged` with 500ms debounce, calls `store.reset()`

### Phase 3: Availability Calculation

The core logic — filter events, slice multi-day events, invert busy time into free slots.

**Files:**
- `Services/AvailabilityService.swift` — Event filtering (`shouldBlockTime`), multi-day slicing, free-slot inversion, per-day calculation

**Acceptance criteria:**
- [ ] Correctly identifies free slots between meetings
- [ ] Handles overlapping events (merge overlaps before subtracting)
- [ ] All-day events do NOT block time (skipped by `shouldBlockTime`)
- [ ] Declined and cancelled events excluded
- [ ] Events with `availability == .free` excluded
- [ ] Multi-day events sliced and clamped to each day's working hours
- [ ] Events starting before or ending after working hours clamped to window
- [ ] Today buffer applied correctly
- [ ] Filters out sub-30-minute gaps
- [ ] Skips non-working days
- [ ] "This week" auto-rolls to next week if current week is exhausted
- [ ] "Next N business days" includes today only if viable slots remain after buffer

### Phase 4: Text Formatting + Clipboard

Format slots as human-readable text. Formatter is pure — clipboard write happens in AppDelegate.

**Files:**
- `Services/AvailabilityFormatter.swift` — Pure function: `(slots: [Date: [TimeSlot]], showTimeZone: Bool) → String`

**Formatting rules:**
- Day header: `Mon Mar 25:` — `EEE MMM d` with `en_US_POSIX` locale
- Time: shortest form — `9am`, `9:30am`, `9-10:30am` (same period), `9am-1pm` (cross period)
- 12pm for noon, 12am for midnight
- `11:30am-12pm` shows both suffixes (AM→PM cross)
- `12-1pm` elides start suffix (both PM)
- Multiple slots: comma-separated — `9-10:30am, 2-3pm`
- Time zone (if enabled): `(AEST)` on its own line after last day
- Days with no availability: omitted
- English-only, `en_US_POSIX` locale, lowercase am/pm

**Clipboard write (in AppDelegate):** `NSPasteboard.general.clearContents()` then `NSPasteboard.general.setString(text, forType: .string)`

**Acceptance criteria:**
- [ ] Output matches format spec exactly
- [ ] All time formatting edge cases pass (30 unit tests from research)
- [ ] Time zone appended when setting enabled, using `TimeZone.current.abbreviation()`
- [ ] Formatter is pure (no side effects, no clipboard access)
- [ ] Clipboard write debounced (ignore clicks within 500ms of previous)

### Phase 5: Feedback — Checkmark + No-Availability

**Files:**
- `Utilities/StatusItemController.swift` — Add `flashCheckmark()` and `flashXMark()` methods

**Behavior:**
- **Successful copy:** Swap icon to `checkmark.circle.fill` SF Symbol (template) for 1.5s, then revert
- **No availability:** Swap icon to `xmark.circle` SF Symbol for 1.5s, then revert — **no macOS notification** (avoids notification permission entirely)
- **Click during animation:** Reset the 1.5s timer, recalculate fresh availability

```swift
func flashConfirmation(success: Bool) {
    let symbolName = success ? "checkmark.circle.fill" : "xmark.circle"
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    image?.isTemplate = true
    let original = statusItem.button?.image
    statusItem.button?.image = image
    animationTimer?.invalidate()
    animationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
        self?.statusItem.button?.image = original
    }
}
```

**Acceptance criteria:**
- [ ] Checkmark icon flashes on successful copy
- [ ] X-mark icon flashes when no slots found
- [ ] Icon reverts after ~1.5 seconds
- [ ] Clipboard unchanged when no slots found
- [ ] Click during animation resets timer and recalculates
- [ ] No notification permission required

### Phase 6: Settings Window

SwiftUI settings window accessible from right-click menu.

**Files:**
- `Models/AppSettings.swift` — `@AppStorage` key constants, validation helpers (clamp functions)
- `Views/SettingsView.swift` — Main settings layout with all controls
- `Views/CalendarPickerView.swift` — Calendar checklist with color dots, auto-refreshes on `EKEventStoreChanged`

**Settings layout:**
```
┌─ Settings ──────────────────────────────┐
│                                         │
│  Working Hours                          │
│  ┌────────┐    ┌────────┐              │
│  │ 9:00AM │ to │ 5:00PM │  (30-min)   │
│  └────────┘    └────────┘              │
│                                         │
│  Working Days                           │
│  [x] Mon [x] Tue [x] Wed [x] Thu       │
│  [x] Fri [ ] Sat [ ] Sun               │
│                                         │
│  Default Range                          │
│  ○ This week (Mon-Fri)                  │
│  ● Next [===|====] 5 business days      │
│                                         │
│  Today Buffer                           │
│  Minimum ┌──────────┐ before a slot     │
│          │  1 hour  │▼                  │
│          └──────────┘                   │
│  Options: None, 30 min, 1 hr, 2 hr, 4hr│
│                                         │
│  Calendars                              │
│  [x] 🔴 Work                           │
│  [x] 🔵 Personal                       │
│  [ ] 🟢 Birthdays                      │
│  [x] 🟡 Shared Team                    │
│                                         │
│  [x] Append time zone (AEST)           │
│  [x] Launch at login                   │
│                                         │
└─────────────────────────────────────────┘
```

**Changes from original plan:**
- Working hours picker uses 30-minute increments (minutes-since-midnight storage)
- Today buffer is a dropdown with presets (not free-form)
- Default range slider has discrete integer detents (2, 3, 4, 5)
- Settings are live (no Save button) — standard macOS convention
- Validate `workingHoursEnd > workingHoursStart` in the picker UI (end picker only shows times after start)

**Guard rails:**
- All calendars unchecked → treat as "all calendars selected" (same as empty `selectedCalendarIDs`)
- All working days unchecked → show inline warning, left-click produces no-availability feedback
- `workingHoursStart >= workingHoursEnd` → prevented by UI picker constraints

**Acceptance criteria:**
- [ ] All settings persist across app restarts via `@AppStorage`
- [ ] Working hours picker uses 30-minute increments
- [ ] Default range slider snaps to integers (2-5) with "This week" radio toggle
- [ ] Today buffer dropdown with preset options
- [ ] Calendar list auto-populates from EventKit, refreshes on `EKEventStoreChanged`
- [ ] Calendar colors displayed (convert `CGColor` → SwiftUI `Color`)
- [ ] Time zone toggle shows `TimeZone.current.abbreviation()`
- [ ] Launch at login uses `SMAppService.mainApp` — wraps register/unregister in do/catch, verifies `.status` after
- [ ] All values validated/clamped on read

### Phase 7: Polish + Edge Cases

- [ ] Menu bar icon: SF Symbol `calendar` or custom template image
- [ ] `SMAppService.mainApp.register()` / `.unregister()` with error handling + status verification
- [ ] Handle calendar permission revocation mid-session (re-check before query, debounced alert)
- [ ] Handle `EKEventStoreChanged` to refresh calendar list + invalidate cached data
- [ ] Handle system time zone change (re-read `TimeZone.current` on each click, not cached)
- [ ] DST transitions: use `Calendar.date(byAdding:)` for all date math, never raw hour arithmetic
- [ ] Debounce rapid clicks (ignore within 500ms of previous)

## Acceptance Criteria

### Functional

- [ ] Left-click menu bar icon → availability copied to clipboard in <200ms
- [ ] Right-click → menu with Next week / Next fortnight / Next 30 days / Settings / Quit
- [ ] Output format matches spec: `Mon Mar 25: 9-10:30am, 2-3pm`
- [ ] Reads from all calendars added in macOS System Settings
- [ ] Declined, cancelled, and free-status events excluded from busy time
- [ ] Settings window configures: working hours (30-min granularity), working days, default range, today buffer, calendars, time zone, launch at login
- [ ] Checkmark flash on successful copy, X-mark flash on no availability
- [ ] "This week" auto-rolls forward when current week is exhausted

### Non-Functional

- [ ] Runs on macOS 14+ (Sonoma and later)
- [ ] No Dock icon (pure menu bar app, `LSUIElement = true`)
- [ ] App Sandbox enabled, no network entitlements
- [ ] Hardened Runtime enabled
- [ ] Zero third-party dependencies
- [ ] Memory footprint under 30 MB
- [ ] Calendar queries complete in under 500ms (async, off main thread)

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| User denies calendar permission | Debounced alert (once per session) with button to open System Settings > Privacy > Calendars |
| Permission revoked mid-session | Check `authorizationStatus` before every query, not just at startup |
| EventKit returns stale data | Observe `EKEventStoreChanged` with 500ms debounce, call `store.reset()`, re-fetch on next click |
| All-day events misidentified | Check both `isAllDay` flag AND midnight-to-midnight pattern |
| Multi-day events not sliced | Slice into per-day segments, clamp to working hours window |
| Stale calendar IDs in UserDefaults | Silently skip IDs not found in current calendar list, fall back to all calendars |
| User has no calendars synced | Show "No calendars found" in settings, guide to System Settings > Internet Accounts |
| Settings window appears behind other apps | `NSApp.activate(ignoringOtherApps: true)` + temporary `.regular` activation policy |
| DST causes wrong slot times | All date math via `Calendar.date(byAdding:)`, never raw arithmetic |
| Rapid double-click | Debounce clicks within 500ms |
| Time zone changes while app running | Read `TimeZone.current` fresh on each click |
| SMAppService registration fails | Wrap in do/catch, verify `.status` after, update UI to reflect actual state |

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-03-24-calendar-click-brainstorm.md](docs/brainstorms/2026-03-24-calendar-click-brainstorm.md) — Key decisions carried forward: EventKit for all calendars, grouped-by-day abbreviated format, configurable default range (2-5 business days), today buffer, calendar selection checklist
- Apple EventKit: https://developer.apple.com/documentation/eventkit
- Apple NSStatusItem: https://developer.apple.com/documentation/appkit/nsstatusitem
- Apple SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- WWDC 2023 "Discover Calendar and EventKit" session
- Itsycal (open source macOS menu bar calendar): https://github.com/sfsam/Itsycal — production EKEventStore patterns
- MeetingBar (open source menu bar app): https://github.com/leits/MeetingBar — modern async/Combine EventKit patterns
- Peter Steinberger on Settings window from menu bar: https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items
- Bjango menu bar icon sizing guide: https://bjango.com/articles/designingmenubarextras/

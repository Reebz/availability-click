# Calendar Click — Brainstorm

**Date:** 2026-03-24
**Status:** Refined

## What We're Building

A native macOS menu bar app that copies your calendar availability to the clipboard in one click. You paste it into an email or chat — no Calendly links, no AI agents, just a clean human-written-looking list of free slots.

**Core interaction:**
- **Left-click** the menu bar icon → availability copied to clipboard, brief confirmation shown
- **Right-click** → menu with extended ranges: Next week, Next fortnight, Next 30 days
- **Cmd+V** into any email or chat

## Why This Approach

Scheduling tools like Calendly feel impersonal for executive meetings. Typing availability manually is tedious and error-prone. This sits in between — effortless but still feels like you wrote it yourself.

Native macOS + EventKit means it reads every calendar added in System Settings (iCloud, Google, Outlook, Exchange) without needing separate OAuth flows or API keys.

## Key Decisions

### 1. Calendar Source: EventKit (all calendars)
Read from the macOS EventKit API. Users pick which calendars count as "busy" in settings (checklist). This covers Apple Calendar, Google, Outlook, and anything else synced to the Mac.

### 2. Output Format: Grouped by day, abbreviated
```
Mon Mar 25: 9-10:30am, 2pm-3pm
Tue Mar 26: 10am-12pm
Wed Mar 27: 9am-5pm
Thu Mar 28: 1-3:30pm
```
- Fully free days show the full working hours range (e.g., `Wed Mar 27: 9am-5pm`)
- Time ranges use shortest readable form (9am not 9:00am, but 9:30am keeps the minutes)
- No header text — just the slots, ready to paste
- Time zone optionally appended at the end (e.g., `(AEST)`) — configurable in settings

### 3. Default Range: Configurable (2-5 business days)
Settings has a slider from 2 to 5 business days for the left-click default. Can also be set to "This week" (Mon-Fri of current week). Right-click menu always offers next week / fortnight / 30 days regardless of this setting.

### 4. Working Hours: User-configured
- Configurable start and end time (e.g., 9am-5pm)
- Configurable which days are working days (e.g., Mon-Fri)

### 5. Today Buffer
Configurable minimum lead time for today's slots (default: 1 hour). If it's 2pm and buffer is 1 hour, earliest today slot shown is 3pm.

### 6. Minimum Slot Duration: 30 minutes
Free gaps shorter than 30 minutes between meetings are ignored.

### 7. Calendar Selection
Settings shows a checklist of all calendars from EventKit. Only checked calendars block time. Unchecked calendars (e.g., "Birthdays") are ignored.

### 8. Time Zone Display
Configurable toggle in settings. When enabled, appends the local time zone abbreviation (e.g., `(AEST)`) after the last line of output.

### 9. Confirmation Feedback
Left-click: menu bar icon briefly flashes a checkmark, then reverts. No notification banner — minimal and non-intrusive.

### 10. No Availability
If no free slots exist in the selected range, show a macOS notification ("No free slots found") and leave the clipboard unchanged.

## Technical Approach

- **Language:** Swift
- **UI Framework:** SwiftUI (for settings window), AppKit (for menu bar integration)
- **Calendar API:** EventKit / EventStore
- **Distribution:** Direct download (and potentially Mac App Store later)
- **Permissions:** Calendar access (EventKit entitlement)
- **Data storage:** UserDefaults for settings (working hours, buffer, selected calendars, default range)

## Scope — V1

| In | Out |
|----|-----|
| Menu bar icon with left-click copy | Visual calendar preview / popover |
| Right-click extended range menu | Drag-and-drop into emails |
| Settings window (hours, days, buffer, calendars, default range) | iCal file generation |
| Grouped-by-day text format | Multiple output format options |
| EventKit integration (all calendar providers) | Direct Google/Outlook API integration |
| Launch at login option | Keyboard shortcut to trigger copy |

## Open Questions

None — all key decisions resolved during brainstorm.

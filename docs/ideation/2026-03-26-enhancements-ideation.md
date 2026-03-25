---
date: 2026-03-26
topic: enhancements
focus: what else can I do to enhance this?
---

# Ideation: Calendar Click Enhancements

## Codebase Context

- Native macOS menu bar app (Swift 6, SwiftUI + AppKit, macOS 14+)
- Clean architecture: CalendarService → AvailabilityService → AvailabilityFormatter
- 71 tests across 6 suites, zero dependencies, App Sandbox
- V1 complete: left-click copy, right-click ranges, settings, calendar selection, feedback animation

## Ranked Ideas

### 1. Global Keyboard Shortcut
**Description:** Configurable system-wide hotkey (Ctrl+Shift+C) triggers default copy. No mouse needed.
**Rationale:** Collapses interaction cost to near-zero. Every successful menu bar utility has a hotkey.
**Downsides:** Global hotkey conflict avoidance.
**Confidence:** 95%
**Complexity:** Low
**Status:** Explored → docs/brainstorms/2026-03-26-v1.1-enhancements-requirements.md

### 2. Smart Slot Rounding
**Description:** Snap slot boundaries to configurable increments (5/10/15/30 min). 10:47am becomes 11:00am.
**Rationale:** Eliminates robotic-looking times nobody would schedule at.
**Downsides:** Hides genuinely available minutes.
**Confidence:** 90%
**Complexity:** Low
**Status:** Explored

### 3. Expose Minimum Slot Duration Setting
**Description:** Add UI for the existing hidden minimumSlotMinutes setting. Half-built already.
**Rationale:** Users with 15-min coffee chats see "no availability" incorrectly. ~20 line change.
**Downsides:** None.
**Confidence:** 95%
**Complexity:** Trivial
**Status:** Explored

### 4. Preview Popover Before Copy
**Description:** Option+click shows formatted text in a popover before clipboard write. Verify before sending.
**Rationale:** Catches wrong week, stale data, unwanted gaps before they reach the recipient.
**Downsides:** Second interaction path to maintain.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Explored

### 5. Recipient Timezone Conversion
**Description:** Timezone picker in preview popover converts output to recipient's local time.
**Rationale:** Eliminates mental math for cross-timezone scheduling — Calendly's strongest feature.
**Downsides:** Timezone picker UI complexity.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Explored

### 6. Format Templates
**Description:** Plain text (default) + Markdown bullet list. Selectable in Settings or popover.
**Rationale:** Output native to destination: plain for SMS/email, Markdown for Slack/Notion.
**Downsides:** Two formats to maintain and test.
**Confidence:** 80%
**Complexity:** Medium
**Status:** Explored

### 7. Availability Diffing
**Description:** Track last-copied snapshot, highlight changes on next copy. Strikethrough removed, bold new.
**Rationale:** Most novel idea. "One update to my availability" becomes automatic.
**Downsides:** Needs state; diff formatting complexity; unfamiliar notation.
**Confidence:** 70%
**Complexity:** Medium-High
**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Visual block grid image | Too expensive; text better in email/chat |
| 2 | Interactive HTML slot picker | Data URIs stripped; rebuilds Calendly |
| 3 | Auto-paste into text field | Accessibility permission; fragile |
| 4 | Contextual scheduling detection | Invasive; high false positives |
| 5 | Drag-and-drop from icon | Not natural for menu bar icons |
| 6 | Dual-clipboard ICS | Rare for recipients to paste into calendar |
| 7 | Calendar profile switching | Niche; existing selection approximates it |
| 8 | "Busy with" context labels | Privacy risk; complicates architecture |
| 9 | Business days slider >5 | Already solvable via right-click |
| 10 | Better no-availability feedback | Too small standalone |
| 11 | Proactive clipboard refresh | Risky side effects |
| 12 | Scheduling intent detection | Same as contextual detection |
| 13 | Kill the click / proactive loading | Over-engineering |
| 14 | Clipboard history ring | Lower leverage than top 7 |
| 15 | Multi-person calendar overlay | High complexity; V3 |
| 16 | Specific-date picker | Significant UI for niche use |
| 17 | Duration-first output | Niche reframe |

## Session Log
- 2026-03-26: Initial ideation — 40 raw ideas (5 agents), 24 after dedupe, 7 survived
- 2026-03-26: Ideas 1-6 explored via /ce:brainstorm → requirements doc created

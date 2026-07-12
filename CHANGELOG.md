# Changelog

All notable changes to Availability Click are documented here.

## v1.2.1

- The app icon now appears in the Cmd+Tab switcher and the Dock while the Settings window is open. Earlier builds bundled no icon, so it showed up blank there.

## v1.2.0

The first update since launch, gathering everything built after v1.0.0.

New:

- A right-click "Copy 3 Suggested Times" action writes a short numbered proposal of well-spread times instead of the full grid.
- The global hotkey now fires on a fresh install with no extra permissions. Tap it to copy, hold it to open the preview.
- Copied text can carry an optional "as of" timestamp, and the timezone label now reads as a plain zone name with a single GMT offset ("Berlin Time, GMT+2").
- The menu bar icon flags when a time you copied is no longer free, and confirms before overwriting your own unpasted output once availability has changed.
- An optional per-event buffer pads meetings so offered slots never start or end flush against one.
- Shortcuts and Spotlight can now read your availability through two App Intents, one returning formatted text and one returning structured start and end slots, under a documented automation contract that later versions only add to.
- Every copy outcome is announced to VoiceOver, and copied output now carries rich text with bold day labels in Mail, Notion, and Google Docs.

Improved:

- Output follows your locale, including 24-hour time where the locale uses it.
- A failed click now says why: no calendar access, no calendars available, or no free slots in the range.
- A first-run coach shows the click, right-click, and Option-click gestures once, and the menu carries the running version and a Check for Updates link.
- Deselecting your last calendar is no longer possible, and a fully stale calendar selection stops rather than silently widening to every calendar.

Still App-Sandboxed with calendar access as the only entitlement. No network, no analytics, no tracking. Signed with a Developer ID and notarized by Apple.

## v1.0.0

First public release.

- Menu bar app that reads your calendars and copies your availability to the clipboard in one click.
- Left-click copies the default range. Right-click picks Next week, Next fortnight, or Next 30 days.
- Option+click opens a preview with a timezone picker and a plain-text / Markdown toggle.
- Ctrl+Shift+C copies from anywhere, without touching the mouse (configurable).
- Reads every calendar synced to your Mac. Skips declined, cancelled, free, and all-day events.
- Configurable working hours, working days, default range, today buffer, calendar selection, slot rounding, minimum slot duration, output format, and time zone.
- App-Sandboxed with calendar access as the only entitlement. No network, no analytics, no tracking.
- Signed with a Developer ID and notarized by Apple.

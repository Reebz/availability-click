
# <img src="site/images/app-icon.png" width="80" height="80"> Availability Click

Share your calendar availability in one click. A macOS menu bar app that reads your calendars and copies formatted free slots to paste into any email or chat.

[Download the app](https://github.com/Reebz/availability-click/releases)

```
Mon Mar 30: 9-10:30am, 2-4pm
Tue Mar 31: 10am-12pm
Wed Apr 1: 9am-5pm
Thu Apr 2: 1-3:30pm
Fri Apr 3: 9-11am, 3-5pm
```

## Why this exists

Calendly feels too impersonal for certain meetings. Typing out your availability by hand is tedious and error-prone. This sits in between -- effortless but still feels like you wrote it yourself.

I found myself manually typing "I'm free Tuesday 2-4 and Wednesday morning" into emails multiple times a day. That's a copy-paste problem, and the calendar already has the answer. So I built a button that does the work.

No links for your counterpart to click. No accounts for them to create. No bots. Just a clean message that reads like a human wrote it -- because the human decided to send it.


# Installation

### Download

[Download here](https://github.com/Reebz/availability-click/releases). Open the app and grant calendar access. That's it.

Requires macOS 14 (Sonoma) or later.

> Apple may give a warning about opening a downloaded app. To launch, right-click and select Open.


## How to Use

1. Launch Availability Click from Applications
2. Grant calendar access when prompted
3. Left-click the calendar icon in the menu bar -- your availability is copied to the clipboard
4. Cmd+V into any email, Slack message, or chat

Right-click the menu bar icon for extended date ranges, Settings, and Quit.


# Features

- One click to copy -- or use the keyboard shortcut (Ctrl+Shift+C)
- Reads all calendars synced to your Mac (iCloud, Google, Outlook, Exchange)
- Smart time formatting -- "9-10:30am" not "9:00am-10:30am"
- Privacy-first -- no accounts, no network access, no analytics

**Menu Bar**
- Left-click copies availability for your default range
- Right-click for Next week, Next fortnight, Next 30 days
- Option+click opens a preview popover before copying
- Checkmark flash confirms the copy; X-mark if no slots found

**Settings**
- Working hours with 30-minute granularity (e.g., 8:30am-5pm)
- Working days (any combination, not just Mon-Fri)
- Default range: "This week" or "Next 2-5 business days" (slider)
- Today buffer: minimum lead time before showing a slot (30 min to 4 hours)
- Calendar selection: choose which calendars count as "busy"
- Slot rounding: snap times to clean 5/10/15/30-minute boundaries
- Minimum slot duration: hide gaps shorter than 15/30/45/60 minutes
- Output format: Plain text or Markdown
- Time zone toggle with GMT offset
- Keyboard shortcut: configurable global hotkey
- Launch at login

**Preview Popover (Option+click)**
- See your formatted availability before it hits the clipboard
- Timezone picker with search -- convert times to your recipient's local time
- Format toggle -- switch between plain text and Markdown
- Copy button sends the displayed text to the clipboard

**Smart Filtering**
- Declined meetings don't block your time
- Cancelled events are excluded
- Events marked "free" (focus time, etc.) are excluded
- All-day events don't block time slots
- "This week" auto-rolls to next week on Friday evening and weekends


## Privacy Policy

Availability Click does not collect, store, or transmit personal data.

The app:
- Does not include analytics
- Does not include tracking
- Does not make any network connections
- Does not share data with third parties
- Does not store user data on external servers

All calendar data is read locally via Apple's EventKit framework and never leaves your Mac. The app runs inside the macOS App Sandbox with calendar access as the only entitlement -- no network permissions are granted.

No data is retained by the developer.


## Technical Details

- **Language:** Swift 6
- **Frameworks:** SwiftUI, AppKit, EventKit, Combine, ServiceManagement
- **Dependencies:** Zero third-party dependencies
- **Build tool:** XcodeGen
- **Deployment target:** macOS 14.0 (Sonoma)
- **Tests:** 89 tests across 8 suites (Apple Testing framework)
- **Security:** App Sandbox, Hardened Runtime, Developer ID signed


## Support

If you find Availability Click useful, consider [buying me a coffee](https://buymeacoffee.com/reebz).<br>
<a href="https://www.buymeacoffee.com/reebz" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>


## License

[MIT](LICENSE)

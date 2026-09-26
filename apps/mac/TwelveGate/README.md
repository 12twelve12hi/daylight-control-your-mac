# TwelveGate — the Mac side of Twelve

A small menu bar app (AppKit, no SwiftUI, no dependencies) that keeps a
WebSocket open to the Twelve server on this Mac and enforces whatever lock mode
the server sends: a full-screen shield, a meeting allowlist, or nothing. It also
shows the check-in countdown banner and offers the emergency exit.

The server is the source of truth (see `../../../SPEC.md`). The app only
sends `hello`, `emergency.unlock`, `checkin.snooze`, `mac.foreground` and
`ping`, and only reads `state.lockMode`, `state.shield`, `state.banner`,
`state.allowlist`, `state.meeting`, `state.emergencyUntil` and the check-in
timestamps.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools with Swift 5.9 or newer (`xcode-select --install`).
- The Twelve server installed on the same Mac; it writes the pairing token to
  `~/.twelve/config.json`.

## Build

```sh
cd apps/mac/TwelveGate
./scripts/bundle.sh
```

This runs `swift build -c release`, assembles `build/TwelveGate.app` with
`Resources/Info.plist`, and ad-hoc signs it. The script prints the bundle path.

For a quick development run without a bundle, `swift build` and start
`.build/debug/TwelveGate` from a terminal; log lines go to stderr.

## Install

```sh
cp -R build/TwelveGate.app /Applications/

mkdir -p ~/Library/LaunchAgents ~/Library/Logs/twelve
sed "s|__HOME__|$HOME|g" launchd/com.twelve.gate.plist \
  > ~/Library/LaunchAgents/com.twelve.gate.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.twelve.gate.plist
```

The LaunchAgent starts the app at login and restarts it if it exits
(`KeepAlive`). Output lands in `~/Library/Logs/twelve/gate.log`.

To restart after rebuilding:

```sh
launchctl kickstart -k gui/$UID/com.twelve.gate
```

## Configuration

- `~/.twelve/mac.json` — optional. `{"serverUrl": "ws://127.0.0.1:7712/ws"}`
  is the default when the file is missing.
- `~/.twelve/config.json` — written by the server. The app reads
  `pairing.token` from it and connects to `serverUrl?token=<token>`. The token
  is re-read before every connection attempt, so the app can be running before
  the server has paired for the first time.

The menu bar item is titled **12**. Its menu shows the connection and phase, the
next check-in time, and offers **Open Daylight pairing page**
(`http://127.0.0.1:7712/pair`), **Open dashboard**, **Reconnect** and **Quit**.

## How the lock behaves

| `lockMode` | What the app does |
|------------|-------------------|
| `shield`   | A borderless, opaque window at the shielding window level covers every display and stays there across Spaces and full-screen apps. The Dock and menu bar are hidden and Cmd-Tab, Force Quit, Hide and Log Out are disabled (Apple's kiosk presentation options). If another app comes forward the gate re-activates itself after 150 ms; a 2 s timer re-orders the shields front as a backstop. The shield shows the server's title and body, the clock, the connection status, the current meeting (if any) and the emergency exit. |
| `allowlist` | No shield. A small floating HUD in the top-right says "Meeting mode — only allowlisted apps" with the meeting title. Whenever a regular app that is not on `state.allowlist` becomes active it is hidden and the HUD flashes "<name> is not on the meeting allowlist". Every activation is reported to the server as `mac.foreground` for the session log. A 2 s poll of the frontmost app backs up the notification. |
| `free`     | Shields and HUD are removed and the presentation options are reset. |

`state.banner` is independent of the lock mode: when present, a floating
non-activating panel at the top-center of the main screen shows the banner text
and a live m:ss countdown to `banner.endsAt`, plus a **Snooze 15 min** button
when `banner.canSnooze` is true. Clicking it sends `checkin.snooze`.

**Quit** is disabled while the mode is `shield` or `allowlist`, and
`applicationShouldTerminate` refuses to quit in those modes, unless an
emergency unlock is in progress. If the server becomes unreachable the app
keeps its last mode and shows "Reconnecting…" on the shield.

## Emergency unlock

At the bottom of the shield: **Hold for 30 s to unlock in an emergency**.
Press and hold the button; a progress bar fills over 30 seconds. Releasing or
dragging out early resets it. After a full hold a text field appears
("Why? (at least 10 characters)") with an **Unlock for 30 minutes** button that
is enabled once the reason is at least 10 characters. Clicking it sends
`emergency.unlock` with the reason; the server switches the Mac to `free` for
30 minutes, logs the event on the session (or the day log), and returns the
previous mode afterwards.

The hold time and the 30 minutes are the server's `emergency.holdSeconds` /
`emergency.unlockMinutes` defaults; the app hard-codes the same defaults.

## What can and cannot be enforced

This is a firm gate with a friction exit, not a security boundary:

- Spotlight, notification banners, system alerts, the password dialog for
  `sudo`-like prompts and the Screen Time / lock screen UI can appear above the
  shield. The app re-activates itself and re-orders the shields front within
  about two seconds; it does not fight system UI.
- The kiosk presentation options only apply while TwelveGate is the active
  app. The app switches itself to a regular activation policy while shielded so
  they take effect, and back to a menu bar (accessory) app otherwise.
- `killall TwelveGate` from a terminal that was already open, or a reboot,
  ends the shield. launchd restarts the app and the server sends the mode
  again.
- No Accessibility, Screen Recording or other TCC permission is needed and none
  is requested.
- Allowlist mode hides apps; it does not block them from running in the
  background.

## Uninstall

```sh
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.twelve.gate.plist
rm ~/Library/LaunchAgents/com.twelve.gate.plist
rm -rf /Applications/TwelveGate.app
```

If the app is shielding at that moment, `bootout` will stop it anyway: launchd
sends SIGTERM, which the app does not intercept.

## Files

```
Package.swift                       SwiftPM manifest (macOS 13+, no dependencies)
Sources/TwelveGate/main.swift       NSApplication setup
Sources/TwelveGate/AppDelegate.swift    settings, status item and menu, Quit rule
Sources/TwelveGate/Protocol.swift       Codable mirror of the protocol subset
Sources/TwelveGate/ServerConnection.swift   WebSocket client with reconnect
Sources/TwelveGate/LockController.swift     applies a StateSnapshot
Sources/TwelveGate/ShieldWindow.swift       shield window, content, emergency unlock
Sources/TwelveGate/BannerPanel.swift        check-in countdown panel
Sources/TwelveGate/HUDPanel.swift           meeting-mode HUD
Sources/TwelveGate/HoldButton.swift         press-and-hold control
Resources/Info.plist                bundle metadata (LSUIElement, local networking)
scripts/bundle.sh                   build + wrap into build/TwelveGate.app
launchd/com.twelve.gate.plist       LaunchAgent template (__HOME__ placeholder)
```

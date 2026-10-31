# TomatoTime

A small macOS menu bar pomodoro timer. Shows the countdown in the menu bar, pauses
music and videos (Music, Spotify, browsers and more) when a timer goes off, and suggests a break activity.

## Build

Needs macOS 13+ and the Xcode command-line tools (`xcode-select --install`).

```bash
./build.sh run
```

This builds `build/Pomodoro.app` and launches it. Pick the "Try it (10 sec)" style first to
check the chime and music pausing.

## Styles

| Style | Focus / short break | Rounds | Long break |
|---|---|---|---|
| Classic | 25 / 5 min | 4 | 15 min |
| Sprint | 15 / 3 min | 4 | 10 min |
| Deep work | 50 / 10 min | 2 | 25 min |
| Flow | 90 / 20 min | 2 | 30 min |
| Custom | your own | your own | your own |
| Try it | 10 / 5 sec | 2 | 8 sec |

Pick **Custom** in the menu to set the focus, short break and long break lengths (in minutes) and the number of rounds.

## Control it from elsewhere

- **Global hotkey:** `⌃⌥T` starts and pauses the timer from any app. In the menu, click the shortcut to record a different one (it needs at least one of ⌃ ⌥ ⌘; Esc cancels), use Reset to go back to `⌃⌥T`, or switch the hotkey off.
- **URL scheme:** `open tomatotime://startStop` (also `start`, `pause`, `skip`, `reset`), handy for Shortcuts, Raycast or a script.
- **Event log:** every start, pause, skip, reset and finished round is appended as one JSON line to `~/Library/Logs/TomatoTime/events.log`.

## Notes

- macOS asks once for permission to control Music and Spotify, and once for notifications.
- "Pause browsers and other apps too" (on by default) sends the Play/Pause media key, but only if the Mac is still producing sound after Music/Spotify were paused. Needs Accessibility permission. Resumes with the same key when the next focus round starts.
- Ad-hoc signed only: fine on your own Mac, not distributable.

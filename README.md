# TomatoTime

A small macOS menu bar pomodoro timer. Shows the countdown in the menu bar, pauses
Music and Spotify when a timer goes off, and suggests a break activity.

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
| Try it | 10 / 5 sec | 2 | 8 sec |

## Notes

- macOS asks once for permission to control Music and Spotify, and once for notifications.
- "Also pause browsers and other apps" sends the Play/Pause media key. It is a toggle, so it
  can start playback if nothing was playing. Off by default.
- Ad-hoc signed only: fine on your own Mac, not distributable.
- Written without access to a Mac or Swift toolchain, so it had not been compiled when first committed.

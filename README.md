# Screenshot Archive

A tiny native Mac app for keeping your screenshots folder tidy.

Open **Screenshot Archive.app** to preview files, pick a source folder and age
cutoff, toggle monthly `YYYY-MM` archive folders or hourly cleanup, or click
**Clean Up Now** (with one-click **Undo**). The default cutoff is three days.
Click **Allow** when macOS requests folder access.

## The rule

- Defaults to your macOS `com.apple.screencapture` location, or `~/Documents/Screenshots` if unset, and can be changed in the app.
- Moves top-level regular files named `Screenshot …` into `Archive` (or `Archive/YYYY-MM` when monthly organization is enabled).
- Uses the last modification time, so recently edited screenshots stay put.
- Offers 1, 3, 7, 14, or 30 days; one day means 24 hours.
- Keeps original filenames and skips names already in Archive.
- Excludes screen recordings, other filenames, subfolders, and symbolic links.
- Nothing is deleted or overwritten. Archiving tidies the folder; it does not free disk space.

Give a screenshot a descriptive name without the `Screenshot ` prefix to keep
it in the top-level folder permanently. To restore an archived screenshot,
click **Undo** right after a manual cleanup, or move it back and rename it.

## Automatic cleanup

The app's switch manages a macOS LaunchAgent. When enabled, it checks at login
and every hour while logged in and awake. It runs quietly when the app window
is closed, and records the last run time, moved count, and any error so the UI
can surface issues immediately.

- App and source: `~/DevPkgs/ScreenshotArchive`
- Schedule: `~/Library/LaunchAgents/com.jmitch.screenshot-archive.plist`
- Log: `~/Library/Logs/ScreenshotArchive.log` (automatically trimmed; quiet on no-op runs)
- Preferences: macOS defaults for `com.jmitch.screenshot-archive.helper`

Folder permissions are managed under System Settings > Privacy & Security >
Files and Folders > Screenshot Archive.

## Build & Test

Uses SwiftUI, AppKit, and Foundation, with no third-party dependencies.
Requires Xcode command-line tools. Targets Apple silicon and macOS 13 or newer.

```sh
cd "$HOME/DevPkgs/ScreenshotArchive"
/bin/zsh -f test.sh
/bin/zsh -f build.sh
open "Screenshot Archive.app"
```

### Preserving folder permission across rebuilds

By default `build.sh` ad-hoc signs (`-`), which changes the app's code signature
on every rebuild and may cause macOS to re-prompt for Documents access. To avoid
re-prompting, create a self-signed Code Signing certificate in Keychain Access
(e.g. `Screenshot Archive Dev`) and pass it via `SIGN_IDENTITY`:

```sh
SIGN_IDENTITY="Screenshot Archive Dev" /bin/zsh -f build.sh
```

Turn automatic cleanup off and quit the app before rebuilding.

## Disable from Terminal

The app's automatic-cleanup switch is the easiest way. Alternatively:

```sh
launchctl bootout "gui/$(id -u)/com.jmitch.screenshot-archive"
rm -f "$HOME/Library/LaunchAgents/com.jmitch.screenshot-archive.plist"
```

Archived screenshots stay in `Archive`.

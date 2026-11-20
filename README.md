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

## Daily object storage backups

Open **Backups…** to save snapshots to an existing S3-compatible bucket. The
app signs and uploads requests directly using macOS frameworks.

1. Enter the bucket, signing region, and optional object key prefix. For Amazon
   S3, leave **Endpoint** blank and use the bucket's region. For Cloudflare R2,
   use your account's S3 API endpoint and region `auto`. Other providers can
   use an HTTPS endpoint that accepts path-style S3 requests.
2. Enter an access key ID and secret with `s3:PutObject` permission for that
   prefix, then click **Save Destination**. The app stores the secret in macOS
   Keychain. The endpoint, bucket, prefix, region, and key ID are saved in app
   preferences. [Amazon S3 permissions](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
   · [Cloudflare R2 endpoints and regions](https://developers.cloudflare.com/r2/api/s3/api/)
3. Click **Back Up Now** for an immediate snapshot, or enable **Back up daily
   at 8 PM**. The daily schedule uses local time and runs while you are logged
   in, even with the window closed. If your Mac sleeps through the scheduled
   time, launchd runs the backup on wake. The Backups window and app log show
   the outcome.

Each successful upload creates a uniquely named, dated ZIP. It contains regular
files named `Screenshot …` in the selected folder, `Archive`, and
`Archive/YYYY-MM`, preserving their relative paths. An empty selection skips
the upload. Each run needs temporary disk space for one full ZIP and supports
ZIPs up to 5 GiB. Snapshots accumulate until your bucket's retention policy or
an administrator removes them.

To restore, download the desired ZIP from your bucket and expand it in a new
folder. Turn off daily backups in **Backups…** to stop future uploads. The
backup LaunchAgent is `~/Library/LaunchAgents/com.jmitch.screenshot-archive.backup.plist`.

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

## Version history and publishing

In a new clone, enable automatic publishing once with `git config --local core.hooksPath .githooks`. Each commit pushes its branch to `origin`. When changes reach `main`, the publisher updates both version fields in `Info.plist`, adds release notes, and pushes the release commit and its `vX.Y.Z` tag together. GitHub Actions also tests and builds pushes to `main` and versions changes made through GitHub or a clone without hooks. [Changelog](CHANGELOG.md)

Commit subjects supply the release notes. Use `feat: …` for a minor version, a type ending in `!` or a `BREAKING CHANGE:` footer for a major version, and any other subject for a patch. For a change with several release notes, put each on a separate `Changelog: …` line in the commit body. A batch of unpublished commits gets one version using the largest applicable bump and includes notes from each change.

If a push fails, the commit stays local. After reconnecting or reconciling a remote update, rerun `./scripts/publish.sh` to publish it.

## Disable from Terminal

The app's automatic-cleanup switch is the easiest way. Alternatively:

```sh
job="gui/$(id -u)/com.jmitch.screenshot-archive"
launchctl bootout "$job"
if launchctl print "$job" >/dev/null 2>&1; then
  echo "Hourly cleanup is still loaded."
elif [ "$?" -eq 113 ]; then  # launchctl confirmed the service is absent
  rm -f "$HOME/Library/LaunchAgents/com.jmitch.screenshot-archive.plist"
else
  echo "Could not verify the job status. The schedule file was kept."
fi
```

Archived screenshots stay in `Archive`.

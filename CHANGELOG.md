# Changelog

## 1.3.0 — 2026-11-20

- Add inline thumbnails, Quick Look previews, and one-click Keep & Rename in the preview list.
- Detect custom macOS screenshot prefixes, match supported image capture formats, and organize existing flat Archive files into YYYY-MM folders.
- Show Archive file count and on-disk size, add optional debounced failure notifications for hourly cleanup, and harden refresh/Undo safety.
- Replace the app icon with an original vector icon, add Desktop and Downloads usage descriptions, add MIT license, and support --universal and --install in build.sh.

## 1.2.0 — 2026-11-20

- Back up current and archived screenshots to an S3-compatible bucket on demand or daily at 8 PM. Restore a snapshot by expanding its dated ZIP.
- Store the backup secret in macOS Keychain and report the outcome of each backup in the app.
- Show when an hourly cleanup schedule needs repair and preserve screenshots added to an archive folder during Undo.
- Automatically push completed commits and publish app versions, Git tags, and changelog entries when changes reach main.

## 1.1.0 — 2026-11-20

- Preview and archive older screenshots with optional monthly folders, hourly cleanup, and one-click undo.

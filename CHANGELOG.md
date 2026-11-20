# Changelog

## 1.2.0 — 2026-11-20

- Back up current and archived screenshots to an S3-compatible bucket on demand or daily at 8 PM. Restore a snapshot by expanding its dated ZIP.
- Store the backup secret in macOS Keychain and report the outcome of each backup in the app.
- Show when an hourly cleanup schedule needs repair and preserve screenshots added to an archive folder during Undo.
- Automatically push completed commits and publish app versions, Git tags, and changelog entries when changes reach main.

## 1.1.0 — 2026-11-20

- Preview and archive older screenshots with optional monthly folders, hourly cleanup, and one-click undo.

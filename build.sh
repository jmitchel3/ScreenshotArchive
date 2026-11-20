#!/bin/zsh -f
set -eu
cd -- "${0:A:h}"

archive_app="$PWD/Screenshot Archive.app"
sign_identity="${SIGN_IDENTITY:--}"
archive_build=$(/usr/bin/mktemp -d /private/tmp/screenshot-archive-build.XXXXXX)
trap '/bin/rm -rf -- "$archive_build"' EXIT

/bin/mkdir -p \
  "$archive_build/Screenshot Archive.app/Contents/MacOS" \
  "$archive_build/Screenshot Archive.app/Contents/Resources"

/usr/bin/xcrun swiftc -O -warnings-as-errors -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$archive_build/ModuleCache" \
  ArchiveCore.swift LaunchAgent.swift ObjectBackup.swift BackupView.swift ScreenshotArchive.swift \
  -o "$archive_build/Screenshot Archive.app/Contents/MacOS/ScreenshotArchive"

/usr/bin/xcrun swiftc -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$archive_build/ModuleCache" \
  scripts/generate-icon.swift \
  -o "$archive_build/generate-icon"
"$archive_build/generate-icon" "$archive_build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$archive_build/AppIcon.iconset" \
  -o "$archive_build/Screenshot Archive.app/Contents/Resources/AppIcon.icns"

/bin/cp Info.plist "$archive_build/Screenshot Archive.app/Contents/Info.plist"
if [[ -d "$archive_app" ]]; then /bin/rm -rf -- "$archive_app"; fi
/bin/mv "$archive_build/Screenshot Archive.app" "$archive_app"
/usr/bin/xattr -cr "$archive_app"
/usr/bin/codesign --force --sign "$sign_identity" "$archive_app"
/usr/bin/codesign --verify --strict "$archive_app"

print -- "Built $archive_app (signed with: $sign_identity)"

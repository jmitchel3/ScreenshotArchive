#!/bin/zsh -f
set -eu
cd -- "${0:A:h}"

universal=0
install_app=0
install_dir="${INSTALL_DIR:-/Applications}"

for arg in "$@"; do
  case "$arg" in
    --universal) universal=1 ;;
    --install) install_app=1 ;;
    -h|--help)
      print -- "Usage: build.sh [--universal] [--install]"
      print -- "  --universal  Build arm64 + x86_64 universal binary"
      print -- "  --install    Install to \${INSTALL_DIR:-/Applications} and refresh enabled LaunchAgents"
      exit 0
      ;;
    *)
      print -u2 -- "Unknown option: $arg"
      exit 2
      ;;
  esac
done

resolve_signing_identity() {
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    print -- "$SIGN_IDENTITY"
    return 0
  fi
  local matches
  matches=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F'"' '$2 == "Screenshot Archive Dev" { print $2 }' || true)
  local count=0
  if [[ -n "$matches" ]]; then
    count=$(print -- "$matches" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  fi
  if [[ "$count" -eq 1 ]]; then
    print -- "Screenshot Archive Dev"
  else
    print -- "-"
  fi
}

refresh_agent_if_enabled() {
  local label="$1"
  local app_path="$2"
  local uid_val
  uid_val=$(/usr/bin/id -u)
  local domain="gui/$uid_val"
  local plist="$HOME/Library/LaunchAgents/$label.plist"

  if [[ ! -f "$plist" ]]; then
    return 0
  fi
  if ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    return 0
  fi

  local backup="$archive_build/$label.plist.bak"
  /bin/cp "$plist" "$backup"

  local updated="$archive_build/$label.plist.new"
  /bin/cp "$plist" "$updated"
  /usr/bin/plutil -replace ProgramArguments.5 -string "$app_path" "$updated"

  /bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    print -u2 -- "Warning: $label remained loaded; kept existing plist unchanged."
    return 1
  fi

  /bin/cp "$updated" "$plist"
  if /bin/launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
    print -- "Refreshed LaunchAgent $label -> $app_path"
    if [[ "$label" == "com.jmitch.screenshot-archive" ]]; then
      print -- "Note: RunAtLoad is enabled on $label, so an immediate cleanup check was triggered."
    fi
  else
    print -u2 -- "Warning: failed to reload $label; restoring previous plist."
    /bin/cp "$backup" "$plist"
    /bin/launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
    return 1
  fi
}

archive_app="$PWD/Screenshot Archive.app"
sign_identity=$(resolve_signing_identity)
host_arch=$(/usr/bin/uname -m)
archive_build=$(/usr/bin/mktemp -d /private/tmp/screenshot-archive-build.XXXXXX)
trap '/bin/rm -rf -- "$archive_build"' EXIT

staged_app="$archive_build/Screenshot Archive.app"
/bin/mkdir -p \
  "$staged_app/Contents/MacOS" \
  "$staged_app/Contents/Resources"

sources=(
  ArchiveCore.swift
  LaunchAgent.swift
  ObjectBackup.swift
  BackupView.swift
  ScreenshotArchive.swift
)

if [[ "$universal" -eq 1 ]]; then
  /usr/bin/xcrun swiftc -O -swift-version 6 -warnings-as-errors -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -module-cache-path "$archive_build/ModuleCache-arm64" \
    "${sources[@]}" \
    -o "$archive_build/ScreenshotArchive-arm64"
  /usr/bin/xcrun swiftc -O -swift-version 6 -warnings-as-errors -parse-as-library \
    -target x86_64-apple-macosx13.0 \
    -module-cache-path "$archive_build/ModuleCache-x86_64" \
    "${sources[@]}" \
    -o "$archive_build/ScreenshotArchive-x86_64"
  /usr/bin/lipo -create \
    "$archive_build/ScreenshotArchive-arm64" \
    "$archive_build/ScreenshotArchive-x86_64" \
    -output "$staged_app/Contents/MacOS/ScreenshotArchive"
else
  /usr/bin/xcrun swiftc -O -swift-version 6 -warnings-as-errors -parse-as-library \
    -target "${host_arch}-apple-macosx13.0" \
    -module-cache-path "$archive_build/ModuleCache" \
    "${sources[@]}" \
    -o "$staged_app/Contents/MacOS/ScreenshotArchive"
fi

# Always compile the icon generator for the host architecture.
/usr/bin/xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -target "${host_arch}-apple-macosx13.0" \
  -module-cache-path "$archive_build/ModuleCache-host" \
  scripts/generate-icon.swift \
  -o "$archive_build/generate-icon"
"$archive_build/generate-icon" "$archive_build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$archive_build/AppIcon.iconset" \
  -o "$staged_app/Contents/Resources/AppIcon.icns"

/bin/cp Info.plist "$staged_app/Contents/Info.plist"
/usr/bin/xattr -cr "$staged_app"

# Sign and verify the staged bundle BEFORE replacing the existing working copy.
/usr/bin/codesign --force --sign "$sign_identity" "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

if [[ "$install_app" -eq 1 ]]; then
  target_app="$install_dir/Screenshot Archive.app"
  /usr/bin/osascript -e 'tell application id "com.jmitch.screenshot-archive.helper" to quit' >/dev/null 2>&1 || true
  /bin/sleep 0.5
  backup_app="$archive_build/PreviousApp.app"
  if [[ -d "$target_app" ]]; then
    /bin/mv "$target_app" "$backup_app"
  fi
  if /bin/cp -R "$staged_app" "$target_app"; then
    /usr/bin/codesign --verify --strict "$target_app"
    print -- "Installed $target_app (signed with: $sign_identity)"
    refresh_agent_if_enabled "com.jmitch.screenshot-archive" "$target_app"
    refresh_agent_if_enabled "com.jmitch.screenshot-archive.backup" "$target_app"
  else
    if [[ -d "$backup_app" ]]; then
      /bin/mv "$backup_app" "$target_app"
    fi
    exit 1
  fi
else
  backup_app="$archive_build/PreviousLocalApp.app"
  if [[ -d "$archive_app" ]]; then
    /bin/mv "$archive_app" "$backup_app"
  fi
  if /bin/mv "$staged_app" "$archive_app"; then
    print -- "Built $archive_app (signed with: $sign_identity)"
  else
    if [[ -d "$backup_app" ]]; then
      /bin/mv "$backup_app" "$archive_app"
    fi
    exit 1
  fi
fi

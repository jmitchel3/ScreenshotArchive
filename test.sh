#!/bin/zsh -f
set -eu
cd -- "${0:A:h}"

host_arch=$(/usr/bin/uname -m)
test_build=$(/usr/bin/mktemp -d /private/tmp/screenshot-archive-test.XXXXXX)
trap '/bin/rm -rf -- "$test_build"' EXIT

/usr/bin/xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "${host_arch}-apple-macosx13.0" \
  -module-cache-path "$test_build/ModuleCache" \
  ArchiveCore.swift LaunchAgent.swift ObjectBackup.swift Tests/ArchiveCoreTests.swift \
  -o "$test_build/ArchiveCoreTests"

"$test_build/ArchiveCoreTests"

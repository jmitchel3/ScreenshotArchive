#!/bin/zsh -f
set -eu
cd -- "${0:A:h}"

test_build=$(/usr/bin/mktemp -d /private/tmp/screenshot-archive-test.XXXXXX)
trap '/bin/rm -rf -- "$test_build"' EXIT

/usr/bin/xcrun swiftc -warnings-as-errors -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$test_build/ModuleCache" \
  ArchiveCore.swift Tests/ArchiveCoreTests.swift \
  -o "$test_build/ArchiveCoreTests"

"$test_build/ArchiveCoreTests"

#!/bin/sh
# Exercise the actual Git hooks against a disposable local origin.
set -eu
root=$(git rev-parse --show-toplevel)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
git init --bare -q -b main "$temp/origin"
git init -q -b main "$temp/clone"
cd "$temp/clone"
git config user.name 'Test Publisher'
git config user.email 'publisher@example.invalid'
git config core.hooksPath /dev/null
git remote add origin "$temp/origin"
mkdir scripts
cp "$root/scripts/publish.sh" "$root/scripts/version.py" scripts/
cp -R "$root/.githooks" .
cat > Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
</dict></plist>
PLIST
echo '# Changelog' > CHANGELOG.md
echo 'initial' > app
echo 'initial' > unrelated
git add .
git commit -qm 'Initial'
git tag -a v1.1.0 -m 'Baseline'
git config core.hooksPath .githooks

echo 'staged' > unrelated
git add unrelated
echo 'unstaged' > unrelated
echo 'feature' > app
git commit -qm 'feat: add backups' -m 'Changelog: Save dated snapshots.' -- app
test "$(git rev-parse 'v1.2.0^{}')" = "$(git --git-dir="$temp/origin" rev-parse main)"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'v1.2.0^{}')"
test "$(git show :unrelated)" = staged
test "$(cat unrelated)" = unstaged
test "$(git show HEAD:unrelated)" = initial
grep -Fqx -- '- Save dated snapshots.' CHANGELOG.md
./scripts/publish.sh
test "$(git tag --list | wc -l | tr -d ' ')" = 2

git switch -qc fix
echo 'fix' >> app
git commit -qm 'fix: handle an empty backup' -- app
test "$(git rev-parse HEAD)" = "$(git --git-dir="$temp/origin" rev-parse fix)"
git switch -q main
git merge --ff-only fix
test "$(git rev-parse 'v1.2.1^{}')" = "$(git --git-dir="$temp/origin" rev-parse main)"
grep -Fqx -- '- handle an empty backup' CHANGELOG.md

# Simulate an unversioned web push and the Actions fallback.
echo 'new format' >> app
git -c core.hooksPath=/dev/null commit -qm 'feat(format)!: change the snapshot format' -- app
git push -q origin main
./scripts/publish.sh
test "$(git rev-parse 'v2.0.0^{}')" = "$(git --git-dir="$temp/origin" rev-parse main)"
python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path("Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == "2.0.0"
assert info["CFBundleVersion"] == "5"
assert Path("CHANGELOG.md").read_text().count("Save dated snapshots.") == 1
PY
echo 'Release hooks, changelog, and fallback publishing passed.'

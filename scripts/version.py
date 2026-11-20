"""Generate release metadata in the publisher's isolated checkout."""

import datetime
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True)


def update_version(base):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", base)
    if not match:
        raise SystemExit(f"Expected a semantic version tag, received {base!r}")
    major, minor, patch = map(int, match.groups())
    messages = git("log", "-z", "--reverse", "--no-merges", "--format=%B", f"{base}..HEAD").strip("\0").split("\0")
    if not any(messages):
        messages = [git("log", "-1", "--format=%B")]

    bump = "patch"
    entries = []
    for message in messages:
        title = message.splitlines()[0]
        conventional = re.fullmatch(r"([\w-]+)(?:\([^)]+\))?(!)?:\s+(.+)", title)
        if (conventional and conventional[2]) or re.search(r"^BREAKING[ -]CHANGE:", message, re.M):
            bump = "major"
        elif bump == "patch" and conventional and conventional[1] == "feat":
            bump = "minor"
        details = re.findall(r"^Changelog: (.+)$", message, re.M)
        entries.extend(details or [conventional[3] if conventional else title])

    if bump == "major":
        version = f"{major + 1}.0.0"
    elif bump == "minor":
        version = f"{major}.{minor + 1}.0"
    else:
        version = f"{major}.{minor}.{patch + 1}"

    plist = Path("Info.plist")
    xml = plist.read_text()
    build = int(plistlib.loads(git("show", f"{base}:Info.plist").encode())["CFBundleVersion"]) + 1
    for key, value in [("CFBundleShortVersionString", version), ("CFBundleVersion", str(build))]:
        pattern = rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)"
        xml, count = re.subn(pattern, lambda m: m[1] + value + m[2], xml)
        if count != 1:
            raise SystemExit(f"Expected exactly one string field named {key} in Info.plist")
    plist.write_text(xml)

    changelog = Path("CHANGELOG.md")
    heading, existing = changelog.read_text().split("\n", 1)
    date = datetime.datetime.now(datetime.timezone.utc).date()
    notes = "\n".join(f"- {entry}" for entry in entries)
    changelog.write_text(f"{heading}\n\n## {version} — {date}\n\n{notes}\n\n{existing.lstrip()}")
    return version


if __name__ == "__main__":
    print(update_version(sys.argv[1]))

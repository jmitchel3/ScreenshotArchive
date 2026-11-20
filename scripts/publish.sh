#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"
# Hooks can inherit the temporary index Git uses for a path-limited commit.
unset $(git rev-parse --local-env-vars)
branch=$(git symbolic-ref --quiet --short HEAD) || exit 0
if [ "$branch" != main ]; then
    git push --set-upstream origin "refs/heads/$branch:refs/heads/$branch"
    exit 0
fi

head=$(git rev-parse HEAD)
base=$(git describe --first-parent --tags --abbrev=0 --match 'v[0-9]*' "$head")
if [ "$(git rev-parse "$base^{commit}")" != "$head" ]; then
    temp=$(mktemp -d)
    tree="$temp/release"
    cleanup() {
        if [ -d "$tree" ]; then git worktree remove --force "$tree"; fi
        rmdir "$temp"
    }
    trap cleanup EXIT
    git worktree add --quiet --detach "$tree" "$head"
    # Generate from committed files. Unrelated staged and unstaged edits stay local.
    version=$(cd "$tree" && python3 scripts/version.py "$base")
    git -C "$tree" add -- Info.plist CHANGELOG.md
    if git show-ref --verify --quiet "refs/tags/v$version"; then
        # A previous run may have created the tag before a local edit blocked the fast-forward.
        release=$(git rev-parse "refs/tags/v$version^{commit}")
        if [ "$(git rev-parse "$release^")" != "$head" ]; then
            echo "v$version already identifies a different release. Reconcile main and its tags before publishing." >&2
            exit 1
        fi
    else
        git -C "$tree" -c core.hooksPath=/dev/null commit --quiet -m "Release v$version"
        release=$(git -C "$tree" rev-parse HEAD)
        git tag -a "v$version" "$release" -m "Screenshot Archive $version"
    fi
    git -c core.hooksPath=/dev/null merge --ff-only "$release"
    head=$release
fi

# A rejected branch or tag leaves both remote refs untouched. Re-running retries the push.
git push --atomic --follow-tags origin "$head:refs/heads/main"

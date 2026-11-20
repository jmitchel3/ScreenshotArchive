## Publishing changes

For completed changes, run the relevant checks, commit the in-scope files, and verify that the push succeeded. Enable the tracked hooks with `git config --local core.hooksPath .githooks` in a fresh clone. Respect an explicit request to keep work local.

Write a commit subject that describes the change. Use `feat:` for a new feature, `fix:` for a fix, and `!` after the type for a breaking change. For multiple user-visible changes, add one `Changelog: …` line per item in the commit body.

The hooks push commits and fast-forward merges. On `main`, they also update the app version, build number, and changelog and push the release tag. If a push fails, resolve the reported issue and rerun `./scripts/publish.sh`.

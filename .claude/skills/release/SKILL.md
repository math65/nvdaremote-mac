---
name: release
description: End-to-end NVDA Remote release — drafts the release notes (English RELEASE_NOTES.md + French RELEASE_NOTES.fr.md) and then builds, signs, notarizes, publishes the GitHub release and the Sparkle appcast with `scripts/build-release.sh --release [--beta]`. Use when the user cuts a release ("publish the new version", "release 0.3", "ship a beta"). User-triggered only: the publish half is public and irreversible.
disable-model-invocation: true
---

# Release NVDA Remote (notes, then publish)

Phase A (notes) only writes Markdown. Phase B (publish) builds, notarizes and
publishes a release that reaches every user through the in-app updater. **Never run
Phase B without an explicit go-ahead from the user.**

- `/release notes`: Phase A only.
- `/release`, `/release publish`, `/release beta`: Phase A, then stop and confirm.

**The version decides the channel, not the argument.**

```bash
grep -m1 MARKETING_VERSION NVDARemote.xcodeproj/project.pbxproj
```

A version with a prerelease suffix (`0.3-beta.1`) is a beta, published with
`--release --beta`: only users who turned on "Receive beta versions" (Settings,
General) get it, and the GitHub release is a prerelease. A bare version (`0.3`) is
stable and reaches everyone. If the argument and the version disagree, stop and
ask. Betas need their own marketing version, or the `v<version>` tag of the beta
and the stable collide.

Always ask git what shipped, never session memory.

## Phase A — Release notes

1. Previous tag: `git tag --sort=-v:refname | head -5`.
2. Changes: `git log <prev-tag>..HEAD --oneline --no-merges`. Skip release plumbing
   ("Update appcast", version bumps). Check `gh pr list --state open` before
   claiming something is fixed.
3. `RELEASE_NOTES.md` (English, also the GitHub release body):

   ```markdown
   ## NVDA Remote <X.Y> (build <N>) — <YYYY-MM-DD>

   ### Highlights
   ### Fixes
   ### Other changes

   ### Download
   [NVDA-Remote-<X.Y>-<N>.zip](https://github.com/math65/nvdaremote-mac/releases/download/v<X.Y>/NVDA-Remote-<X.Y>-<N>.zip)
   ```

   Drop empty sections. Always give the direct asset URL.
4. `RELEASE_NOTES.fr.md`: the same content written in natural French with "vous",
   not a word-for-word translation. Only Sparkle's dialog shows it, to French users.

Tone: the readers are VoiceOver users deciding whether to update. Describe what
they notice before and after, one change per bullet with a bold lead clause. No
class names, protocol messages or code vocabulary.

## Phase B — Publish (after confirmation)

Prerequisites:
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` bumped in
  `NVDARemote.xcodeproj/project.pbxproj` (the app target's Debug and Release
  configurations). The build number goes up for every release, betas included:
  Sparkle compares build numbers.
- `App/AppBackendSecret.plist` present (git-ignored; the script refuses without it).
- On `main`, clean tree, **pushed**: the script checks that HEAD exists on GitHub,
  tags exactly that commit, and pushes `docs/` (appcast and notes) itself.

```bash
scripts/build-release.sh --release          # stable
scripts/build-release.sh --release --beta   # beta
```

Do not trust the exit status alone: read the output for `error:` or `failed`, then
check:

```bash
gh release view v<X.Y> --repo math65/nvdaremote-mac
curl -s https://math65.github.io/nvdaremote-mac/appcast.xml | grep -c "<item>"
```

(GitHub Pages can take a minute to serve the new appcast.)

To fix the notes after publishing, without a new binary: edit the Markdown, re-run
`scripts/render-release-notes.sh` for both HTML files in `docs/`, push, and
`gh release edit v<X.Y> --notes-file RELEASE_NOTES.md`.

Optional AppleVis post: subject 64 characters max, headings H4 or lower, Markdown
body, direct asset URL. Write it separately from the GitHub notes.

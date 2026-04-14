# Release Process

This repository publishes a GitHub Release whenever you push a tag matching `v*` (for example `v1.4.0`).
The workflow builds platform-specific binaries for Linux, macOS, and Windows, and then attaches them to the release.

## One-time setup

1. Ensure `.github/workflows/release.yml` exists on your default branch.
2. Ensure your `CHANGELOG.md` is maintained and committed before tagging.
   - The release workflow uses the contents of `CHANGELOG.md` as the release notes (`body_path: CHANGELOG.md`).

## Steps for each release

1. Update versioning files in the repo if needed.
2. Update `CHANGELOG.md` with the release notes for the new version.
3. Commit and push your changes to your main branch.
4. Create and push a version tag (`v*`):

   ```bash
   git tag -a v1.4.0 -m "Release v1.4.0"
   git push origin v1.4.0
   ```

5. Go to **GitHub → Actions** and watch the **Release** workflow.
6. After it succeeds, open **GitHub → Releases** and verify:
   - A release named/tagged `v1.4.0` (or your tag) exists.
   - Assets are attached:
     - `markdown2html-linux-x64.zip`
     - `markdown2html-macos-x64.zip`
     - `markdown2html-windows-x64.zip`
   - Release notes come from `CHANGELOG.md`.

## If a release needs to be redone

1. Delete the tag locally and remotely.
2. Recreate it and push again.

```bash
git tag -d v1.4.0
git push origin :refs/tags/v1.4.0
git tag -a v1.4.0 -m "Release v1.4.0"
git push origin v1.4.0
```

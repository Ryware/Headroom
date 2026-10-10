# Headroom — Publishing Kit

## Positioning

**Product name:** Headroom  
**Category:** macOS Utilities / Disk Space Analyzer  
**Price:** Free  
**Primary promise:** See what is using your Mac's disk and reclaim space safely.

Headroom is for Mac users and developers who want the speed and visual clarity of a modern disk analyzer without a subscription, account, ads, or data collection.

## Short descriptions

### Tagline

See what is eating your disk. Reclaim the space safely.

### One-line description

A fast, free, privacy-friendly macOS disk space analyzer with an interactive treemap, safety guidance, and developer-aware cleanup.

### GitHub repository description

Free native macOS disk analyzer with a folder tree, treemap, file categories, safety guidance, and fast cleanup.

### Social post

Meet Headroom: a free native disk space analyzer for macOS. Scan huge folders quickly, explore an interactive treemap, find giant files and developer caches, and understand what is safe to remove. No subscription, ads, account, or tracking.

## Full product description

Headroom is a fast, native disk space analyzer and cleanup utility for macOS 14 and newer.

Scan your home folder, startup disk, or any directory and immediately see where the space went. Browse a responsive folder tree, explore a colorful interactive treemap, compare storage by category, and find the largest files and app bundles.

Headroom is especially useful for developers. It recognizes common build output, package stores, dependency folders, virtual machines, caches, and logs from Xcode, npm, pnpm, pip, Gradle, NuGet, Cargo, and other tools.

Before removing anything, Headroom explains what the item is and provides a safety verdict. Use recoverable Trash mode for everyday cleanup, or opt into permanent parallel deletion when you explicitly need it.

Everything runs locally on your Mac. Headroom is free and includes no subscription, ads, account system, analytics, or in-app purchases.

## Current release — 0.2.0

**GitHub release title:** Headroom 0.2.0 — Watch your disk from the menu bar

**Tag:** `v0.2.0`  
**Version:** `0.2.0` (build `2`) in `Info.plist` and `project.yml`

Release body: [`release-notes-0.2.0.md`](release-notes-0.2.0.md).  
After `./release.sh`, attach `dist/Headroom-0.2.0.dmg` and `dist/Headroom-0.2.0.dmg.sha256`.

## Previous release — 0.1.0

### Suggested release title

Headroom 0.1.0 — Free native disk analyzer for macOS

### GitHub release body

Headroom 0.1.0 is the first public release of a fast, free, native macOS disk space analyzer.

### Highlights

- Fast parallel scanning built on `getattrlistbulk(2)`
- Virtualized folder tree for very large directories
- Interactive treemap colored by category, age, or deletion safety
- Storage breakdown by category
- Largest-file and app-bundle discovery
- Safety explanations for recognized macOS and developer-tool locations
- Developer cleanup candidates including DerivedData, package caches, build output, and dependencies
- Recoverable Trash mode and explicit permanent-delete mode
- Fully local operation with no account, ads, subscription, or tracking

### Requirements

- macOS 14 Sonoma or newer
- Apple silicon or Intel Mac

### Install

Download `Headroom-0.1.0.dmg`, open it, and drag Headroom to Applications.

Headroom may request Full Disk Access only when you choose to scan protected locations such as Mail, Messages, or Safari data.

## Discovery metadata

Suggested topics:

`macos`, `swift`, `swiftui`, `disk-usage`, `disk-space`, `disk-cleaner`, `storage-analyzer`, `treemap`, `developer-tools`, `free-mac-app`

Natural search phrases to use in launch posts and landing pages:

- free disk space analyzer for Mac
- macOS storage visualizer
- find large files on Mac
- Mac disk cleanup utility
- treemap disk usage for macOS
- clean Xcode DerivedData and developer caches
- free alternative to subscription disk cleaners

Avoid keyword stuffing; use one or two phrases per paragraph and lead with the user benefit.

## Screenshot order

1. Dashboard — establishes trust and gives a complete overview.
2. Treemap — strongest visual and clearest differentiator.
3. Folder Tree — demonstrates depth and professional utility.
4. Categories — shows explainable storage breakdown.
5. Welcome — communicates polish and ease of use.

The prepared 1920-pixel-wide images are in `Screenshots/`.

## Publication checklist

- [x] Xcode build succeeds without errors.
- [x] Release-mode app build script is available.
- [x] README includes benefit-led copy, install steps, privacy, safety, performance, and screenshots.
- [x] Screenshot set is optimized for web publication.
- [x] License the public source under the MIT License.
- [x] Create a Developer ID Application certificate for team `<your team id>`.
- [x] Notarization credentials: `release.sh` uses the App Store Connect API key in `.secrets/` (no keychain profile needed).
- [x] Run `release.command` (double-click; runs `release.sh` outside the assistant sandbox) and verify the notarized DMG.
- [x] Create the public `Ryware/Headroom` repository.
- [x] Configure GitHub Actions release-build verification.
- [x] Create the draft GitHub release for `v0.1.0`.
- [x] Upload `dist/Headroom-0.1.0.dmg` and `.sha256` to the draft release with the release body above.
- [x] Publish a SHA-256 checksum (in the release notes and `CHANGELOG.md`).
- [ ] Publish the draft release (GitHub → Releases → v0.1.0 → Publish release).
- [ ] Test the downloaded DMG on a Mac that did not build the app.

## Mac App Store checklist

Build the App Store variant from the generated Xcode project (`xcodegen` → `Headroom.xcodeproj`), which enables App Sandbox and the `APP_STORE` compilation condition.

```sh
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Release \
  -archivePath dist/Headroom.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath dist/Headroom.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath dist/appstore -allowProvisioningUpdates
```

Set `destination` to `upload` in `ExportOptions.plist` to upload directly once the app record exists.

- [x] App Sandbox entitlements (`AppStore.entitlements`) with user-selected read/write and security-scoped bookmarks.
- [x] `APP_STORE` code paths: no Home/Startup Disk shortcuts, no known-location scanning, bookmark-based recents.
- [x] App icon asset catalog (`Assets/Assets.xcassets`).
- [x] App Store screenshots at exactly 1440 × 900 (`AppStore/Screenshots/`).
- [x] Bundle ID the app bundle id registered and Mac App Store provisioning profile created.
- [x] Apple Distribution certificate (cloud managed) created.
- [x] Universal (arm64 + x86_64) archive exported and signed: `dist/appstore/Headroom.pkg`.
- [x] Create the app record in App Store Connect (app ID 6817532988, name "Headroom - Free Mac Analyzer" because "Headroom" is taken).
- [x] Upload build 0.1.0 (1) via Xcode Organizer.
- [x] Fill in App Information, pricing, availability, age rating, listing text, and screenshots via `AppStore/asc_publish.py` (App Store Connect API).
- [x] Attach the uploaded build to version 0.1.0.
- [ ] Add the App Review contact phone (`ASC_CONTACT_PHONE=+... python3 AppStore/asc_publish.py review`).
- [ ] Complete the App Privacy questionnaire in the web UI ("No, we do not collect data"); the API does not expose it.
- [ ] Submit for review.

`asc_publish.py` needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, and `ASC_TOKEN_TOOL` (the compiled `asc_token` JWT helper). Keys live in the git-ignored `.secrets/` folder.

## Homebrew

Users install with `brew install ryware/tap/headroom`. The tap is the public repository [`Ryware/homebrew-tap`](https://github.com/Ryware/homebrew-tap), holding `Casks/headroom.rb`.

The tap keeps itself up to date: its `Update Headroom cask` workflow runs every 3 hours (and on demand from its Actions tab). It reads Headroom's latest GitHub release, takes the DMG checksum from the `.sha256` asset, fills in `packaging/homebrew/headroom.rb` from this repository and commits the result. No token or secret is needed.

Optional: to update the tap the moment a release is published instead of within 3 hours, add a fine-grained token with **Contents: Read and write** on `Ryware/homebrew-tap` to this repository as the Actions secret `HOMEBREW_TAP_TOKEN`; the release workflow then pushes the cask itself.

Later, once the repository meets Homebrew's notability bar (about 75 stars), the cask can be submitted to the official `homebrew/cask` with `brew bump-cask-pr` so that `brew install headroom` works without the tap.

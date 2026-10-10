# Changelog

## 1.1.0 — October 11, 2026

### 🚀 New feature

- **MCP server for AI agents.** `Headroom --mcp` serves the Model Context Protocol on stdio, so Claude Code, Claude Desktop, Cursor and other MCP clients can check free space, scan folders, find cleanup candidates and duplicates, and ask whether a path is safe to delete, using the same engine and safety rules as the app. The only write is `move_to_trash`, which is recoverable and refuses items marked *Do not delete*. See [Use with AI agents](README.md#use-with-ai-agents-mcp-and-command-line).
- **Command line tool for agents.** The app binary takes commands (`Headroom status`, `scan`, `cleanup`, `duplicates`, `explain`, `trash` and more) and prints JSON, for agents that run shell commands. The app carries instructions for agents in `Contents/Resources/AGENTS.md`, so an agent asked to use Headroom finds out how by itself.
- **Agent work shows in the window.** When the window is empty or shows the same folder, an agent's scan and duplicate search run there, so you see their progress and results.
- **Private to you.** While the app is open it also serves MCP on 127.0.0.1, and every request must carry a session token stored where only you can read it. **Settings → AI agents** turns it off. The App Store build does not include any of this.

### ✨ Changed

- **The What's New page has its own animation**: a small Headroom window where a dashboard tile opens its view and Back returns, instead of a sparkle icon.

### 🐛 Fixed

- **Updating no longer opens the tour at the welcome page.** Updated users, and **Help → What's New in Headroom**, now land on What's New as intended. Users who updated to 1.0.5 see it once on their next update.

### 🙏 Thanks

The agent support comes from [@SonyStone](https://github.com/SonyStone), who designed and built the MCP server, the command line tool and the bundled instructions (#1). Thank you!

## 1.0.5 — October 7, 2026

### 🚀 New feature

- **Back and Forward, like Finder.** **⌘[** goes back and **⌘]** goes forward, with **‹ ›** buttons in the toolbar and a new **Go** menu. **⌘←** and **⌘→** work too, except while typing in a text field, where they still move the cursor. Going back into By Category brings back the category you had selected.
- **Jump to any view from the keyboard.** **⌘1** opens the Dashboard and **⌘2–⌘7** open Folder Tree, Treemap, By Category, Largest Files, Duplicates and Cleanup.
- **Duplicates says what to do next.** After a search, a bar explains the choice and offers **Select extra copies (keep newest)** as one click, with *keep oldest* and *keep highest in the tree* under **Other ways**. With copies ticked it shows the count and size, **Clear**, and **Move N copies to Trash (size)**, and says whether they can be put back. Copies marked *Do not delete*, such as files inside `.git`, are never picked for you (#14).
- **The Dashboard is clickable.** The four stat tiles open Treemap, Largest Files, Folder Tree and Cleanup, and a bar or row in *Space by category* opens By Category with that category selected (#12). A one-time tip shows how to come back.

### ✨ Changed

- **By Category's chart selects a category** when you click a bar, its label or the empty space after a short bar, and stays in sync with the list (#11).
- **Scanned locations are named the way Finder names them**: *Macintosh HD* with a drive icon instead of `/`, the home folder by its name with a house icon, and folders by their Finder name. This applies to the sidebar, headers, inspector, scanning screen, recent scans and Duplicates (#10).
- **Duplicate rows lead with what tells copies apart**: the path below the folder they share, with that folder on the second line. Groups of more than six copies collapse to five with *Show N more copies*, and clicking a copy shows it in the inspector (#14).
- Chart axes start at **0** instead of "Zero KB".

### 🐛 Fixed

- **Treemap hover is smooth in Safety mode.** Moving the pointer repainted every cell, and Safety colours rebuilt each cell's explanation text on every frame. The map now redraws only when its layout, colours or selection change, and colours are worked out once. Safety badges in Duplicates, Cleanup and Largest Files are cheaper too (#13).
- The inspector showed the scanned root's location as `/..`.
- In Duplicates, the status bar no longer shows a selection left over from Folder Tree, and the inspector follows the copy you click instead of a folder picked elsewhere (#14).

### 🙏 Thanks

Most of this release comes from [@SonyStone](https://github.com/SonyStone), who reported five rough edges (#4–#8) and then fixed each one: Finder-style location names (#10), the clickable By Category chart (#11) and Dashboard (#12), smooth Treemap hover (#13) and the Duplicates next step (#14). Thank you!

## 1.0.4 — October 6, 2026

### 🚀 New feature

- **Security products are named, not guessed at.** Headroom looks for installed antivirus and ransomware shields (AVG, Avast, Bitdefender, Trend Micro, Norton, McAfee, Kaspersky, ESET, Sophos, Malwarebytes, Microsoft Defender, CrowdStrike, SentinelOne, Jamf Protect). When a delete is refused inside a folder they guard, the result names the likely product and the exact setting to change, with an **Open ⟨product⟩** button next to **Reveal in Finder**, since Finder is always allowed.
- **Warned before, not after.** The confirmation for a delete inside Documents, Desktop, Downloads or Pictures says which product guards the folder and what to do if the delete stops.
- **Move to Trash names the real cause when it is refused.** macOS reports an antivirus refusal, a privacy-folder denial and a root-owned item with the same "You do not have permission" text. Headroom now tells them apart (a refusal that was held for seconds is a ransomware shield such as AVG or Bitdefender) and says where the fix is. The result has a **Reveal in Finder** button, because Finder is allowed through by every security product, and a **How to Fix** link to the FAQ with the per-product steps.

### ✨ Changed

- Permanent delete tries one file on its own before the parallel pass. A held refusal there stops the delete within seconds instead of after a round of parallel waits.
- The result toast's Details alert has a **How to Fix…** button that opens the landing page's answer for refused deletes.

### 🧰 Chores

- 91 unit tests: product detection, guarded-folder matching, message wording, the pre-flight stall rule, and the Trash-refusal explanations.

## 1.0.3 — October 6, 2026

### 🐛 Fixed

- **Duplicate finder no longer eats all memory.** Hashing read files through `FileHandle`, and every chunk it returned stayed alive until the whole worker finished, so a scan held every byte it had compared in memory (tens of GB on a big tree) until macOS started killing other apps. Hashing now uses `pread(2)` into one reusable 1 MB buffer per worker: a 7.9 GB verification pass runs in 7 MB and about three times faster.
- **Permanent delete no longer grinds for hours when a security product blocks it.** An antivirus or ransomware shield with an Endpoint Security extension can hold every `unlinkat` for seconds and then refuse it. Headroom now stops after a few consecutive held refusals, renames any hidden folder back to its real name, and explains what happened in the result instead of showing "0 KB freed" with no reason. A refused removal is also no longer retried unless the file actually carried an immutable flag, which halved the time wasted per file.
- The result toast shows the reason for a failure inline; the Details button is no longer needed to learn that nothing was removed.
- A late progress tick could re-open the delete sheet after the delete had finished.

### ✨ Changed

- **Cancel button** on the permanent-delete sheet. Files already removed stay removed, everything else is left untouched.
- Delete progress advances per file and shows the current path, so a slow delete is visibly moving instead of looking frozen.
- Progress for deletes and duplicate scans is published only when it changes; the window no longer re-renders ten times a second for the length of a delete.

### 🧰 Chores

- 83 unit tests: multi-chunk hashing against CryptoKit, locked-file deletion, the stall rule, and cancel.

## 1.0.2 — October 5, 2026

### ✨ Changed

- **New landing page** at [headroom-app.org](https://headroom-app.org/): an interactive treemap demo in the hero that scans sample data, shows verdicts on hover, zooms on click and lets you clean the safe items; native CSS, self-hosted Geist, a bento feature grid with real screenshots, a scroll-driven explainer that walks through the duplicate finder's four passes on a mock group of files, and light and dark modes with a toggle. Motion is native CSS and respects Reduce Motion. No frameworks. The site uses Google Analytics for visit and download counts; the app still sends nothing.
- README and site documentation cover the duplicate finder's four comparison passes and the menu bar popover.

### 🧹 Chores

- Removed all signing and App Store identifiers from the repository and its history. `ExportOptions.plist` is now a gitignored local file generated from `ExportOptions.example.plist`; the release script reads the team id and App Store Connect keys from the keychain and environment only.

## 1.0.1 — October 5, 2026 · First stable release

DiskTree is now **Headroom**, and this is the first stable release. The name describes what the app gives you, and it no longer clashes with another disk analyzer on the App Store. The bundle id is unchanged, so 0.x installs update in place and the free-space history carries over. (1.0.0 was tagged internally and never published; everything below is new since 0.2.0.)

### 🚀 New feature

- **Duplicate finder.** Finds files that exist more than once with identical content, grouped and sorted by how much space one copy would give back. Files are bucketed by size, then compared by a 64 KB header hash, then by samples from the middle and the end, then by a full SHA-256, so only true byte-for-byte copies are listed and large files are read in full only when every cheaper check says they match. Files under 1 MB and files inside app bundles are skipped. Select with one click (keep newest / oldest / highest in the tree), keep-one-copy protection on by default, delete to the Trash or permanently.
- **Dashboard card** showing reclaimable duplicate space with a jump to the new Duplicates pane.
- **Progress by phase** for the duplicate scan ("Comparing file headers", "Sampling large files", "Verifying byte for byte") and a paged results list, so huge scans neither look stuck nor stall the window.

### ✨ Changed

- Renamed to Headroom everywhere: app, menu bar, GitHub repository, landing page, DMG name (`Headroom-1.0.1.dmg`).
- The What's New tour explains the duplicate finder and the new name.
- Landing page redesign: scroll reveals, live free-space ring, animated duplicate-finder demo, menu bar screenshot.

### 🧰 Chores

- 79 unit tests (duplicate finder added), CI coverage and badges updated for the new name.
- Release workflow publishes `Headroom-<version>.dmg`.
- Removed Apple team id, App Store Connect ids, SKU and contact email from the repository and its history; `ExportOptions.plist` and the App Store tooling are local-only. The signing identity is discovered from the keychain.

## 0.2.0 — September 30, 2026

Headroom now watches your disk from the menu bar. Still 100% free, with every feature unlocked.

### 🚀 New feature

- **Menu bar monitor** with a ring showing how much of the startup disk is free. It turns amber, then red, as space runs low. Optionally show the free space as text next to the ring.
- **Popover** with free / used / total space, a Healthy / Getting low / Low status, and a 7-day free-space chart.
- **Reclaimable now**: adds up safe caches, logs and build output and lets you clean them in one click. Only items rated Safe are included, and they go to the Trash, so it is recoverable.
- **Alerts** (local notifications): low free space (default below 10 GB) and fast drops (default 5 GB within an hour). Both thresholds are adjustable. Tapping an alert opens Headroom.
- **Dashboard trend card** with the 7-day free-space history and the change over the last 24 hours.
- **Settings** (⌘,):
  - Show Headroom in the menu bar
  - Show free space next to the icon
  - Keep running when the window is closed
  - Show in the Dock (turn off for a menu-bar-only app)
  - Open at login (starts quietly in the menu bar)
  - Alert toggles and thresholds
  - Deleting mode (Trash or permanent)
- Popover shortcuts: **Open Headroom**, **Scan Home**, Settings and Quit.

### 🔥 Bug fix

- Sorting by Size, Name, Files or Modified no longer freezes the app on very large scans. Folders are now sorted only when they are displayed.
- **Open Headroom** from the menu bar (and tapping an alert) reliably brings the window forward, including after the window was closed or when the app is running without a Dock icon.

### ⚙️ Chore

- Version 0.2.0 (build 2). Existing users see the What's New page of the intro tour.
- Direct-download builds are universal (Apple silicon and Intel), signed with a Developer ID certificate and notarized by Apple.
- The Mac App Store build stays sandboxed: it scans and cleans only folders you choose. Home, Startup Disk, and one-click cleanup of known caches stay in the direct-download app.
- Unit tests cover the scanner, deleter, safety rules, cleanup finder, and disk monitor. GitHub Actions runs them on every push.

### 🔒 Privacy

Free-space history (at most 7 days) is stored only on your Mac in Application Support. Alerts are local notifications. Nothing is uploaded.

---

## 0.1.0

Headroom 0.1.0 is the first public release of a fast, free, native macOS disk space analyzer.

### 🚀 New feature

- Fast parallel scanning built on `getattrlistbulk(2)`
- Virtualized folder tree for very large directories
- Interactive treemap colored by category, age, or deletion safety
- Storage breakdown by category
- Largest-file and app-bundle discovery
- Safety explanations for recognized macOS and developer-tool locations
- Developer cleanup candidates including DerivedData, package caches, build output, and dependencies
- Recoverable Trash mode and explicit permanent-delete mode
- Fully local operation with no account, ads, subscription, or tracking

### ⚙️ Chore

- macOS 14 Sonoma or newer. Apple silicon or Intel (universal binary).
- The DMG is signed with a Developer ID certificate and notarized by Apple.

SHA-256 `Headroom-0.1.0.dmg`: `6361fea6d58dd6c0d07e03201a3eb9cd4c18272a917e481ae2b1469af592c097`

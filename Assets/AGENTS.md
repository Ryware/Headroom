# Headroom: instructions for AI agents

Headroom is a disk usage analyzer for macOS. Its command line tool scans folders and finds large files,
duplicates and regenerable clutter (caches, `node_modules`, build output…), with a safety verdict for every item.
Use it instead of `du` and `find` when the user asks what takes space or what they can delete.

## Run it

The command line tool is the app's own binary, next to this file:

```sh
/Applications/Headroom.app/Contents/MacOS/Headroom help     # adjust the path if the app lives elsewhere
```

It needs no setup. Every command prints JSON. While the Headroom app is open, commands reuse the folder shown
in its window, and the user sees duplicate searches you start there.

| Command | What it does |
| --- | --- |
| `status [path]` | Free, used and total space on the volume |
| `state` | What the user has open in the Headroom window |
| `scan <path>` | Size, categories, largest subfolders and files, reclaimable total |
| `list <path> --depth 2` | Folder tree sorted by size (the data behind the treemap) |
| `largest <path> --category video` | Largest files and bundles, optionally by category |
| `cleanup [path]` | Caches, `node_modules`, DerivedData, build output, logs, Trash, with safety advice |
| `explain <path>` | What a file or folder is and whether it is safe to delete |
| `duplicates <path>` | Byte-for-byte identical files, ranked by wasted space |
| `open <path>` | Show a folder in the Headroom window |
| `trash <path>... --yes` | Move items to the Trash (recoverable) |

`Headroom help <command>` lists a command's options. Scanning a large folder such as `~` takes up to a minute.

For "what can I delete?", run `cleanup ~`: it searches the whole home folder, including every project's
`node_modules` and build output. `cleanup` without a path only checks well-known cache locations.

## Rules

- Run `explain` before suggesting that the user delete something, and pass on its verdict and advice.
- Never run `trash` without asking the user first. It refuses items marked *Do not delete* and top-level
  system and home folders. Permanent deletion is not available.

## MCP (optional)

The same tools are available as an MCP server over stdio: command `/Applications/Headroom.app/Contents/MacOS/Headroom`,
args `["--mcp"]`. Only add it to your client's configuration if the user asks for it.

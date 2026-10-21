# `omarchy-cleaner` CLI reference

The CLI is the plugin's only backend: the panel, shell IPC, the scheduled scan
and your own scripts all call it. It lives at
`~/.config/omarchy/plugins/io.github.momostifler96.omarchy-cleaner/bin/omarchy-cleaner`.
Run `omarchy-cleaner link` to put it on your `PATH`.

## Conventions

- `--json` prints exactly one JSON object or array on **stdout**. Progress and
  warnings go to **stderr** (`==>` step, `  -` done, `  !` warning).
  `--quiet` silences progress.
- Commands that change something (`clean`, `maintain`, `trash`) ask for
  confirmation on a terminal. Without a terminal they refuse unless you pass
  `--yes`.
- With `--json`, errors are reported as `{"ok": false, "error": "…", "code": N}`.

| Exit code | Meaning |
|---|---|
| 0 | success |
| 1 | error |
| 2 | usage error (unknown command, module, option or value) |
| 3 | confirmation required or refused (pass `--yes`) |
| 4 | partial failure (some items or root actions failed) |

## Commands

### `scan [MODULE...] [--details] [--notify] [--json]`

Measures what each module could free. It never modifies anything. With no
module names it scans every module and replaces the cached state. With names
it merges the result into the cached state.

- `--details` lists every item instead of the 5 largest.
- `--notify` sends a desktop notification when the pre-selected total reaches
  `notifyThresholdMB`.

```json
{
  "ok": true,
  "version": "0.1.0",
  "generatedAt": "2026-10-21T10:39:45+00:00",
  "totalBytes": 151588978108,
  "selectedBytes": 22342917973,
  "modules": [
    {
      "id": "user-cache",
      "title": "User caches",
      "description": "…",
      "kind": "user",              // user | root | command
      "requiresRoot": false,
      "risk": "low",               // low | medium | high
      "mode": "contents",          // contents | delete | trash | report | root | command
      "available": true,
      "reason": "",                // why the module is unavailable, when it is
      "selected": true,            // pre-selected (config "selection" or module default)
      "bytes": 4187593112,
      "count": 40,
      "items": [ { "bytes": 1203421184, "path": "/home/me/.cache/chromium", "label": "chromium" } ]
    }
  ]
}
```

Items of root and command modules use pseudo paths such as
`pacman-cache:old`, `journal:vacuum`, `pkg:<name>` or `docker:Images`.

### `clean (MODULE... | --defaults) [--dry-run] [--yes] [--json]`

Re-scans the named modules, then cleans them. `--defaults` uses the
pre-selection. Root modules are batched into a single `pkexec` call, so you are
asked for your password once. `large-files` is review-only: it is reported as
`skipped` and never cleaned in bulk.

`--dry-run` shows the plan and changes nothing:

```json
{ "ok": true, "dryRun": true, "plannedBytes": 123, "modules": [ { "id": "trash", "mode": "contents", "bytes": 123, "items": [ … ] } ] }
```

Real run:

```json
{
  "ok": true,
  "dryRun": false,
  "finishedAt": "2026-10-21T11:02:10+00:00",
  "freedBytes": 5368709120,
  "modules": [
    { "id": "user-cache", "ok": true, "freedBytes": 4187593112, "errors": 0, "mode": "contents" },
    { "id": "journal", "ok": true, "freedBytes": 1181116006, "errors": 0, "mode": "root", "estimated": true }
  ]
}
```

For root modules, `freedBytes` is the scanned estimate (`"estimated": true`).
Only one `clean` runs at a time. A concurrent run exits with code 1.

### `maintain TASK... [--yes] [--json]`

| Task | Root | Runs |
|---|:-:|---|
| `font-cache` | | `fc-cache -f` |
| `desktop-db` | | `update-desktop-database ~/.local/share/applications` |
| `dns-flush` | 🔒 | `resolvectl flush-caches` |
| `trim` | 🔒 | `fstrim --all --verbose` |
| `locate-db` | 🔒 | `updatedb` |

```json
{ "ok": true, "tasks": [ { "verb": "font-cache", "ok": true, "message": "" } ] }
```

### `trash PATH... [--yes] [--json]`

Moves files or folders to the freedesktop Trash. This is how the panel removes
a single large file. Paths outside `$HOME` (or a mounted drive's own trash) and
ignored paths are refused.

### `status [--json]`

Returns the cached state without scanning. It is cheap enough to poll.

```json
{ "ok": true, "scanned": true, "generatedAt": "…", "totalBytes": 0, "selectedBytes": 0,
  "modules": [ { "id": "trash", "title": "Trash bins", "bytes": 0, "selected": true, "available": true } ] }
```

### `modules [--json]` · `tasks [--json]`

Static catalogues: id, title, description, kind/root, default selection, risk and mode.

### `ignore list | add PATH | remove PATH`

Manages the ignore list. Entries are absolute paths (`~` allowed) or globs.
A path matches when it is equal to an entry, below it, or matches it as a glob.

### `config list | get KEY | set KEY VALUE | unset KEY`

Keys: `pacmanKeep`, `journalMaxMB`, `largeFileMinMB`, `notifyThresholdMB`
(whole numbers), and `selection`, `ignore` (JSON arrays). Values are validated.
For example, `selection` must only contain known module ids.

### `schedule enable [daily|weekly|monthly] | disable | status`

Creates or removes `~/.config/systemd/user/omarchy-cleaner-scan.{service,timer}`.
These files are marked as managed. A file with the same name that the plugin
did not create is never overwritten. The timer only runs
`scan --notify --quiet --json` at idle I/O priority. It never cleans.

### `history [--limit N] [--json]`

Shows the last N cleans (default 20), read from `~/.local/state/omarchy-cleaner/history.jsonl`.

### `link` · `unlink`

Adds or removes the `~/.local/bin/omarchy-cleaner` symlink. An existing file
that is not this plugin's link is never replaced.

### `open` · `version` · `help`

`open` opens the panel in the running shell through IPC.

## Shell IPC

When the widget is enabled, the shell exposes the target
`io.github.momostifler96.omarchy-cleaner` with these methods:

| Method | Returns | Effect |
|---|---|---|
| `open`, `close`, `toggle` (`show`, `hide`) | — | panel visibility |
| `scan` | — | background scan; the widget updates when it finishes |
| `cleanDefaults` | — | cleans the pre-selected modules (password prompt for root items) |
| `status` | JSON string | `busy`, `status`, `error`, `generatedAt`, `totalBytes`, `selectedBytes` |

Call it with `omarchy-shell io.github.momostifler96.omarchy-cleaner <method>`.

## Examples

```bash
# Clean caches every night from cron or a timer, without prompts:
omarchy-cleaner clean user-cache dev-cache --yes --quiet

# Report only, for a status bar or dashboard:
omarchy-cleaner status --json | jq -r '.selectedBytes'

# Ask an AI agent to look first, then act on the dry-run plan:
omarchy-cleaner scan --json --details
omarchy-cleaner clean --defaults --dry-run --json
```

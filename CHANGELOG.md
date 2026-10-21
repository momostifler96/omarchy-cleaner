# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [0.2.0] — 2026-10-21

### Added
- **Memory** tab in the panel:
  - RAM and swap gauges, with the reclaimable file cache shown separately;
  - applications ranked by real memory use (PSS summed per systemd unit),
    expandable to their heaviest processes;
  - clean quit (SIGTERM) and force quit (SIGKILL) with confirmation;
  - stuck processes (stopped, zombie, disk-wait) with an explanation.
- `omarchy-cleaner memory`, `memory quit UNIT` and `memory kill PID`
  commands, with `--force` and JSON output.
- **Drop file cache** maintenance task (`drop-caches` root verb), behind a
  warning explaining why it rarely helps.
- IPC methods `showMemory` and `showDisk`.
- Tests for the memory view and quit safety, including quitting a real app scope.

### Changed
- The confirmation dialog now handles every destructive action (clean, quit,
  drop cache).
- Preview image shows both tabs.

## [0.1.0] — 2026-10-21

### Added
- Bar widget and popup panel for the Omarchy Quattro shell:
  - categories with sizes, pre-selection and risk hints;
  - item previews;
  - review-only large files with "open folder" and "move to Trash" actions;
  - a confirmation dialog;
  - maintenance buttons.
- `omarchy-cleaner` CLI with JSON output: `scan`, `clean` (including
  `--dry-run` and `--defaults`), `maintain`, `trash`, `status`, `modules`,
  `tasks`, `ignore`, `config`, `schedule`, `history`, `link`/`unlink`, `open`.
- 13 modules: user caches, developer caches, AUR build cache, downloaded
  models and browsers, Trash, pacman cache, journal, crash dumps, orphan
  packages, snapper snapshots, Docker leftovers, broken launchers, large files.
- 5 maintenance tasks: font cache, launcher database, DNS flush, SSD trim,
  file search index.
- Privileged helper `omarchy-cleaner-root`, run through pkexec, limited to a
  fixed list of verbs.
- Remote control:
  - shell IPC target `io.github.momostifler96.omarchy-cleaner`
    (`open`, `close`, `toggle`, `scan`, `cleanDefaults`, `status`);
  - an opt-in systemd user timer for scheduled scans with notifications.
- Ignore list, an optional config file and a clean history.
- Test suite (`tests/run.sh`) that runs in a throw-away home directory.

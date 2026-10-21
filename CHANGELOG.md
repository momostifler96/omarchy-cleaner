# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

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

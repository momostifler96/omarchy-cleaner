#!/bin/bash
# shellcheck shell=bash
#
# Cleanup modules for omarchy-cleaner.
#
# A module is one registry line plus a few functions named after its id
# (dashes become underscores):
#
#   OC_MODULES line   id|title|description|kind|default|risk|mode
#     kind     user    : runs as the current user
#              root    : cleaned through bin/omarchy-cleaner-root via pkexec
#              command : cleaned by a dedicated user command (e.g. docker)
#     default  1 when the module is pre-selected by a plain `clean --defaults`
#     risk     low | medium | high (shown in the UI, documented in README)
#     mode     contents : empty each item directory but keep it
#              delete   : remove each item entirely
#              trash    : move each item to the freedesktop Trash
#              report   : never cleaned in bulk; items are reviewed and
#                         removed one by one (`omarchy-cleaner trash PATH`)
#              root / command : see kind
#
#   oc_avail_<id>   optional; prints a reason and returns 1 when unavailable
#   oc_scan_<id>    prints items as "<bytes>\t<path>\t<label>" (see oc_emit)
#   oc_verbs_<id>   root modules: prints the helper verb(s) to run
#   oc_clean_<id>   command modules: performs the cleanup
#
# Scans never modify anything. Cleans always re-scan first, so only items that
# still exist and are not ignored are touched.

OC_MODULES=(
  "user-cache|User caches|Application caches in ~/.cache (browsers, thumbnails, Electron apps, shaders…). Rebuilt automatically.|user|1|low|contents"
  "dev-cache|Developer caches|Package-manager caches: npm, pnpm, yarn, bun, pip, uv, Go, Cargo, Gradle, Composer, Deno… Re-downloaded on the next build.|user|0|low|contents"
  "aur-cache|AUR build cache|Clone and build directories left by yay and paru.|user|1|low|contents"
  "downloaded-assets|Downloaded models & browsers|Large re-downloadable assets cached by tools: Hugging Face models, Playwright/Puppeteer/Cypress browsers, Electron binaries, LM Studio…|user|0|medium|contents"
  "trash|Trash bins|Your Trash plus the trash folders on mounted drives.|user|1|low|contents"
  "pacman-cache|Package cache|Old package versions in /var/cache/pacman/pkg (keeps the last versions, removes uninstalled ones).|root|1|low|root"
  "journal|System logs|systemd journal archives beyond the configured size limit.|root|1|low|root"
  "coredumps|Crash reports|Core dumps stored by systemd-coredump.|root|1|low|root"
  "orphans|Orphan packages|Packages installed as dependencies that nothing requires anymore.|root|0|medium|root"
  "snapper|Old snapshots|Btrfs snapshots past snapper's own retention rules (snapper cleanup number).|root|0|medium|root"
  "docker|Docker leftovers|Stopped containers, unused networks, dangling images and build cache. Volumes are never touched.|command|0|medium|command"
  "broken-entries|Broken launchers|App launchers and autostart entries whose program no longer exists (moved to Trash).|user|0|low|trash"
  "large-files|Large files|Files over the size threshold in your home folders. Review only: move files to Trash one by one.|user|0|high|report"
)

# Maintenance tasks: id|title|description|kind
OC_TASKS=(
  "font-cache|Rebuild font cache|Regenerate the fontconfig cache (fc-cache -f).|user"
  "desktop-db|Refresh launcher database|Rebuild the MIME/launcher cache for your local apps.|user"
  "dns-flush|Flush DNS cache|Clear systemd-resolved's DNS cache.|root"
  "trim|Trim SSDs|Tell SSDs which blocks are free (fstrim on all mounted filesystems).|root"
  "locate-db|Update file search index|Rebuild the plocate database used by file search.|root"
)

# Directory names inside ~/.cache claimed by a more specific module, so the
# generic user-cache module never counts them twice.
OC_DEV_CACHE_NAMES=(pip uv pypoetry go-build gopls goimports pnpm yarn node-gyp composer deno .bun mise typescript ccache sccache zig bazel)
OC_AUR_CACHE_NAMES=(yay paru)
OC_ASSET_CACHE_NAMES=(huggingface ms-playwright ms-playwright-mcp ms-playwright-go puppeteer Cypress electron electron-builder argos-translate lm-studio lm-studio-updater chrome-devtools-mcp torch whisper)
# Never touched: the running shell, Omarchy's own state, and anything that
# looks like a backup somebody kept on purpose.
OC_PROTECTED_CACHE_NAMES=(omarchy quickshell)
OC_PROTECTED_CACHE_GLOBS=('*.bak' '*.backup' '*.orig' '*.old')

oc_name_in() {
  local name=$1 item
  shift
  for item in "$@"; do [[ $name == "$item" ]] && return 0; done
  return 1
}

oc_cache_name_protected() {
  local name=$1 glob
  oc_name_in "$name" "${OC_PROTECTED_CACHE_NAMES[@]}" && return 0
  for glob in "${OC_PROTECTED_CACHE_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ $name == $glob ]] && return 0
  done
  return 1
}

# --- Registry accessors -----------------------------------------------------

oc_module_line() {
  local line
  for line in "${OC_MODULES[@]}"; do
    [[ ${line%%|*} == "$1" ]] && { echo "$line"; return 0; }
  done
  return 1
}

oc_module_ids() {
  local line
  for line in "${OC_MODULES[@]}"; do echo "${line%%|*}"; done
}

oc_module_field() {
  # $1 = id, $2 = field index (1-based, id=1 … mode=7)
  oc_module_line "$1" | cut -d'|' -f"$2"
}

oc_task_line() {
  local line
  for line in "${OC_TASKS[@]}"; do
    [[ ${line%%|*} == "$1" ]] && { echo "$line"; return 0; }
  done
  return 1
}

oc_fn() { echo "$1_${2//-/_}"; }

oc_module_available() {
  local fn
  fn=$(oc_fn oc_avail "$1")
  if declare -F "$fn" >/dev/null; then "$fn"; else return 0; fi
}

oc_module_scan() {
  "$(oc_fn oc_scan "$1")"
}

# --- user-cache -------------------------------------------------------------

oc_scan_user_cache() {
  [[ -d $OC_CACHE_HOME ]] || return 0
  local entry name
  while IFS= read -r -d '' entry; do
    name=$(basename -- "$entry")
    oc_cache_name_protected "$name" && continue
    oc_name_in "$name" "${OC_DEV_CACHE_NAMES[@]}" "${OC_AUR_CACHE_NAMES[@]}" "${OC_ASSET_CACHE_NAMES[@]}" && continue
    [[ -L $entry ]] && continue
    if [[ -d $entry ]]; then
      oc_emit_path "$entry" "$name"
    fi
  done < <(find "$OC_CACHE_HOME" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# --- dev-cache --------------------------------------------------------------

oc_dev_cache_paths() {
  local name
  for name in "${OC_DEV_CACHE_NAMES[@]}"; do
    echo "$OC_CACHE_HOME/$name"
  done
  echo "$HOME/.npm/_cacache"
  echo "$HOME/.bun/install/cache"
  echo "$HOME/.cargo/registry/cache"
  echo "$HOME/.cargo/registry/src"
  echo "$HOME/.cargo/git/checkouts"
  echo "$HOME/.gradle/caches"
  echo "$HOME/.local/share/pnpm/store"
}

oc_scan_dev_cache() {
  local path
  while IFS= read -r path; do
    [[ -d $path && ! -L $path ]] || continue
    oc_emit_path "$path" "${path#"$HOME"/}"
  done < <(oc_dev_cache_paths)
}

# --- aur-cache --------------------------------------------------------------

oc_avail_aur_cache() {
  if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
    echo "no AUR helper (yay/paru) installed"
    return 1
  fi
}

oc_scan_aur_cache() {
  local name
  for name in "${OC_AUR_CACHE_NAMES[@]}"; do
    [[ -d $OC_CACHE_HOME/$name ]] && oc_emit_path "$OC_CACHE_HOME/$name" "$name"
  done
  return 0
}

# --- downloaded-assets ------------------------------------------------------

oc_scan_downloaded_assets() {
  local name
  for name in "${OC_ASSET_CACHE_NAMES[@]}"; do
    [[ -d $OC_CACHE_HOME/$name && ! -L $OC_CACHE_HOME/$name ]] && oc_emit_path "$OC_CACHE_HOME/$name" "$name"
  done
  return 0
}

# --- trash ------------------------------------------------------------------

oc_scan_trash() {
  local trash="$OC_DATA_HOME/Trash" sub dir
  for sub in files info expunged; do
    [[ -d $trash/$sub ]] && oc_emit_path "$trash/$sub" "Trash ($sub)"
  done
  # Trash folders on removable / mounted drives (.Trash-UID at their root).
  for dir in /run/media/"$USER"/*/.Trash-"$UID" /media/*/.Trash-"$UID"; do
    [[ -d $dir ]] || continue
    for sub in files info expunged; do
      [[ -d $dir/$sub ]] && oc_emit_path "$dir/$sub" "$(basename -- "$(dirname -- "$dir")") trash ($sub)"
    done
  done
  return 0
}

# --- pacman-cache (root) ----------------------------------------------------

oc_avail_pacman_cache() {
  command -v paccache >/dev/null 2>&1 || { echo "paccache not found (install pacman-contrib)"; return 1; }
}

# Sum "disk space saved" from a paccache dry run.
oc_paccache_dry_bytes() {
  local out size
  out=$(paccache -d "$@" 2>/dev/null | tail -n1) || true
  size=$(sed -n 's/.*disk space saved: \(.*\))/\1/p' <<<"$out")
  if [[ -n $size ]]; then oc_to_bytes "$size"; else echo 0; fi
}

oc_scan_pacman_cache() {
  local keep old uninstalled
  keep=$(oc_config_get pacmanKeep 2)
  old=$(oc_paccache_dry_bytes -k "$keep")
  uninstalled=$(oc_paccache_dry_bytes -uk0)
  ((old > 0)) && oc_emit "$old" "pacman-cache:old" "Old versions (keeping the last $keep)"
  ((uninstalled > 0)) && oc_emit "$uninstalled" "pacman-cache:uninstalled" "Packages that are no longer installed"
  return 0
}

oc_verbs_pacman_cache() { echo "pacman-cache $(oc_config_get pacmanKeep 2)"; }

# --- journal (root) ---------------------------------------------------------

oc_avail_journal() {
  command -v journalctl >/dev/null 2>&1 || { echo "journalctl not found"; return 1; }
}

oc_scan_journal() {
  local usage max reclaim
  usage=$(journalctl --disk-usage 2>/dev/null | sed -n 's/.*take up \([0-9.]*[A-Za-z]*\) .*/\1/p') || true
  usage=$(oc_to_bytes "${usage:-0}")
  max=$(($(oc_config_get journalMaxMB 200) * 1048576))
  reclaim=$((usage > max ? usage - max : 0))
  ((reclaim > 0)) && oc_emit "$reclaim" "journal:vacuum" "Journal archives above $(oc_human "$max")"
  return 0
}

oc_verbs_journal() { echo "journal $(oc_config_get journalMaxMB 200)"; }

# --- coredumps (root) -------------------------------------------------------

oc_scan_coredumps() {
  local dir=/var/lib/systemd/coredump count bytes
  [[ -d $dir ]] || return 0
  count=$(find "$dir" -maxdepth 1 -type f -name 'core.*' 2>/dev/null | wc -l)
  bytes=$(find "$dir" -maxdepth 1 -type f -name 'core.*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
  ((count > 0)) && oc_emit "$bytes" "coredumps:all" "$count crash dump(s)"
  return 0
}

oc_verbs_coredumps() { echo "coredumps"; }

# --- orphans (root) ---------------------------------------------------------

oc_avail_orphans() {
  command -v pacman >/dev/null 2>&1 || { echo "pacman not found"; return 1; }
}

oc_scan_orphans() {
  local -a pkgs
  mapfile -t pkgs < <(pacman -Qdtq 2>/dev/null)
  ((${#pkgs[@]} > 0)) || return 0
  LC_ALL=C pacman -Qi "${pkgs[@]}" 2>/dev/null | awk -F' *: ' '
    /^Name/ { name = $2 }
    /^Installed Size/ { gsub(/ /, "", $2); print name "\t" $2 }
  ' | while IFS=$'\t' read -r name size; do
    oc_emit "$(oc_to_bytes "$size")" "pkg:$name" "$name"
  done
}

oc_verbs_orphans() { echo "orphans"; }

# --- snapper (root) ---------------------------------------------------------

oc_avail_snapper() {
  command -v snapper >/dev/null 2>&1 || { echo "snapper is not installed"; return 1; }
}

oc_scan_snapper() {
  local count
  # Listing usually needs root; fall back to a single cleanup item.
  count=$(snapper --jsonout -c root list 2>/dev/null | jq '[.root[]? | select(.cleanup == "number")] | length' 2>/dev/null) || count=""
  if [[ -n $count ]]; then
    ((count > 0)) && oc_emit 0 "snapper:root" "$count snapshot(s) managed by the number cleanup rule"
  else
    oc_emit 0 "snapper:root" "Apply snapper's retention rules (size unknown until cleaned)"
  fi
  return 0
}

oc_verbs_snapper() { echo "snapper"; }

# --- docker (command) -------------------------------------------------------

oc_avail_docker() {
  command -v docker >/dev/null 2>&1 || { echo "docker is not installed"; return 1; }
  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable (not running, or user not in the docker group)"; return 1; }
}

oc_scan_docker() {
  local type reclaim
  while IFS=$'\t' read -r type reclaim; do
    [[ $type == "Local Volumes" ]] && continue
    reclaim=$(oc_to_bytes "${reclaim%% *}")
    ((reclaim > 0)) && oc_emit "$reclaim" "docker:${type// /-}" "$type"
  done < <(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)
  return 0
}

oc_clean_docker() {
  docker system prune --force >/dev/null
}

# --- broken-entries ---------------------------------------------------------

# Prints the program a .desktop file launches (its first Exec= line).
# TryExec is deliberately ignored: a failing TryExec only hides an entry,
# while its Exec may still work (common with AppImage integrations).
oc_desktop_program() {
  local file=$1 line prog
  line=$(grep -m1 '^Exec=' "$file" 2>/dev/null | cut -d= -f2-) || true
  [[ -z $line ]] && return 1
  # Skip "env VAR=value ..." prefixes and quotes.
  read -r -a words <<<"$line"
  local i=0
  [[ ${words[0]:-} == env || ${words[0]:-} == */env ]] && i=1
  while [[ ${words[i]:-} == *=* && ${words[i]:-} != /* ]]; do i=$((i + 1)); done
  prog=${words[i]:-}
  prog=${prog#\"}
  prog=${prog%\"}
  [[ -n $prog ]] && echo "$prog"
}

oc_scan_broken_entries() {
  local file prog
  for file in "$OC_DATA_HOME"/applications/*.desktop "$HOME"/.config/autostart/*.desktop; do
    [[ -f $file && ! -L $file ]] || continue
    prog=$(oc_desktop_program "$file") || continue
    [[ -z $prog ]] && continue
    if [[ $prog == /* ]]; then
      [[ -x $prog ]] && continue
    else
      command -v "$prog" >/dev/null 2>&1 && continue
    fi
    oc_is_ignored "$file" && continue
    oc_emit "$(stat -c %s "$file")" "$file" "$(basename -- "$file") → missing $prog"
  done
  return 0
}

# --- large-files ------------------------------------------------------------

oc_scan_large_files() {
  local min_mb
  min_mb=$(oc_config_get largeFileMinMB 1024)
  [[ $min_mb =~ ^[0-9]+$ ]] || min_mb=1024
  # Only visible top-level folders of $HOME: hidden directories belong to
  # applications and are covered by the cache modules.
  find "$HOME" -xdev -mindepth 1 \
    \( -path "$HOME/.*" -o -name node_modules -o -name .git \) -prune -o \
    -type f -size +"${min_mb}"M -printf '%s\t%p\t%TY-%Tm-%Td\n' 2>/dev/null |
    sort -rn |
    while IFS=$'\t' read -r bytes path date; do
      oc_is_ignored "$path" && continue
      oc_emit "$bytes" "$path" "${path#"$HOME"/} (modified $date)"
    done
}

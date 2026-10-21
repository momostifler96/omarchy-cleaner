#!/bin/bash
# shellcheck shell=bash
#
# Shared helpers for omarchy-cleaner: logging, paths, configuration, ignore
# list, size parsing and the guarded deletion primitives every module uses.
#
# This file is sourced by bin/omarchy-cleaner; it never runs on its own.

# ---------------------------------------------------------------------------
# Locations (XDG-aware). Nothing here is created until it is actually needed.
# ---------------------------------------------------------------------------
OC_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-cleaner"
OC_CONFIG_FILE="$OC_CONFIG_DIR/config.json"
OC_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-cleaner"
OC_LAST_SCAN="$OC_STATE_DIR/last-scan.json"
OC_HISTORY="$OC_STATE_DIR/history.jsonl"
OC_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
OC_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# shellcheck disable=SC2034 # used by bin/omarchy-cleaner
OC_LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/omarchy-cleaner-$UID.lock"

# Set by the CLI from --json / --quiet.
OC_JSON=${OC_JSON:-0}
OC_QUIET=${OC_QUIET:-0}

# ---------------------------------------------------------------------------
# Logging. Human messages go to stderr so stdout stays clean for --json.
# Prefixes follow the Omarchy convention: "==>" step, "  -" done, "  !" warning.
# ---------------------------------------------------------------------------
oc_step() { [[ $OC_QUIET == 1 ]] || printf '==> %s\n' "$*" >&2; }
oc_info() { [[ $OC_QUIET == 1 ]] || printf '  - %s\n' "$*" >&2; }
oc_warn() { printf '  ! %s\n' "$*" >&2; }
oc_die() {
  local code=${2:-1}
  if [[ $OC_JSON == 1 ]]; then
    jq -cn --arg error "$1" --argjson code "$code" '{ok:false,error:$error,code:$code}'
  else
    printf 'omarchy-cleaner: %s\n' "$1" >&2
  fi
  exit "$code"
}

oc_require() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || oc_die "required command not found: $bin"
  done
}

# Human-readable size (IEC) for a byte count.
oc_human() {
  numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"
}

# Convert sizes printed by other tools to bytes:
#   "830.2 MiB" (paccache), "1.2GB" / "12kB" (docker, decimal),
#   "1.4G" / "512K" (journalctl, du -h: single-letter units are binary).
# Prints 0 for anything it cannot parse.
oc_to_bytes() {
  local raw="${1//[[:space:]]/}"
  [[ $raw =~ ^([0-9]+([.][0-9]+)?)([A-Za-z]*)$ ]] || { echo 0; return; }
  local num=${BASH_REMATCH[1]} unit=${BASH_REMATCH[3]} mult
  case "${unit,,}" in
    '' | b) mult=1 ;;
    kb) mult=1000 ;;
    k | kib) mult=1024 ;;
    mb) mult=1000000 ;;
    m | mib) mult=1048576 ;;
    gb) mult=1000000000 ;;
    g | gib) mult=1073741824 ;;
    tb) mult=1000000000000 ;;
    t | tib) mult=1099511627776 ;;
    *) echo 0; return ;;
  esac
  awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f\n", n * m }'
}

# Apparent size in bytes of a file or directory tree, without crossing
# filesystems. Unreadable sub-entries are skipped rather than failing.
oc_path_bytes() {
  local out
  out=$(du -sb --one-file-system -- "$1" 2>/dev/null | cut -f1) || true
  echo "${out:-0}"
}

# ---------------------------------------------------------------------------
# Configuration (optional). The file is only written by explicit commands such
# as `ignore add` or `config set`; defaults apply when it does not exist.
# ---------------------------------------------------------------------------
oc_config_get() {
  local key=$1 fallback=$2 value=""
  if [[ -f $OC_CONFIG_FILE ]]; then
    value=$(jq -r --arg k "$key" '.[$k] // empty | tostring' "$OC_CONFIG_FILE" 2>/dev/null) || value=""
  fi
  echo "${value:-$fallback}"
}

oc_config_write() {
  # $1 = jq filter applied to the current config (or {} when absent).
  mkdir -p "$OC_CONFIG_DIR"
  local current='{}' tmp
  [[ -f $OC_CONFIG_FILE ]] && current=$(cat "$OC_CONFIG_FILE")
  tmp=$(mktemp "$OC_CONFIG_DIR/.config.XXXXXX")
  if ! jq "${@:2}" "$1" <<<"$current" >"$tmp"; then
    rm -f "$tmp"
    oc_die "could not update $OC_CONFIG_FILE"
  fi
  mv -f "$tmp" "$OC_CONFIG_FILE"
}

# Prints one ignore-list entry per line (absolute paths or globs, ~ expanded,
# trailing slashes removed).
oc_ignore_list() {
  [[ -f $OC_CONFIG_FILE ]] || return 0
  jq -r '.ignore // [] | .[]' "$OC_CONFIG_FILE" 2>/dev/null | sed -e "s|^~|$HOME|" -e 's|/*$||' | grep -v '^$' || true
}

# The ignore list is read once per process; deletion walks consult it often.
OC_IGNORE=()
OC_IGNORE_LOADED=0
oc_ignore_load() {
  ((OC_IGNORE_LOADED == 1)) && return 0
  mapfile -t OC_IGNORE < <(oc_ignore_list)
  OC_IGNORE_LOADED=1
}

oc_is_glob() { [[ $1 == *[\*?[]* ]]; }

# True when a path is covered by the ignore list: equal to an entry, inside
# an entry, or matching an entry used as a glob.
oc_is_ignored() {
  local path=$1 entry
  oc_ignore_load
  for entry in "${OC_IGNORE[@]}"; do
    # shellcheck disable=SC2053 # glob matching is intended
    if [[ $path == "$entry" || $path == "$entry"/* || $path == $entry ]]; then
      return 0
    fi
  done
  return 1
}

# True when something inside the directory $1 is covered by the ignore list,
# i.e. removing $1 recursively would also remove an excluded path. Literal
# entries are compared as paths; glob entries are searched for with find
# (whose -path glob, like [[ == ]], lets * match across "/").
oc_has_ignored_descendant() {
  local dir=$1 entry
  oc_ignore_load
  ((${#OC_IGNORE[@]} > 0)) || return 1
  [[ -d $dir && ! -L $dir ]] || return 1
  for entry in "${OC_IGNORE[@]}"; do
    if oc_is_glob "$entry"; then
      [[ -n $(find "$dir" -xdev -mindepth 1 -path "$entry" -print -quit 2>/dev/null) ]] && return 0
    elif [[ $entry == "$dir"/* ]]; then
      return 0
    fi
  done
  return 1
}

# Remove everything inside $1 except ignored paths. Entries that contain an
# ignored path are descended into instead of being removed wholesale, so an
# exclusion deep inside a cache folder survives along with its parents.
oc_prune_tree() {
  local dir=$1 child failed=0
  while IFS= read -r -d '' child; do
    if oc_is_ignored "$child"; then
      continue
    elif oc_has_ignored_descendant "$child"; then
      oc_prune_tree "$child" || failed=1
    else
      rm -rf --one-file-system -- "$child" 2>/dev/null || failed=1
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  return "$failed"
}

# Apparent size of a path minus whatever the ignore list protects inside it,
# so scans report what a clean would actually free.
oc_reclaimable_bytes() {
  local path=$1 total protected=0 entry match
  total=$(oc_path_bytes "$path")
  if oc_has_ignored_descendant "$path"; then
    for entry in "${OC_IGNORE[@]}"; do
      if oc_is_glob "$entry"; then
        while IFS= read -r -d '' match; do
          # Count each protected match once (skip ones inside another match).
          [[ -n $match ]] && protected=$((protected + $(oc_path_bytes "$match")))
        done < <(find "$path" -xdev -mindepth 1 -path "$entry" -prune -print0 2>/dev/null)
      elif [[ $entry == "$path"/* && -e $entry ]]; then
        protected=$((protected + $(oc_path_bytes "$entry")))
      fi
    done
  fi
  total=$((total - protected))
  echo $((total > 0 ? total : 0))
}

# ---------------------------------------------------------------------------
# Guarded deletion. Every user-level removal goes through these helpers, which
# refuse anything outside $HOME (or a mounted volume's own trash), the home
# directory itself, top-level XDG directories, and ignored paths.
# ---------------------------------------------------------------------------
oc_path_allowed() {
  local p=$1
  [[ $p == /* ]] || return 1
  [[ $p != *"/../"* && $p != *"/.." && $p != *"/./"* ]] || return 1
  case "$p" in
    "$HOME" | "$HOME/" | "$OC_CACHE_HOME" | "$OC_DATA_HOME" | "$HOME/.config" | "$HOME/.local" | "$OC_CONFIG_DIR"*) return 1 ;;
    "$HOME"/* | "/run/media/$USER"/*/.Trash-"$UID"/* | /media/*/.Trash-"$UID"/*) ;;
    *) return 1 ;;
  esac
  oc_is_ignored "$p" && return 1
  return 0
}

# Remove the contents of a directory but keep the directory itself (and its
# permissions), so applications that hold it open keep working. Ignored paths
# anywhere inside are kept (see oc_prune_tree).
oc_empty_dir() {
  local dir=$1
  oc_path_allowed "$dir" || { oc_warn "refused (protected path): $dir"; return 1; }
  [[ -d $dir && ! -L $dir ]] || return 0
  oc_prune_tree "$dir" || {
    oc_warn "some entries could not be removed in $dir"
    return 1
  }
}

# Remove a file or a whole directory tree. Symlinks are removed, never followed.
# A directory that contains an ignored path is pruned instead: everything
# else goes, the excluded path and its parent folders stay.
oc_delete() {
  local p=$1
  oc_path_allowed "$p" || { oc_warn "refused (protected path): $p"; return 1; }
  [[ -e $p || -L $p ]] || return 0
  if oc_has_ignored_descendant "$p"; then
    oc_prune_tree "$p" || { oc_warn "some entries could not be removed in $p"; return 1; }
    return 0
  fi
  rm -rf --one-file-system -- "$p" 2>/dev/null || { oc_warn "could not remove $p"; return 1; }
}

# Move a path to the user's Trash following the freedesktop.org Trash spec,
# so the user can restore it from any file manager.
oc_trash() {
  local p=$1
  oc_path_allowed "$p" || { oc_warn "refused (protected path): $p"; return 1; }
  [[ -e $p || -L $p ]] || return 0
  # Moving a folder would carry an excluded path along with it; refuse.
  if oc_has_ignored_descendant "$p"; then
    oc_warn "refused: $p contains a path from your ignore list"
    return 1
  fi
  if command -v gio >/dev/null 2>&1 && gio trash -- "$p" 2>/dev/null; then
    return 0
  fi
  local trash="$OC_DATA_HOME/Trash" base name n=1 encoded
  mkdir -p "$trash/files" "$trash/info"
  base=$(basename -- "$p")
  name=$base
  while [[ -e $trash/files/$name || -e $trash/info/$name.trashinfo ]]; do
    name="$base.$n"
    n=$((n + 1))
  done
  encoded=$(jq -rn --arg p "$p" '$p | @uri | gsub("%2F"; "/")')
  printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$encoded" "$(date +%Y-%m-%dT%H:%M:%S)" \
    >"$trash/info/$name.trashinfo"
  mv -- "$p" "$trash/files/$name" || {
    rm -f "$trash/info/$name.trashinfo"
    oc_warn "could not move $p to Trash"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Item emission. A module scan prints one item per line as
#   <bytes>\t<path-or-pseudo-path>\t<label>
# Path-based items that are ignored or empty are filtered out here.
# ---------------------------------------------------------------------------
oc_emit() {
  local bytes=$1 path=$2 label=$3
  [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
  printf '%s\t%s\t%s\n' "$bytes" "$path" "$label"
}

oc_emit_path() {
  local path=$1 label=${2:-$(basename -- "$1")} bytes
  [[ -e $path ]] || return 0
  oc_is_ignored "$path" && return 0
  bytes=$(oc_reclaimable_bytes "$path")
  ((bytes > 0)) || return 0
  oc_emit "$bytes" "$path" "$label"
}

# ---------------------------------------------------------------------------
# State: last scan + clean history (used by the bar widget and `history`).
# ---------------------------------------------------------------------------
oc_state_write() {
  mkdir -p "$OC_STATE_DIR"
  local tmp
  tmp=$(mktemp "$OC_STATE_DIR/.scan.XXXXXX")
  cat >"$tmp"
  mv -f "$tmp" "$OC_LAST_SCAN"
}

oc_history_append() {
  mkdir -p "$OC_STATE_DIR"
  printf '%s\n' "$1" >>"$OC_HISTORY"
}

# Ask for confirmation on a terminal; refuse (exit 3) when nobody can answer.
oc_confirm() {
  local prompt=$1
  [[ ${OC_YES:-0} == 1 ]] && return 0
  if [[ ! -t 0 || ! -t 2 ]]; then
    oc_die "refusing to clean without a terminal; pass --yes to confirm" 3
  fi
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    local answer
    read -r -p "$prompt [y/N] " answer
    [[ $answer == [yY]* ]]
  fi
}

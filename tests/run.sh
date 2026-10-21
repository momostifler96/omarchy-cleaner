#!/bin/bash
#
# Test suite for omarchy-cleaner. Runs entirely inside a throw-away fake $HOME,
# never touches the real system, and needs no test framework.
#
#   tests/run.sh            run every test
#   tests/run.sh -v         also print the CLI output of failing tests
#
# Root modules (pacman-cache, journal, …) are only exercised through `scan` and
# `clean --dry-run`, which never call pkexec.

set -uo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
CLI="$REPO/bin/omarchy-cleaner"
HELPER="$REPO/bin/omarchy-cleaner-root"
VERBOSE=0
[[ ${1:-} == -v ]] && VERBOSE=1

PASS=0
FAIL=0
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-cleaner-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

ok() { PASS=$((PASS + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
ko() {
  FAIL=$((FAIL + 1))
  printf '  \e[31m✗\e[0m %s\n' "$1"
  [[ $VERBOSE == 1 && -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/      /'
}

# Fresh fake home for each test group.
new_home() {
  export HOME="$SANDBOX/home-$RANDOM$RANDOM"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME
  export XDG_RUNTIME_DIR="$SANDBOX"
}

cli() { "$CLI" "$@" 2>/dev/null; }

mkfile() {
  # mkfile PATH SIZE_KB
  mkdir -p "$(dirname "$1")"
  head -c "$(($2 * 1024))" /dev/zero >"$1"
}

echo "==> Syntax"
for f in "$CLI" "$HELPER" "$REPO"/lib/*.sh "$0"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else ko "bash -n $(basename "$f")"; fi
done

echo "==> Manifest"
if command -v omarchy-plugin-validate >/dev/null 2>&1 || [[ -x /usr/share/omarchy/bin/omarchy-plugin-validate ]]; then
  validator=$(command -v omarchy-plugin-validate || echo /usr/share/omarchy/bin/omarchy-plugin-validate)
  if out=$("$validator" "$REPO" 2>&1); then ok "omarchy plugin validate"; else ko "omarchy plugin validate" "$out"; fi
else
  echo "  (omarchy-plugin-validate not available, skipped)"
fi
jq -e '.schemaVersion == 1 and (.id | startswith("omarchy.") | not)' "$REPO/manifest.json" >/dev/null &&
  ok "manifest schemaVersion and id namespace" || ko "manifest schemaVersion and id namespace"
[[ -z $(find "$REPO" -name .git -prune -o -type l -print -quit) ]] && ok "no symlinks in plugin folder" || ko "no symlinks in plugin folder"

echo "==> CLI basics"
new_home
[[ $(cli version) == "$(jq -r .version "$REPO/manifest.json")" ]] && ok "version matches manifest" || ko "version matches manifest"
cli modules --json | jq -e 'length == 13 and all(has("id") and has("risk"))' >/dev/null && ok "modules --json" || ko "modules --json"
cli tasks --json | jq -e 'length == 5' >/dev/null && ok "tasks --json" || ko "tasks --json"
"$CLI" scan nope >/dev/null 2>&1; [[ $? == 2 ]] && ok "unknown module exits 2" || ko "unknown module exits 2"
"$CLI" frobnicate >/dev/null 2>&1; [[ $? == 2 ]] && ok "unknown command exits 2" || ko "unknown command exits 2"
cli status --json | jq -e '.scanned == false' >/dev/null && ok "status before any scan" || ko "status before any scan"

echo "==> Unit helpers"
# shellcheck source=../lib/common.sh
( source "$REPO/lib/common.sh"
  [[ $(oc_to_bytes "830.2 MiB") == 870527795 ]] && echo "MiB ok"
  [[ $(oc_to_bytes "1.5GB") == 1500000000 ]] && echo "GB ok"
  [[ $(oc_to_bytes "1.4G") == 1503238554 ]] && echo "G ok"
  [[ $(oc_to_bytes "12kB") == 12000 ]] && echo "kB ok"
  [[ $(oc_to_bytes "garbage") == 0 ]] && echo "garbage ok"
) >"$SANDBOX/units" 2>&1
[[ $(wc -l <"$SANDBOX/units") == 5 ]] && ok "oc_to_bytes units" || ko "oc_to_bytes units" "$(cat "$SANDBOX/units")"

( source "$REPO/lib/common.sh"
  HOME=/home/tester OC_CACHE_HOME=/home/tester/.cache OC_DATA_HOME=/home/tester/.local/share OC_CONFIG_FILE=/nonexistent
  for p in / /etc/passwd /home/tester /home/tester/ /home/tester/.cache /home/tester/.local/share /home/tester/../root/x relative/path; do
    oc_path_allowed "$p" && echo "ALLOWED $p"
  done
  oc_path_allowed /home/tester/.cache/foo && echo "CHILD-ALLOWED"
) >"$SANDBOX/guards" 2>&1
[[ $(cat "$SANDBOX/guards") == "CHILD-ALLOWED" ]] && ok "path guards: protected paths refused, children allowed" ||
  ko "path guards: protected paths refused, children allowed" "$(cat "$SANDBOX/guards")"

echo "==> user-cache / dev-cache / aur-cache"
new_home
mkfile "$HOME/.cache/someapp/blob" 64
mkfile "$HOME/.cache/thumbnails/large/a.png" 32
mkfile "$HOME/.cache/pip/http/x" 16
mkfile "$HOME/.cache/yay/pkg/PKGBUILD" 8
mkfile "$HOME/.cache/huggingface/model.bin" 128
mkfile "$HOME/.cache/omarchy/state" 4
mkfile "$HOME/.cache/quickshell/qmlcache" 4
mkfile "$HOME/.cache/nvim.bak/init.lua" 4
mkfile "$HOME/.npm/_cacache/index" 16
scan=$(cli scan user-cache dev-cache downloaded-assets --json --details)
jq -e '.modules[] | select(.id == "user-cache") | (.items | map(.label)) as $l
  | ($l | index("someapp")) and ($l | index("thumbnails"))
  and (($l | index("omarchy")) | not) and (($l | index("quickshell")) | not)
  and (($l | index("nvim.bak")) | not) and (($l | index("pip")) | not)
  and (($l | index("huggingface")) | not)' <<<"$scan" >/dev/null &&
  ok "user-cache skips protected and claimed folders" || ko "user-cache skips protected and claimed folders" "$scan"
jq -e '.modules[] | select(.id == "dev-cache") | .items | map(.path) | (index("'"$HOME"'/.cache/pip") and index("'"$HOME"'/.npm/_cacache"))' <<<"$scan" >/dev/null &&
  ok "dev-cache finds pip and npm" || ko "dev-cache finds pip and npm" "$scan"
jq -e '.modules[] | select(.id == "downloaded-assets") | .count == 1' <<<"$scan" >/dev/null &&
  ok "downloaded-assets finds huggingface" || ko "downloaded-assets finds huggingface" "$scan"

"$CLI" clean user-cache --dry-run --json 2>/dev/null | jq -e '.dryRun and .plannedBytes > 0' >/dev/null &&
  [[ -f $HOME/.cache/someapp/blob ]] && ok "dry-run changes nothing" || ko "dry-run changes nothing"

"$CLI" clean user-cache </dev/null >/dev/null 2>&1; [[ $? == 3 ]] && ok "clean without terminal or --yes is refused (exit 3)" || ko "clean without terminal or --yes is refused (exit 3)"

res=$("$CLI" clean user-cache --yes --json 2>/dev/null)
if [[ ! -e $HOME/.cache/someapp/blob && -d $HOME/.cache/someapp && ! -e $HOME/.cache/thumbnails/large ]] &&
   [[ -f $HOME/.cache/omarchy/state && -f $HOME/.cache/quickshell/qmlcache && -f $HOME/.cache/nvim.bak/init.lua ]] &&
   [[ -f $HOME/.cache/pip/http/x && -f $HOME/.cache/huggingface/model.bin ]]; then
  ok "clean user-cache empties caches, keeps protected ones"
else
  ko "clean user-cache empties caches, keeps protected ones" "$res"
fi
jq -e '.ok and .freedBytes > 0' <<<"$res" >/dev/null && ok "clean --json reports freed bytes" || ko "clean --json reports freed bytes" "$res"
[[ -s $HOME/.local/state/omarchy-cleaner/history.jsonl ]] && ok "history is recorded" || ko "history is recorded"

echo "==> Ignore list"
new_home
mkfile "$HOME/.cache/keepme/data" 16
mkfile "$HOME/.cache/dropme/data" 16
cli ignore add "$HOME/.cache/keepme" >/dev/null
cli ignore list | grep -qx "$HOME/.cache/keepme" && ok "ignore add/list" || ko "ignore add/list"
"$CLI" clean user-cache --yes >/dev/null 2>&1
[[ -f $HOME/.cache/keepme/data && ! -f $HOME/.cache/dropme/data ]] && ok "ignored path survives clean" || ko "ignored path survives clean"
cli ignore remove "$HOME/.cache/keepme" >/dev/null
cli ignore list | grep -q keepme && ko "ignore remove" || ok "ignore remove"

echo "==> Trash"
new_home
mkfile "$HOME/.local/share/Trash/files/old.txt" 16
mkdir -p "$HOME/.local/share/Trash/info"
printf '[Trash Info]\nPath=/x\n' >"$HOME/.local/share/Trash/info/old.txt.trashinfo"
"$CLI" clean trash --yes >/dev/null 2>&1
[[ -d $HOME/.local/share/Trash/files && -z $(ls -A "$HOME/.local/share/Trash/files") ]] && ok "trash emptied, folder kept" || ko "trash emptied, folder kept"

mkfile "$HOME/Videos/big.mkv" 2048
cli config set largeFileMinMB 1 >/dev/null
cli scan large-files --json | jq -e '.modules[0].count == 1' >/dev/null && ok "large-files threshold from config" || ko "large-files threshold from config"
"$CLI" clean large-files --yes --json 2>/dev/null | jq -e '.modules[0].skipped == true' >/dev/null &&
  [[ -f $HOME/Videos/big.mkv ]] && ok "large-files is never bulk-cleaned" || ko "large-files is never bulk-cleaned"
XDG_DATA_HOME="$HOME/.local/share" PATH="/usr/bin:/bin" "$CLI" trash "$HOME/Videos/big.mkv" --yes >/dev/null 2>&1
trashed=("$HOME"/.local/share/Trash/files/big.mkv*)
[[ ! -e $HOME/Videos/big.mkv && -e ${trashed[0]} ]] && ok "trash PATH moves a file to Trash" || ko "trash PATH moves a file to Trash"
"$CLI" trash /etc/hostname --yes >/dev/null 2>&1; [[ $? != 0 && -f /etc/hostname ]] && ok "trash refuses paths outside \$HOME" || ko "trash refuses paths outside \$HOME"

echo "==> Broken launchers"
new_home
mkdir -p "$HOME/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Gone\nExec=/nonexistent/bin/gone %%U\n' >"$HOME/.local/share/applications/gone.desktop"
printf '[Desktop Entry]\nType=Application\nName=Fine\nTryExec=not-on-path\nExec=env FOO=1 bash -c true\n' >"$HOME/.local/share/applications/fine.desktop"
scan=$(cli scan broken-entries --json --details)
jq -e '.modules[0].items | map(.path) | (any(endswith("gone.desktop")) and (any(endswith("fine.desktop")) | not))' <<<"$scan" >/dev/null &&
  ok "detects missing Exec, ignores TryExec and env prefixes" || ko "detects missing Exec, ignores TryExec and env prefixes" "$scan"

echo "==> Config"
new_home
cli config set journalMaxMB 300 >/dev/null && [[ $(cli config get journalMaxMB) == 300 ]] && ok "config set/get" || ko "config set/get"
"$CLI" config set journalMaxMB abc >/dev/null 2>&1; [[ $? == 2 ]] && ok "config rejects non-numbers" || ko "config rejects non-numbers"
"$CLI" config set selection '["nope"]' >/dev/null 2>&1; [[ $? == 2 ]] && ok "config rejects unknown modules in selection" || ko "config rejects unknown modules in selection"
cli config set selection '["trash"]' >/dev/null
"$CLI" clean --defaults --dry-run --json 2>/dev/null | jq -e '[.modules[].id] == ["trash"] or (.modules | length) == 0' >/dev/null &&
  ok "--defaults honours saved selection" || ko "--defaults honours saved selection"

echo "==> Root helper"
"$HELPER" coredumps >/dev/null 2>&1; [[ $? == 1 ]] && ok "helper refuses to run without root" || ko "helper refuses to run without root"
grep -q 'unknown verb' "$HELPER" && grep -q 'number_arg' "$HELPER" && ok "helper validates verbs and numbers" || ko "helper validates verbs and numbers"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))

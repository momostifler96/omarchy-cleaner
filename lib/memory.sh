#!/bin/bash
# shellcheck shell=bash
#
# Memory view for omarchy-cleaner: RAM/swap figures, memory per application,
# and stuck processes, plus the guarded "quit" actions.
#
# Memory per process is PSS (proportional set size, from
# /proc/PID/smaps_rollup): shared pages are split between the processes that
# share them, so summing PSS over an application gives an honest total.
# Only your own processes are readable, which is also exactly the set you
# are allowed to quit.
#
# Processes are grouped by their systemd unit (the cgroup leaf). Under uwsm,
# every app launched from Omarchy runs in its own app-*.scope, so a browser and
# all its helper processes form one group. Commands started from a terminal
# belong to that terminal's group; expand it to see and quit them one by one.
#
# Quitting an application sends SIGTERM to its whole unit through
# `systemctl --user kill`, so the app can save its state and exit cleanly.
# --force sends SIGKILL instead.

# Session components that are never offered for quitting. Names are compared
# case-insensitively against the group name and its main process.
OC_PROTECTED_PROCESSES=(hyprland quickshell qs omarchy-shell uwsm waybar mako walker elephant hypridle hyprsunset hyprpaper swaybg swayosd-server fcitx5 systemd dbus-broker pipewire wireplumber pipewire-pulse xdg-desktop-portal xdg-desktop-portal-hyprland)

# Launcher names that appear in unit names but are not the app itself.
OC_LAUNCHER_NAMES='^(gtk-launch|xdg-terminal-exec|uwsm-app|app2unit|launch|exec|run)$'

oc_is_protected_name() {
  local name=${1,,} p
  for p in "${OC_PROTECTED_PROCESSES[@]}"; do
    [[ $name == "$p" ]] && return 0
  done
  return 1
}

# RAM and swap figures from /proc/meminfo, as a JSON object.
oc_meminfo_json() {
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemFree:/      { free = $2 }
    /^MemAvailable:/ { avail = $2 }
    /^Buffers:/      { buffers = $2 }
    /^Cached:/       { cached = $2 }
    /^SReclaimable:/ { sreclaim = $2 }
    /^Shmem:/        { shmem = $2 }
    /^SwapTotal:/    { stotal = $2 }
    /^SwapFree:/     { sfree = $2 }
    END {
      cache = buffers + cached + sreclaim - shmem
      if (cache < 0) cache = 0
      printf "{\"ram\":{\"totalBytes\":%.0f,\"usedBytes\":%.0f,\"availableBytes\":%.0f,\"freeBytes\":%.0f,\"cacheBytes\":%.0f},", \
        total * 1024, (total - avail) * 1024, avail * 1024, free * 1024, cache * 1024
      printf "\"swap\":{\"totalBytes\":%.0f,\"usedBytes\":%.0f}}\n", stotal * 1024, (stotal - sfree) * 1024
    }' /proc/meminfo
}

# One line per readable process: pid, pss bytes, state, cgroup leaf, comm.
# Unreadable files (other users' processes, vanished PIDs) are skipped with
# gawk's BEGINFILE/ERRNO (plain awk would abort on the first one).
oc_process_table() {
  gawk '
    BEGINFILE { if (ERRNO != "") nextfile; n = split(FILENAME, parts, "/"); pid = parts[3]; kind = parts[4] }
    kind == "smaps_rollup" && /^Pss:/ { pss[pid] = $2 * 1024 }
    kind == "cgroup" { line = $0; sub(/^0::/, "", line); m = split(line, c, "/"); unit[pid] = c[m] }
    kind == "comm" { comm[pid] = $0 }
    kind == "stat" { s = $0; sub(/^.*\) /, "", s); state[pid] = substr(s, 1, 1) }
    END {
      for (p in state) {
        if (!(p in pss) && state[p] !~ /[DTZ]/) continue
        printf "%s\t%.0f\t%s\t%s\t%s\n", p, pss[p] + 0, state[p], unit[p], comm[p]
      }
    }' /proc/[0-9]*/smaps_rollup /proc/[0-9]*/cgroup /proc/[0-9]*/comm /proc/[0-9]*/stat 2>/dev/null
}

# Full memory report as JSON (see docs/CLI.md "memory").
oc_memory_json() {
  local limit=${1:-10} self_unit table protected_json
  self_unit=$(awk -F'::' '{n = split($2, c, "/"); print c[n]}' /proc/$$/cgroup 2>/dev/null)
  # Keep only processes owned by the current user.
  table=$(oc_process_table | while IFS=$'\t' read -r pid pss state unit comm; do
    [[ -O /proc/$pid ]] && printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$pss" "$state" "$unit" "$comm"
  done)
  protected_json=$(printf '%s\n' "${OC_PROTECTED_PROCESSES[@]}" | jq -R . | jq -cs .)

  jq -cn \
    --argjson mem "$(oc_meminfo_json)" \
    --arg table "$table" \
    --arg self "$self_unit" \
    --arg launchers "$OC_LAUNCHER_NAMES" \
    --argjson protected "$protected_json" \
    --argjson limit "$limit" '
    def decode: gsub("\\\\x2d"; "-") | gsub("\\\\x2e"; ".") | gsub("\\\\x5f"; "_");
    # Human name from a unit like app-Hyprland-google\x2dchrome\x2dstable-ea0af70c.scope
    def unit_name:
      if test("^app-.+\\.(scope|service)$") then
        sub("^app-"; "") | sub("\\.(scope|service)$"; "") | sub("@.*$"; "")
        | sub("^(Hyprland|hyprland|niri|sway)-"; "")
        | sub("-[0-9a-f]{6,}$"; "") | sub("-[0-9]+$"; "")
        | decode
        | if test("^[a-z]+\\.[^.]+\\..+") then split(".") | last else . end
      else "" end;

    ($table | split("\n") | map(select(length > 0) | split("\t")
      | {pid: (.[0] | tonumber), bytes: (.[1] | tonumber), state: .[2], unit: .[3], comm: (.[4] // "")})) as $procs
    | ($procs | map(select(.state | test("[DTZ]")))
        | map(. + {stateLabel: ({"D": "waiting on disk/IO (cannot be killed until it returns)",
                                 "T": "stopped (suspended)",
                                 "Z": "zombie (already exited, waiting for its parent)"}[.state]),
                   canKill: (.state == "T")})) as $stuck
    | ($procs | map(select(.bytes > 0)) | group_by(.unit) | map(
        (sort_by(.pid) | first) as $main
        | (max_by(.bytes)) as $heaviest
        | (.[0].unit) as $unit
        | ($unit | unit_name) as $uname
        | (if $uname == "" or ($uname | test($launchers)) then $main.comm else $uname end) as $name
        | (($protected | index($name | ascii_downcase)) != null
           or ($protected | index($main.comm | ascii_downcase)) != null) as $isProtected
        | ($unit | test("^app-.+\\.(scope|service)$")) as $isApp
        | {
            unit: $unit,
            name: $name,
            mainProcess: $heaviest.comm,
            bytes: (map(.bytes) | add),
            processCount: length,
            quittable: ($isApp and ($isProtected | not) and $unit != $self),
            reason: (if $isProtected then "part of the desktop session"
                     elif ($isApp | not) then "system or session service"
                     elif $unit == $self then "this terminal"
                     else "" end),
            processes: (sort_by(-.bytes) | .[:8] | map(. as $p | {pid, comm, bytes,
              quittable: (($protected | index($p.comm | ascii_downcase)) == null)}))
          }
      ) | sort_by(-.bytes)) as $apps
    | $mem + {
        ok: true,
        generatedAt: (now | todate),
        appsTotal: ($apps | length),
        apps: $apps[:$limit],
        stuck: $stuck
      }'
}

# Validate and quit an application unit (SIGTERM, or SIGKILL with force=1).
oc_memory_quit_unit() {
  local unit=$1 force=${2:-0} current
  [[ $unit =~ ^app-[A-Za-z0-9._@:\\-]+\.(scope|service)$ ]] || oc_die "not an application unit: $unit" 2
  current=$(oc_memory_json 1000 | jq -c --arg u "$unit" '.apps[] | select(.unit == $u)')
  [[ -n $current ]] || oc_die "no running application with unit $unit" 2
  [[ $(jq -r .quittable <<<"$current") == true ]] ||
    oc_die "refusing to quit $(jq -r .name <<<"$current"): $(jq -r .reason <<<"$current")" 1
  local signal=SIGTERM
  ((force == 1)) && signal=SIGKILL
  systemctl --user kill --signal="$signal" -- "$unit" ||
    oc_die "could not signal $unit"
  jq -c --arg s "$signal" '{ok: true, unit, name, signal: $s, bytes}' <<<"$current"
}

# Validate and signal a single process owned by the user.
oc_memory_kill_pid() {
  local pid=$1 force=${2:-0} comm
  [[ $pid =~ ^[0-9]+$ ]] || oc_die "invalid PID: $pid" 2
  [[ -d /proc/$pid ]] || oc_die "no such process: $pid" 2
  [[ -O /proc/$pid ]] || oc_die "process $pid belongs to another user" 1
  ((pid != $$ && pid != PPID)) || oc_die "refusing to signal omarchy-cleaner itself" 1
  comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
  oc_is_protected_name "$comm" && oc_die "refusing to quit $comm: part of the desktop session" 1
  local signal=TERM
  ((force == 1)) && signal=KILL
  kill -s "$signal" "$pid" 2>/dev/null || oc_die "could not signal process $pid"
  jq -cn --argjson pid "$pid" --arg comm "$comm" --arg s "SIG$signal" '{ok: true, pid: $pid, comm: $comm, signal: $s}'
}

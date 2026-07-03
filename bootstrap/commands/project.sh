#!/bin/bash
# =====================================================================
# commands/project.sh - create/repair the links for one project
# ---------------------------------------------------------------------
# Reads the resolved links through the manifest cursor API (never the
# raw serialization) and hands each one to link_apply. Then wires
# .git/info/exclude and registers the project so `doctor` can find it.
#
# Globals expected from bin/dev-env:
#   DEV_ENV_HOME    repo (real)          - manifest + backups live here
#   DEV_ENV_STABLE  ~/Developer/dev-env  - link sources point through this
#   MANIFEST        manifest path
#   PROFILE         profile name (default: default)
#   STATE_DIR       <repo>/state
#   DRY_RUN         0|1
# =====================================================================

# Escape a string for safe inclusion inside a JSON double-quoted value.
# Handles the characters that would otherwise produce invalid JSON:
# backslash, double-quote, tab, carriage return, newline. Pure bash 3.2
# parameter substitution, no subprocess, no jq. Backslash MUST be first.
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# Reverse of json_escape. Walks the string honoring backslash escapes,
# so a registry entry round-trips back to its raw value. Single-line
# values only (embedded newlines are out of scope, as elsewhere).
json_unescape() {
  printf '%s' "$1" | awk '
    {
      n = length($0); out = ""
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\" && i < n) {
          i++; d = substr($0, i, 1)
          if      (d == "n") out = out "\n"
          else if (d == "r") out = out "\r"
          else if (d == "t") out = out "\t"
          else               out = out d      # covers \" \\ \/ and any other
        } else out = out c
      }
      printf "%s", out
    }'
}

# Read the registry into TAB-separated "path<TAB>profile" lines.
# Supports BOTH formats for backward compatibility:
#   new: { "path": "P", "profile": "swift" }
#   old: "P"                          -> profile defaults to "default"
_registry_read() {
  local file="$1" line esc prof path
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *'"path"'*)
        esc=$(printf '%s' "$line" | sed -n 's/^.*"path"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*,[[:space:]]*"profile".*$/\1/p')
        prof=$(printf '%s' "$line" | sed -n 's/^.*"profile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p')
        [ -n "$prof" ] || prof="default"
        ;;
      *'"'*'"'*)
        # old string entry (no "path" key); ignore pure bracket lines
        esc=$(printf '%s' "$line" | sed -n 's/^[^"]*"\(.*\)"[^"]*$/\1/p')
        prof="default"
        ;;
      *) continue ;;
    esac
    [ -n "$esc" ] || continue
    path=$(json_unescape "$esc")
    printf '%s\t%s\n' "$path" "$prof"
  done < "$file"
}

# Write "path<TAB>profile" lines (stdin) as a JSON array of objects,
# one object per line so it stays greppable. Values are JSON-escaped.
_registry_write() {
  local path prof first=1
  printf '[\n'
  while IFS="$(printf '\t')" read -r path prof; do
    [ -n "$path" ] || continue
    [ -n "$prof" ] || prof="default"
    [ "$first" -eq 1 ] || printf ',\n'
    printf '  {"path": "%s", "profile": "%s"}' "$(json_escape "$path")" "$(json_escape "$prof")"
    first=0
  done
  printf '\n]\n'
}

# Register (or update) a project with the profile it was linked under.
# Re-registering with the same profile is a no-op; a different profile
# updates the existing entry in place (never duplicates the path).
_project_register() {
  local proj="$1" file="$STATE_DIR/projects.json"
  local profile="${PROFILE:-default}"
  local p pr others="" present=0 same=0 tab
  tab=$(printf '\t')
  while IFS="$tab" read -r p pr; do
    [ -n "$p" ] || continue
    if [ "$p" = "$proj" ]; then
      present=1
      [ "$pr" = "$profile" ] && same=1
      continue                      # drop the old entry for this path
    fi
    others="$others$p$tab$pr
"
  done <<EOF
$(_registry_read "$file")
EOF

  if [ "$present" = 1 ] && [ "$same" = 1 ]; then
    log_info "✓ project already registered (profile: $profile)"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "register project (profile: $profile) -> ${file/#$DEV_ENV_HOME\//}"
    return 0
  fi
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  { printf '%s' "$others"; printf '%s%s%s\n' "$proj" "$tab" "$profile"; } \
    | grep -v "^[[:space:]]*$" | _registry_write > "$file"
  if [ "$present" = 1 ]; then
    log_ok "🗂  project registry updated (profile: $profile)"
  else
    log_ok "🗂  project registered in state/projects.json (profile: $profile)"
  fi
}

cmd_project() {
  local arg="$1"
  if [ -z "$arg" ]; then
    log_error "usage: dev-env project <path> [--profile <name>]"
    return 2
  fi
  if [ ! -d "$arg" ]; then
    log_error "project path is not a directory: $arg"
    return 2
  fi
  local proj
  proj=$(cd "$arg" 2>/dev/null && pwd -P) || { log_error "cannot resolve: $arg"; return 2; }

  # the stable alias must exist (init creates it)
  if [ ! -d "$DEV_ENV_STABLE" ]; then
    log_error "stable path missing: ${DEV_ENV_STABLE/#$HOME/~} — run 'dev-env init' first"
    return 1
  fi

  local profile="${PROFILE:-default}"
  log_step "dev-env project (profile: $profile)"
  log_info "target project: ${proj/#$HOME/~}"

  if ! manifest_load "$MANIFEST" "$profile"; then
    log_error "could not resolve profile '$profile' from manifest"
    return 1
  fi

  local n i rel_src rel_tgt req cfl src tgt excludes=""
  n=$(manifest_link_count)
  log_reset_counters
  i=1
  while [ "$i" -le "$n" ]; do
    rel_src=$(manifest_link_field "$i" source)
    rel_tgt=$(manifest_link_field "$i" target)
    req=$(manifest_link_field "$i" required)
    cfl=$(manifest_link_field "$i" conflict)
    src="$DEV_ENV_STABLE/$rel_src"
    tgt="$proj/$rel_tgt"
    link_apply "$src" "$tgt" "$req" "$cfl" || true
    excludes="$excludes$rel_tgt
"
    i=$((i + 1))
  done
  manifest_unload

  # wire .git/info/exclude (client .gitignore stays untouched)
  local args="" e
  while IFS= read -r e; do
    [ -n "$e" ] && args="$args $e"
  done <<EOF
$excludes
EOF
  # shellcheck disable=SC2086
  git_exclude_ensure "$proj" $args

  _project_register "$proj"

  log_report
  [ "$LOG_FAILED" -eq 0 ]
}

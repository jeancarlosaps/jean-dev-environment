#!/bin/bash
# =====================================================================
# commands/validate.sh - focused smoke tests for one project (read-only)
# ---------------------------------------------------------------------
# Where `doctor` is a broad audit, `validate` answers one question:
# "would the tools actually find their config in this project?"
#
#   dev-env validate <path> [--profile <name>]
#
# Smoke tests per resolved link:
#   * every link resolves to its central source
#   * Claude finds .claude  (resolves to a directory)
#   * Cursor finds .cursor  (resolves to a directory)
#   * MCP .mcp.json is valid JSON (corruption check)
#
# Never mutates. Exit status is non-zero if any smoke test fails.
#
# Globals from bin/dev-env: DEV_ENV_HOME DEV_ENV_STABLE MANIFEST PROFILE
# Depends on: log.sh, manifest.sh, link.sh (_link_canonical),
#             doctor.sh (_dr_json_ok)
# =====================================================================

VAL_PASS=0
VAL_FAIL=0

_val_ok()   { VAL_PASS=$((VAL_PASS + 1)); log_ok "$*"; }
_val_fail() { VAL_FAIL=$((VAL_FAIL + 1)); log_error "$*"; }

cmd_validate() {
  local arg="$1"
  if [ -z "$arg" ]; then
    log_error "usage: dev-env validate <path> [--profile <name>]"
    return 2
  fi
  if [ ! -d "$arg" ]; then
    log_error "project path is not a directory: $arg"
    return 2
  fi
  local proj
  proj=$(cd "$arg" 2>/dev/null && pwd -P) || { log_error "cannot resolve: $arg"; return 2; }
  if [ ! -d "$DEV_ENV_STABLE" ]; then
    log_error "stable path missing: ${DEV_ENV_STABLE/#$HOME/~} — run 'dev-env init' first"
    return 1
  fi

  local profile="${PROFILE:-default}"
  log_step "dev-env validate (profile: $profile)"
  log_info "project: ${proj/#$HOME/~}"

  if ! manifest_load "$MANIFEST" "$profile"; then
    log_error "could not resolve profile '$profile'"
    return 1
  fi

  local n i rel_src rel_tgt req central tgt base resolved
  n=$(manifest_link_count)
  i=1
  while [ "$i" -le "$n" ]; do
    rel_src=$(manifest_link_field "$i" source)
    rel_tgt=$(manifest_link_field "$i" target)
    req=$(manifest_link_field "$i" required)
    central="$DEV_ENV_HOME/$rel_src"
    tgt="$proj/$rel_tgt"
    base=$(basename "$rel_tgt")
    i=$((i + 1))

    # does the link resolve to its central source?
    resolved=0
    if [ -L "$tgt" ] && [ -e "$tgt" ] && \
       [ "$(_link_canonical "$tgt")" = "$(_link_canonical "$central")" ]; then
      resolved=1
    fi

    # optional link, nothing present anywhere -> not a failure
    if [ "$resolved" -eq 0 ] && [ "$req" = "false" ] && \
       [ ! -e "$tgt" ] && [ ! -e "$central" ]; then
      log_info "· $rel_tgt optional and absent — skipped"
      continue
    fi

    if [ "$resolved" -eq 0 ]; then
      _val_fail "$rel_tgt: link does not resolve to $rel_src"
      continue
    fi

    # tool-specific smoke on top of a resolving link
    case "$base" in
      .claude)
        [ -d "$tgt" ] && _val_ok "Claude finds .claude (resolves to a directory)" \
                      || _val_fail "Claude: .claude resolves but is not a directory"
        ;;
      .cursor)
        [ -d "$tgt" ] && _val_ok "Cursor finds .cursor (resolves to a directory)" \
                      || _val_fail "Cursor: .cursor resolves but is not a directory"
        ;;
      *.json)
        _dr_json_ok "$tgt" && _val_ok "MCP config $rel_tgt is valid JSON" \
                           || _val_fail "MCP config $rel_tgt is corrupt/invalid JSON"
        ;;
      *)
        _val_ok "$rel_tgt link resolves"
        ;;
    esac
  done
  manifest_unload

  printf '\n%s\n' "${LOG_C_BLUE}── validate report ─────────────────────${LOG_C_RESET}"
  printf '  passed: %s\n' "$VAL_PASS"
  if [ "$VAL_FAIL" -gt 0 ]; then
    printf '  %sfailed: %s%s\n' "$LOG_C_RED" "$VAL_FAIL" "$LOG_C_RESET"
  else
    printf '  failed: 0\n'
  fi

  [ "$VAL_FAIL" -eq 0 ]
}

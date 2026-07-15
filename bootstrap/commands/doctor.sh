#!/bin/bash
# =====================================================================
# commands/doctor.sh - audit the environment and report (read-only)
# ---------------------------------------------------------------------
# Never mutates anything. Inspects and reports. Exit status is non-zero
# if any hard failure is found, so it is CI/automation friendly.
#
#   dev-env doctor <path>...   audit the given projects
#   dev-env doctor --all       audit every registered project
#   dev-env doctor             (no target) audits only the environment
#
# What it checks:
#   environment : master symlink, ai/shared structure, manifest validity
#   per project : each link exists, is a symlink, resolves, and points
#                 to the correct central source; source present;
#                 target readable; .git/info/exclude wired
#   tools       : .claude / .cursor resolve to a dir; *.json is valid JSON
#
# Uses profile ${PROFILE:-default} for project checks (the registry only
# stores paths, not profiles).
#
# Globals from bin/dev-env: DEV_ENV_HOME DEV_ENV_STABLE MANIFEST
#                           PROFILE STATE_DIR
# Depends on: log.sh, manifest.sh, link.sh (_link_canonical)
# =====================================================================

DR_OK=0
DR_WARN=0
DR_FAIL=0

_dr_ok()   { DR_OK=$((DR_OK + 1));   log_ok "$*"; }
_dr_warn() { DR_WARN=$((DR_WARN + 1)); log_warn "$*"; }
_dr_fail() { DR_FAIL=$((DR_FAIL + 1)); log_error "$*"; }

# ---------------------------------------------------------------------
# THIS IS NOT A JSON PARSER. It is a corruption detector.
# ---------------------------------------------------------------------
# Deliberately dependency-free (no jq, no python). It ONLY catches gross
# breakage:
#     * empty file
#     * truncation
#     * unbalanced quotes
#     * unbalanced braces / brackets
# It does NOT validate JSON syntax (commas, colons, key uniqueness,
# number/literal grammar, etc.) and MUST NOT be grown into a parser.
# If real JSON validation is ever needed, add a proper tool behind an
# optional check — do not extend this function.
# ---------------------------------------------------------------------
_dr_json_ok() {
  local file="$1"
  [ -s "$file" ] || return 1
  awk '
    { data = data $0 "\n" }
    END {
      n = length(data); depth = 0; instr = 0; esc = 0
      started = 0; first = ""; ok = 1
      for (i = 1; i <= n; i++) {
        c = substr(data, i, 1)
        if (instr) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0 }
          continue
        }
        if (c == "\"") { instr = 1; started = 1; continue }
        if (c == " " || c == "\t" || c == "\r" || c == "\n") continue
        if (first == "") first = c
        if (c == "{" || c == "[") { depth++; started = 1 }
        else if (c == "}" || c == "]") { depth--; if (depth < 0) ok = 0 }
      }
      if (instr) ok = 0
      if (depth != 0) ok = 0
      if (first != "{" && first != "[") ok = 0
      if (!started) ok = 0
      exit (ok ? 0 : 1)
    }
  ' "$file"
}

# -------- environment-level checks -----------------------------------
_doctor_environment() {
  log_step "environment"

  # master symlink
  if [ -L "$DEV_ENV_STABLE" ] && [ -e "$DEV_ENV_STABLE" ] && \
     [ "$(_link_canonical "$DEV_ENV_STABLE")" = "$(_link_canonical "$DEV_ENV_HOME")" ]; then
    _dr_ok "master symlink -> repo: ${DEV_ENV_STABLE/#$HOME/~}"
  elif [ -L "$DEV_ENV_STABLE" ]; then
    _dr_fail "master symlink broken or misdirected: ${DEV_ENV_STABLE/#$HOME/~}"
  else
    _dr_fail "master symlink missing: ${DEV_ENV_STABLE/#$HOME/~} (run 'dev-env init')"
  fi

  # ai/shared structure
  local d missing=""
  for d in .agents .claude .cursor _bmad mcp prompts snippets templates knowledge docs; do
    [ -d "$DEV_ENV_HOME/ai/shared/$d" ] || missing="$missing $d"
  done
  if [ -z "$missing" ]; then
    _dr_ok "ai/shared structure complete"
  else
    _dr_warn "ai/shared missing dirs:$missing (run 'dev-env init')"
  fi

  # manifest
  if manifest_validate "$MANIFEST" >/dev/null 2>&1; then
    _dr_ok "manifest valid"
  else
    _dr_fail "manifest invalid (run: manifest_validate for details)"
  fi

  # AI-guard hooks (global core.hooksPath)
  local hooks="$DEV_ENV_STABLE/git/hooks" hookspath h missing_h=""
  hookspath=$(git config --global core.hooksPath 2>/dev/null || true)
  if [ "$hookspath" = "$hooks" ]; then
    for h in prepare-commit-msg commit-msg pre-push; do
      [ -x "$DEV_ENV_HOME/git/hooks/$h" ] || missing_h="$missing_h $h"
    done
    if [ -z "$missing_h" ]; then
      _dr_ok "AI-guard hooks active (core.hooksPath -> ${hooks/#$HOME/~})"
    else
      _dr_fail "AI-guard hooks missing/not executable:$missing_h"
    fi
  elif [ -n "$hookspath" ]; then
    _dr_fail "core.hooksPath aponta para outro lugar: $hookspath (AI guard inativo)"
  else
    _dr_warn "core.hooksPath não configurado (run 'dev-env init') — AI guard inativo"
  fi
}

# -------- per-project checks -----------------------------------------
_doctor_project() {
  local proj="$1" profile="$2"
  log_step "project: ${proj/#$HOME/~}  (profile: $profile)"

  if [ ! -d "$proj" ]; then
    _dr_fail "project directory does not exist"
    return
  fi
  if ! manifest_load "$MANIFEST" "$profile"; then
    _dr_fail "cannot resolve profile '$profile'"
    return
  fi

  local n i rel_src rel_tgt req central src_stable tgt base
  n=$(manifest_link_count)
  i=1
  while [ "$i" -le "$n" ]; do
    rel_src=$(manifest_link_field "$i" source)
    rel_tgt=$(manifest_link_field "$i" target)
    req=$(manifest_link_field "$i" required)
    central="$DEV_ENV_HOME/$rel_src"
    src_stable="$DEV_ENV_STABLE/$rel_src"
    tgt="$proj/$rel_tgt"
    i=$((i + 1))

    # source (central) presence
    if [ ! -e "$central" ] && [ ! -L "$central" ]; then
      if [ "$req" = "false" ]; then
        _dr_warn "$rel_tgt: optional source absent in dev-env ($rel_src)"
        continue
      fi
      _dr_fail "$rel_tgt: source missing in dev-env ($rel_src)"
      continue
    fi

    # target state
    if [ ! -L "$tgt" ]; then
      if [ -e "$tgt" ]; then
        _dr_fail "$rel_tgt: real data present but NOT a symlink (needs migrate)"
      else
        _dr_fail "$rel_tgt: link missing (run 'dev-env project')"
      fi
      continue
    fi
    if [ ! -e "$tgt" ]; then
      _dr_fail "$rel_tgt: broken symlink -> $(readlink "$tgt")"
      continue
    fi
    if [ "$(_link_canonical "$tgt")" != "$(_link_canonical "$central")" ]; then
      _dr_fail "$rel_tgt: symlink points elsewhere -> $(readlink "$tgt")"
      continue
    fi
    if [ ! -r "$tgt" ]; then
      _dr_warn "$rel_tgt: link resolves but target is not readable"
      continue
    fi

    # tool-aware smoke (light)
    base=$(basename "$rel_tgt")
    case "$base" in
      .claude|.cursor)
        if [ -d "$tgt" ]; then _dr_ok "$rel_tgt: linked, resolves to a dir"
        else _dr_warn "$rel_tgt: linked but not a directory"; fi
        ;;
      *.json)
        if _dr_json_ok "$tgt"; then _dr_ok "$rel_tgt: linked, valid JSON"
        else _dr_fail "$rel_tgt: linked but INVALID JSON"; fi
        ;;
      *)
        _dr_ok "$rel_tgt: linked, resolves correctly"
        ;;
    esac
  done
  manifest_unload

  # .git/info/exclude wiring (advisory)
  if [ -d "$proj/.git" ]; then
    if [ -f "$proj/.git/info/exclude" ] && grep -q '.' "$proj/.git/info/exclude" 2>/dev/null; then
      _dr_ok "git info/exclude present"
    else
      _dr_warn "git info/exclude not wired (run 'dev-env project')"
    fi
  fi
}

_doctor_report() {
  printf '\n%s\n' "${LOG_C_BLUE}── doctor report ───────────────────────${LOG_C_RESET}"
  printf '  ok:      %s\n' "$DR_OK"
  printf '  warn:    %s\n' "$DR_WARN"
  if [ "$DR_FAIL" -gt 0 ]; then
    printf '  %sfail:    %s%s\n' "$LOG_C_RED" "$DR_FAIL" "$LOG_C_RESET"
  else
    printf '  fail:    0\n'
  fi
}

cmd_doctor() {
  local want_all=0 paths="" a
  for a in "$@"; do
    case "$a" in
      --all) want_all=1 ;;
      *) paths="$paths $a" ;;
    esac
  done

  local default_profile="${PROFILE:-default}"
  log_step "dev-env doctor"
  _doctor_environment

  # Build a "path<TAB>profile" work list.
  #  --all         -> read each project's stored profile from the registry
  #  explicit path -> use ${PROFILE:-default} (registry not consulted)
  local targets="" p tab
  tab=$(printf '\t')
  if [ "$want_all" -eq 1 ]; then
    targets=$(_registry_read "$STATE_DIR/projects.json")
  fi
  for p in $paths; do
    targets="$targets
$p$tab$default_profile"
  done

  if [ "$(printf '%s' "$targets" | grep -c .)" -eq 0 ]; then
    log_info "no projects targeted (pass <path>... or --all) — environment only"
  else
    local pr
    while IFS="$tab" read -r p pr; do
      [ -n "$p" ] || continue
      [ -n "$pr" ] || pr="$default_profile"
      _doctor_project "$p" "$pr"
    done <<EOF
$targets
EOF
  fi

  _doctor_report
  [ "$DR_FAIL" -eq 0 ]
}

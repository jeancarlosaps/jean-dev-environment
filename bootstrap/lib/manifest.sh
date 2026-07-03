#!/bin/bash
# =====================================================================
# lib/manifest.sh - semantic layer over the manifest
# ---------------------------------------------------------------------
# Consumes the records emitted by yaml_flatten (lib/yaml.sh) and
# resolves profiles: applies `extends` (shallow, child wins) and fills
# each link with the effective `required` / `conflict` from defaults.
#
# Public functions:
#   manifest_profiles <file>            -> one profile name per line
#   manifest_resolve  <file> <profile>  -> resolved links, TAB separated:
#                                          source <TAB> target <TAB> required <TAB> conflict
#   manifest_validate <file>            -> validates structure + every profile
#
# Depends on: lib/yaml.sh (yaml_flatten), lib/log.sh (optional messages)
# =====================================================================

# List profile names defined in the manifest.
manifest_profiles() {
  local file="$1"
  yaml_flatten "$file" | awk -F'\t' '
    $1 == "profile" { seen[$2]=1 }
    $1 == "link"    { seen[$2]=1 }
    END { for (p in seen) print p }
  ' | sort
}

# Resolve a single profile into its effective link list.
# Prints: source <TAB> target <TAB> required <TAB> conflict
# Returns non-zero on any semantic error (missing profile, cycle,
# missing source/target, invalid enum values).
manifest_resolve() {
  local file="$1" want="$2"
  yaml_flatten "$file" | awk -F'\t' -v want="$want" '
    function fail(msg) { printf("✗ manifest: %s\n", msg) > "/dev/stderr"; err=1; exit 1 }
    {
      if ($1 == "default")  { def[$2] = $3 }
      else if ($1 == "profile") { pseen[$2]=1; if ($3=="extends") pext[$2]=$4; else pver[$2]=$4 }
      else if ($1 == "link") {
        pseen[$2]=1
        key = $2 SUBSEP $3 SUBSEP $4
        L[key] = $5
        n = $3 + 1
        if (n > cnt[$2]) cnt[$2] = n
      }
    }
    END {
      if (err) exit 1
      if (want == "") fail("no profile requested")
      if (!(want in pseen)) fail("unknown profile: " want)

      # --- build extends chain: want -> parent -> ... -> root ---
      depth = 0
      p = want
      while (p != "") {
        if (!(p in pseen)) fail("extends references unknown profile: " p)
        if (p in onchain)  fail("extends cycle detected at profile: " p)
        onchain[p] = 1
        chain[depth++] = p
        p = pext[p]
      }

      # defaults with hard fallbacks
      d_required = ("required" in def) ? def["required"] : "true"
      d_conflict = ("conflict" in def) ? def["conflict"] : "backup"

      # --- apply root..want so child overrides parent ---
      norder = 0
      for (i = depth - 1; i >= 0; i--) {
        prof = chain[i]
        for (j = 0; j < cnt[prof]; j++) {
          src = L[prof, j, "source"]
          tgt = L[prof, j, "target"]
          if (src == "") fail("link missing source in profile " prof " (item " j ")")
          if (tgt == "") fail("link missing target in profile " prof " (item " j ")")

          req = ((prof, j, "required") in L) ? L[prof, j, "required"] : d_required
          cfl = ((prof, j, "conflict") in L) ? L[prof, j, "conflict"] : d_conflict

          if (req != "true" && req != "false")
            fail("invalid required (" req ") for target " tgt)
          if (cfl != "backup" && cfl != "skip" && cfl != "fail")
            fail("invalid conflict (" cfl ") for target " tgt)

          if (!(tgt in pos)) { pos[tgt] = ++norder; ord[norder] = tgt }
          r_src[tgt] = src; r_req[tgt] = req; r_cfl[tgt] = cfl
        }
      }

      if (norder == 0) fail("profile " want " resolves to zero links")
      for (k = 1; k <= norder; k++) {
        t = ord[k]
        printf("%s\t%s\t%s\t%s\n", r_src[t], t, r_req[t], r_cfl[t])
      }
    }
  '
}

# ---------------------------------------------------------------------
# Stable cursor API
# ---------------------------------------------------------------------
# Lets other layers iterate a resolved profile WITHOUT knowing how the
# links are serialized internally. If the on-disk format ever changes,
# only this file changes; consumers keep using these functions.
#
#   manifest_load <file> <profile>   -> load a profile into the cursor
#   manifest_link_count              -> number of links
#   manifest_link_field <i> <field>  -> value; i is 1-based;
#                                       field = source|target|required|conflict
#   manifest_unload                  -> free the cursor
# ---------------------------------------------------------------------

MANIFEST_CURSOR=""

manifest_load() {
  local file="$1" profile="$2" tmp
  tmp=$(mktemp -t devenv_manifest.XXXXXX) || return 1
  if ! manifest_resolve "$file" "$profile" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  MANIFEST_CURSOR="$tmp"
}

manifest_link_count() {
  if [ -z "$MANIFEST_CURSOR" ] || [ ! -f "$MANIFEST_CURSOR" ]; then
    printf '0\n'
    return 0
  fi
  awk 'END { print NR }' "$MANIFEST_CURSOR"
}

manifest_link_field() {
  local i="$1" field="$2" col
  case "$field" in
    source)   col=1 ;;
    target)   col=2 ;;
    required) col=3 ;;
    conflict) col=4 ;;
    *) return 1 ;;
  esac
  awk -F'\t' -v r="$i" -v c="$col" 'NR == r { print $c }' "$MANIFEST_CURSOR"
}

manifest_unload() {
  [ -n "$MANIFEST_CURSOR" ] && [ -f "$MANIFEST_CURSOR" ] && rm -f "$MANIFEST_CURSOR"
  MANIFEST_CURSOR=""
}

# Validate the whole manifest: structure (via yaml_flatten) plus a full
# resolve of every profile. Returns non-zero if anything is wrong.
manifest_validate() {
  local file="$1"
  local profiles p rc=0

  if ! yaml_flatten "$file" >/dev/null; then
    return 1
  fi

  profiles=$(manifest_profiles "$file") || return 1
  if [ -z "$profiles" ]; then
    printf '✗ manifest: no profiles defined\n' >&2
    return 1
  fi

  # iterate line by line (no reliance on shell word-splitting)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! manifest_resolve "$file" "$p" >/dev/null; then
      rc=1
    fi
  done <<EOF
$profiles
EOF
  return "$rc"
}

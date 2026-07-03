#!/bin/bash
# =====================================================================
# lib/yaml.sh - lexer for the manifest YAML subset
# ---------------------------------------------------------------------
# NOT a general YAML parser. It understands exactly the structure used
# by manifest/links.yaml and flattens it into tab-separated records
# that lib/manifest.sh interprets.
#
# Emitted records (TAB separated):
#   version    <value>
#   default    <key>      <value>
#   profile    <name>     <key>     <value>     (key = extends|profileVersion)
#   link       <profile>  <index>   <key>       <value>
#
# Rules enforced: 2-space indentation, known keys only. Any violation
# prints an error to stderr and returns non-zero.
# =====================================================================

# yaml_flatten <file>
# Emits normalized records on stdout. Returns non-zero on structural error.
yaml_flatten() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf '✗ manifest not found: %s\n' "$file" >&2
    return 1
  fi

  awk '
    function fail(msg) {
      printf("✗ %s:%d: %s\n", FILENAME, NR, msg) > "/dev/stderr"
      err = 1
      exit 1
    }
    # count leading spaces; reject tabs in indentation
    function indent_of(line,    i, c, n) {
      n = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == " ") { n++ }
        else if (c == "\t") { fail("tab used in indentation; use 2 spaces") }
        else { break }
      }
      return n
    }
    function trim(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { section=""; profile=""; in_links=0; idx=-1 }
    {
      raw = $0
      # strip inline comments (# preceded by space) and full-line comments
      sub(/[ \t]+#.*$/, "", raw)
      if (raw ~ /^[ \t]*#/) next
      if (trim(raw) == "") next

      ind = indent_of(raw)
      if (ind % 2 != 0) fail("indentation must be a multiple of 2 spaces")
      body = trim(raw)

      # ---- top level (indent 0) ----
      if (ind == 0) {
        section=""; profile=""; in_links=0; idx=-1
        if (body ~ /^version:/) {
          v = trim(substr(body, index(body, ":") + 1))
          printf("version\t%s\n", v)
        } else if (body == "defaults:") {
          section = "defaults"
        } else if (body == "profiles:") {
          section = "profiles"
        } else {
          fail("unknown top-level key: " body)
        }
        next
      }

      # ---- indent 2 ----
      if (ind == 2) {
        if (section == "defaults") {
          key = trim(substr(body, 1, index(body, ":") - 1))
          val = trim(substr(body, index(body, ":") + 1))
          if (key != "required" && key != "conflict")
            fail("unknown defaults key: " key)
          printf("default\t%s\t%s\n", key, val)
        } else if (section == "profiles") {
          # profile name line: "name:"
          if (body !~ /:$/) fail("expected profile name ending with : -> " body)
          profile = substr(body, 1, length(body) - 1)
          in_links = 0; idx = -1
        } else {
          fail("unexpected indentation under: " section)
        }
        next
      }

      # ---- indent 4 (inside a profile) ----
      if (ind == 4) {
        if (profile == "") fail("indent-4 outside a profile: " body)
        if (body == "links:") { in_links = 1; idx = -1; next }
        key = trim(substr(body, 1, index(body, ":") - 1))
        val = trim(substr(body, index(body, ":") + 1))
        if (key != "extends" && key != "profileVersion")
          fail("unknown profile key: " key)
        printf("profile\t%s\t%s\t%s\n", profile, key, val)
        in_links = 0
        next
      }

      # ---- indent 6 (a link list item) ----
      if (ind == 6) {
        if (!in_links) fail("indent-6 outside links: " body)
        if (body !~ /^- /) fail("expected list item starting with - : " body)
        idx++
        rest = trim(substr(body, 3))     # after "- "
        key = trim(substr(rest, 1, index(rest, ":") - 1))
        val = trim(substr(rest, index(rest, ":") + 1))
        if (key != "source" && key != "target" && key != "required" && key != "conflict")
          fail("unknown link key: " key)
        printf("link\t%s\t%d\t%s\t%s\n", profile, idx, key, val)
        next
      }

      # ---- indent 8 (continuation of the current link item) ----
      if (ind == 8) {
        if (!in_links || idx < 0) fail("indent-8 outside a link item: " body)
        key = trim(substr(body, 1, index(body, ":") - 1))
        val = trim(substr(body, index(body, ":") + 1))
        if (key != "source" && key != "target" && key != "required" && key != "conflict")
          fail("unknown link key: " key)
        printf("link\t%s\t%d\t%s\t%s\n", profile, idx, key, val)
        next
      }

      fail("unexpected indentation level (" ind "): " body)
    }
    END { if (err) exit 1 }
  ' "$file"
}

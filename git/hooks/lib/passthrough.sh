#!/bin/bash
# =====================================================================
# git/hooks/lib/passthrough.sh - generic delegation to repo hooks
# ---------------------------------------------------------------------
# A global core.hooksPath makes git skip .git/hooks for EVERY hook, not
# only the AI-guard ones. Each standard hook name in git/hooks/ that is
# a symlink to this file simply re-runs the repository's own hook of
# the same name (corporate hooks keep working). stdin and args are
# passed through untouched.
# =====================================================================
name=$(basename "$0")
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
hook="$gitdir/hooks/$name"
[ -x "$hook" ] && exec "$hook" "$@"
exit 0

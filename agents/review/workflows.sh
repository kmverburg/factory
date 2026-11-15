#!/usr/bin/env bash
# Reviewer helper: list the changed paths under .github/ (one per line, sorted, unique).
# Usage: workflows_changed <pr.json> <diff.patch>. Uses both the PR's file list and the diff,
# so neither a truncated file list nor a rename out of .github/ hides a change.
workflows_changed() {
  {
    jq -r '.files[]?.path // empty' "$1" 2>/dev/null
    sed -nE 's#^diff --git a/(.+) b/(.+)$#\1\n\2#p' "$2" 2>/dev/null
  } | grep -E '^\.github/' | sort -u || true
}

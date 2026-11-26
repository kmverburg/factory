# shellcheck shell=bash
# The Linear status "Conflicts" (KV-80), sourced by the update job, the builder's publish step and the reviewer.
# Needs agents/lib/linear.sh. Everything warns instead of failing. Finished tickets are never touched.

# $1 = "true" when the PR has the label needs-human. Prints the status a ticket goes back to when its conflict is resolved.
conflict_home_state() {
  if [ "$1" = "true" ]; then echo "Needs Human"; else echo "In Review"; fi
}

# $1 = issue. Succeeds when the ticket is in the status Conflicts (case-insensitive).
conflict_in_conflicts() {
  local s
  s=$(linear_state_of "$1") || true
  [ "$(printf '%s' "${s%%$'\t'*}" | tr '[:upper:]' '[:lower:]')" = "conflicts" ]
}

# $1 = issue, $2 = conflicting files (one per line), $3 = what happens next. Moves the ticket to Conflicts with a comment
# listing the files. A ticket that is already in Conflicts, Done or Canceled gets neither, so repeated runs stay quiet.
conflict_found() {
  local s type
  s=$(linear_state_of "$1") || true
  type=${s#*$'\t'}
  case "$type" in completed|canceled) return 0 ;; esac
  [ "$(printf '%s' "${s%%$'\t'*}" | tr '[:upper:]' '[:lower:]')" != "conflicts" ] || return 0
  linear_set_state "$1" "Conflicts"
  linear_comment "$1" "$(printf '🏭 The pull request conflicts with the base branch. Conflicting files:\n%s\n\n%s' "$(sed 's/^/- /' <<<"$2")" "$3")"
}

# $1 = issue, $2 = "true" when the PR has needs-human. When the ticket is in Conflicts, moves it back to where it was.
conflict_clear() {
  conflict_in_conflicts "$1" || return 0
  linear_set_state "$1" "$(conflict_home_state "$2")"
}

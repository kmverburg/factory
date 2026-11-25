#!/usr/bin/env bash
# Compiles every jq filter in agents/: the inline ones in the shell scripts (found by jq-extract.py) and the .jq files.
# Catches syntax errors such as a missing parenthesis before the script runs for real. Usage: bash agents/ci/check-jq.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"
fail=0; count=0

# Defines every $name used in the filter as null, so only real syntax errors fail.
compile() { # $1 = where, $2 = filter text
  local args=() v err
  while read -r v; do [ -n "$v" ] && args+=(--argjson "$v" null); done \
    < <(grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' <<<"$2" | sed 's/^\$//' | grep -vxE '__loc__|__prog_args|ENV' | sort -u)
  count=$((count + 1))
  if ! err=$(jq -n "${args[@]}" "$2" 2>&1 </dev/null) && grep -q 'compile error' <<<"$err"; then
    echo "FAIL $1: jq filter does not compile"; sed 's/^/     /' <<<"$err" | head -5; fail=1
  fi
}

while IFS= read -r -d '' rec; do
  compile "${rec%%$'\n'*}" "${rec#*$'\n'}"
done < <(python3 -I "$here/jq-extract.py" agents/*.sh agents/*/*.sh)

# The .jq files, as the scripts use them: their own directory is the module path (they include each other).
# A file with only definitions is a module; it is checked by including it.
for f in agents/*/*.jq; do
  d=$(dirname "$f"); name=$(basename "$f" .jq)
  args=()
  while read -r v; do [ -n "$v" ] && args+=(--argjson "$v" null); done \
    < <(grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' "$f" | sed 's/^\$//' | grep -vxE '__loc__|__prog_args|ENV' | sort -u)
  count=$((count + 1))
  err=$(jq -n -L "$d" -L agents/scout "${args[@]}" -f "$f" 2>&1 </dev/null) || true
  if grep -q 'Top-level program not given' <<<"$err"; then
    err=$(jq -n -L "$d" -L agents/scout "${args[@]}" "include \"$name\"; ." 2>&1 </dev/null) || true
  fi
  if grep -q 'compile error' <<<"$err"; then
    echo "FAIL $f: jq filter does not compile"; sed 's/^/     /' <<<"$err" | head -5; fail=1
  fi
done

[ "$count" -gt 50 ] || { echo "FAIL only $count jq filters found; the extractor is broken"; fail=1; }
[ "$fail" = 0 ] && echo "ok   $count jq filters compile"
exit $fail

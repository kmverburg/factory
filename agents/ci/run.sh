#!/usr/bin/env bash
# Everything the "Agent scripts" check runs, so it can be run locally too: syntax, shellcheck, jq filters,
# smoke tests and the existing tests. Runs all of them and fails at the end if any failed. Usage: bash agents/ci/run.sh
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.." || exit 1
fail=0
step() { echo "::group::$1"; shift; if "$@"; then echo "::endgroup::"; echo "ok   $*"; else echo "::endgroup::"; echo "::error::FAILED: $*"; fail=1; fi; }
scripts=$(ls agents/*.sh agents/*/*.sh)
# shellcheck disable=SC2086
step "bash -n" bash -c 'for f in '"$(echo $scripts)"'; do bash -n "$f" || exit 1; done'
# shellcheck disable=SC2086
step "shellcheck" shellcheck -x -S warning $scripts
# Linear comments are created only by the helpers in lib/linear.sh, which add the factory marker.
no_direct_comments() { ! grep -n commentCreate agents/*.sh agents/*/*.sh | grep -v '^agents/ci/' | grep -v '/test[^/]*\.sh:' | grep -v '^agents/lib/linear\.sh:' | grep .; }
step "no direct commentCreate" no_direct_comments
step "jq filters compile" bash agents/ci/check-jq.sh
step "smoke tests (publish scripts)" bash agents/ci/smoke-test.sh
tests=(agents/scout/test.sh agents/deps/test.sh agents/watch/test.sh agents/health/test.sh agents/health/test-stuck.sh agents/secrets/test.sh agents/lib/test.sh agents/lib/test-issue-writer.sh
  agents/issue-writer/test.sh agents/review/test.sh agents/review/test-recheck.sh agents/review/test-learn.sh agents/sync/test.sh agents/update/test.sh agents/approve/test.sh agents/report/test.sh agents/retry/test.sh)
for t in "${tests[@]}"; do step "$t" bash "$t"; done
# A test script that isn't listed above would never run in CI.
for t in agents/*/test*.sh; do
  [[ " ${tests[*]} " == *" $t "* ]] || { echo "::error::$t is not run by agents/ci/run.sh"; fail=1; }
done
exit $fail

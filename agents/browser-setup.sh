#!/usr/bin/env bash
# Installs a headless Chromium with Python Playwright and puts it on PATH for the agent.
set -eo pipefail
python3 -m venv "$RUNNER_TEMP/browser"
"$RUNNER_TEMP/browser/bin/pip" install --quiet playwright==1.64.1
"$RUNNER_TEMP/browser/bin/playwright" install --with-deps chromium
echo "$RUNNER_TEMP/browser/bin" >> "$GITHUB_PATH"

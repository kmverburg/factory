#!/usr/bin/env bash
# Usage: render.sh <template> <output-name>
# Replaces {{NAME}} with the environment variable NAME and writes the result as a
# multi-line step output, so a workflow can pass it to the Claude action as `prompt`.
set -eo pipefail
text=$(python3 -c '
import os, re, sys
print(re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: os.environ.get(m.group(1), ""), open(sys.argv[1]).read()))
' "$1")
delim="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d " \n")"
{ echo "$2<<$delim"; echo "$text"; echo "$delim"; } >> "$GITHUB_OUTPUT"

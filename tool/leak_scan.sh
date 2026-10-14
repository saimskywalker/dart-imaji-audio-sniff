#!/usr/bin/env bash
# Fails when tracked files or history mention any private pattern.
#
# The patterns are deliberately NOT in this repository (they would match
# themselves). Provide them, as one extended regular expression, through
# either the LEAK_PATTERNS environment variable (CI: a repository secret) or
# an untracked .leakscan file (listed in .gitignore):
#
#   echo 'first-name|other-name|internal-host' > .leakscan
#   tool/leak_scan.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

patterns="${LEAK_PATTERNS:-}"
if [[ -z "$patterns" && -f .leakscan ]]; then
  patterns="$(tr '\n' '|' < .leakscan | sed 's/|*$//')"
fi
if [[ -z "$patterns" ]]; then
  echo "leak scan skipped: no LEAK_PATTERNS and no .leakscan file"
  exit 0
fi

found=0
if git grep -inE "$patterns" -- . ':!.leakscan'; then found=1; fi
if git log -p --all | grep -inE "$patterns"; then found=1; fi
if git log --all --format='%an %ae %cn %ce %s %b' | grep -inE "$patterns"; then found=1; fi

if [[ $found -ne 0 ]]; then
  echo "leak scan FAILED: private patterns found above" >&2
  exit 1
fi
echo "leak scan clean"

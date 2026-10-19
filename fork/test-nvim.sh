#!/usr/bin/env bash
# Run the specs in spec/ inside a real headless Neovim (see spec/runner.lua).
# Extra arguments replace the default `spec` path and are passed to busted.
# The exit status is busted's; 2 when Neovim quit before busted finished.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

done_marker="$(mktemp)"
trap 'rm -f "$done_marker"' EXIT
rm -f "$done_marker"

status=0
CLAUDECODE_SPEC_DONE="$done_marker" nvim --headless --clean -l spec/runner.lua -o utfTerminal "${@:-spec}" || status=$?

if [ ! -e "$done_marker" ]; then
  echo "test-nvim: Neovim quit before busted finished" >&2
  exit "$((status == 0 ? 2 : status))"
fi
exit "$status"

#!/usr/bin/env bash
# Run the specs in spec/ inside a real headless Neovim (see spec/runner.lua).
# Extra arguments replace the default `spec` path and are passed to busted.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec nvim --headless --clean -l spec/runner.lua -o utfTerminal "${@:-spec}"

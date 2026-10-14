#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/image-tools-test.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
export IMAGE_TOOLS_ROOT="$root"
export IMAGE_TOOLS_TEST_TMP="$test_tmp"
export XDG_CACHE_HOME="$test_tmp/cache"
export XDG_STATE_HOME="$test_tmp/state"
export NVIM_LOG_FILE="$test_tmp/nvim.log"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/spec.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/runtime.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/line_lifecycle.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/disk_cache.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/conversion.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/transfer.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/insert.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/clipboard.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/picker.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/syntax_cache.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/tex.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/typst.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/buffer.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/canvas_bounds.lua"
if command -v python3 >/dev/null 2>&1; then
  python3 "$root/tests/tui.py"
fi

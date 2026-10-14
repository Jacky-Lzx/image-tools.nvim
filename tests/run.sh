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
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/health.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/disk_cache.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/conversion.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/conversion_queue.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/transfer.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/pixel_pool.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/insert.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/clipboard.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/picker.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/syntax_cache.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/treesitter.lua"
if [ -n "${IMAGE_TOOLS_PARSER_ROOT:-}" ]; then
  nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/async.lua"
  nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/incremental.lua"
fi
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/tex.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/tex_multiline.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/document/typst.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/buffer.lua"
nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/canvas_bounds.lua"
if command -v python3 >/dev/null 2>&1; then
  python3 "$root/tests/tui.py"
fi

#!/bin/sh
# Run with: sh tests/run.sh.
# Groups run in order; the first failure stops the run.
# Required: Neovim and ImageMagick (magick), with Ghostscript for PDF conversion.
# Optional: python3, LaTeX/Typst compilers, Tree-sitter parsers and a Snacks checkout.
set -eu

# Color only status labels on interactive terminals. Keep redirected logs plain,
# and honor NO_COLOR (including an empty value) and terminals without color support.
log_run_color=''
log_skip_color=''
log_done_color=''
log_fail_color=''
log_reset=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "${NO_COLOR+x}" != x ]; then
  log_run_color='\033[36m'
  log_skip_color='\033[33m'
  log_done_color='\033[32m'
  log_fail_color='\033[31m'
  log_reset='\033[0m'
fi

log() {
  case "$1" in
  run) log_color=$log_run_color ;;
  skip) log_color=$log_skip_color ;;
  done) log_color=$log_done_color ;;
  fail) log_color=$log_fail_color ;;
  *) log_color='' ;;
  esac
  printf '\n%b[%s]%b %s\n' "$log_color" "$1" "$log_reset" "$2"
}

# Preserve each suite's output and exit status, and identify a failing file.
run_suite() {
  suite_name=$1
  shift
  log run "$suite_name"
  if "$@"; then
    :
  else
    suite_status=$?
    log fail "$suite_name (exit $suite_status)" >&2
    exit "$suite_status"
  fi
}

# Locate the repository relative to this script, regardless of the working directory.
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Keep fixture copies, converted files, caches and logs in a temporary directory.
# Remove that directory when the runner exits.
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/image-tools-test.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

# Lua tests use these two variables to locate plugin sources and temporary files.
export IMAGE_TOOLS_ROOT="$root"
export IMAGE_TOOLS_TEST_TMP="$test_tmp"
export XDG_CACHE_HOME="$test_tmp/cache"
export XDG_STATE_HOME="$test_tmp/state"
export NVIM_LOG_FILE="$test_tmp/nvim.log"

# Run each Lua file in a fresh Neovim process to isolate mocks and global state.
# Keep the suite list explicit so manual clipboard tests and TUI scenarios are
# never discovered and executed as headless tests.
# --headless: no terminal UI, but real buffers, windows and events remain available.
# -u NONE / -i NONE / --noplugin: disable user config, ShaDa and plugin autoloading.
# -l: execute the Lua file; a failed assertion produces a nonzero exit status.
run_test() {
  run_suite "tests/$1" nvim --headless -u NONE -i NONE --noplugin -l "$root/tests/$1"
}

# 1. Core API, preview lifecycle and diagnostics.
run_test core/startup.lua # setup and cleanup retain deferred services
if [ -n "${IMAGE_TOOLS_LAZY_ROOT:-}" ]; then
  run_test core/lazy.lua
else
  log skip 'lazy.nvim loading: set IMAGE_TOOLS_LAZY_ROOT to a lazy.nvim checkout'
fi
run_test core/regression.lua # general regressions
run_test core/runtime.lua
run_test core/line_lifecycle.lua # reference entry/exit, edits and async cancellation
run_test core/preview_diagnostics.lua
run_test core/auto_preview_delay.lua
run_test core/cursor_lifecycle.lua
run_test core/tex_range_lifecycle.lua # asserts that a preview stays open within a multiline reference and closes on exit
run_test core/math_lifecycle.lua
run_test core/health.lua

# 2. Image preparation and rendering resources: disk cache, conversion, queues,
# protocol transfer and pixel reuse. These suites use both controlled mocks and
# real conversions, so headless execution also covers integration behavior.
run_test media/disk_cache.lua
run_test media/conversion.lua
run_test media/prepare.lua
run_test media/math.lua # formula workers; optional real latex/dvipng compilation
run_test media/conversion_queue.lua
run_test terminal/transfer.lua
run_test terminal/stream.lua
run_test terminal/pixel_pool.lua
run_test render/session.lua
run_test render/view.lua

# 3. Image insertion, clipboard adapters and picker integration.
# workflow/clipboard.lua uses fake commands without accessing the system clipboard.
# workflow/{picker,selection}.lua check their optional picker checkout roots.
# manual/clipboard_native.lua requires a prepared system clipboard and runs separately.
run_test workflow/insert.lua
run_test workflow/template.lua
run_test workflow/process.lua
run_test workflow/file_process.lua
run_test workflow/naming.lua
# Main-loop execution lets Insert mode activate and tests real queued typing.
run_suite tests/workflow/insert_mode.lua nvim --headless -u NONE -i NONE --noplugin \
  -c "luafile $root/tests/workflow/insert_mode.lua"
run_test workflow/content.lua
run_test workflow/assets.lua
run_test workflow/asset_project.lua
run_test workflow/move.lua
run_test workflow/clipboard.lua
run_test workflow/clipboard_backend.lua
run_test workflow/picker.lua # optional ordinary Snacks preview compatibility
run_test workflow/selection.lua # optional real selection-tools chooser

# 4. Document recognition: format dispatch, Lua scanner caches and Tree-sitter
# queries/fallback. treesitter.lua always runs and reports skipped real-language
# checks when the corresponding parsers are unavailable.
run_test document/markdown.lua
run_test document/inline.lua
run_test document/math.lua
run_test document/formats.lua
run_test document/html.lua
run_test document/adapters.lua
run_test document/syntax_cache.lua
run_test document/treesitter.lua

# 5. Dedicated real-parser suites (require both latex and typst parsers).
# IMAGE_TOOLS_PARSER_ROOT is a runtime directory with parser/latex.* and parser/typst.*.
# async covers asynchronous parsing, incremental covers index updates, and
# tex_multiline_ts covers multiline ranges. This variable also enables Tree-sitter
# cases in the earlier cursor and LaTeX lifecycle suites.
if [ -n "${IMAGE_TOOLS_PARSER_ROOT:-}" ]; then
  run_test document/async.lua
  run_test document/incremental.lua
  run_test document/tex_multiline_ts.lua
else
  log skip 'Real-parser suites: set IMAGE_TOOLS_PARSER_ROOT (latex + typst)'
fi

# 6. LaTeX/Typst syntax, path resolution and insertion, plus image buffers and bounds.
# tex_multiline forces the Lua scanner; tex/typst also compile real documents when
# their compilers are available. Path assertions here cover recognition/resolution;
# the lifecycle suites in group 1 additionally assert preview windows.
run_test document/tex.lua
run_test document/tex_multiline.lua
run_test document/typst.lua
run_test render/buffer.lua
run_test render/canvas_bounds.lua
run_test render/inline.lua

# 7. Local HTTPS integration, then real Neovim TUI with simulated Kitty replies.
# Checks uploads, placeholders, caches and window lifecycle. Visible pixels still
# require a real Kitty check. tui/run.py launches the Lua scenarios in tui/;
# those files require TUI execution and should not be run as headless tests.
if command -v python3 >/dev/null 2>&1; then
  run_suite tests/https/run.py python3 "$root/tests/https/run.py"
  run_suite tests/tui/run.py python3 "$root/tests/tui/run.py"
else
  log skip 'HTTPS integration and TUI protocol tests: python3 unavailable'
fi

log done 'Test run completed; review skip messages for optional coverage.'

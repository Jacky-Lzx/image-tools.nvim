#!/bin/sh
# Build pinned parsers into an explicitly supplied disposable directory.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$root/tests/ci/versions.sh"
if [ "$#" -ne 1 ]; then
  printf 'Usage: sh tests/ci/install-fixtures.sh /absolute/disposable/directory\n' >&2
  exit 2
fi
case "$1" in /*) ;; *) printf 'Fixture directory must be absolute\n' >&2; exit 2 ;; esac
fixture_root=$1
mkdir -p "$fixture_root"
if [ "$(tree-sitter --version | awk '{print $2}')" != "$TREE_SITTER_VERSION" ]; then
  printf 'tree-sitter %s is required\n' "$TREE_SITTER_VERSION" >&2
  exit 1
fi
checkout() {
  repository=$1
  revision=$2
  destination=$3
  if [ -e "$destination" ]; then
    if [ "$(git -C "$destination" rev-parse HEAD)" != "$revision" ]; then
      printf 'Existing fixture has a different revision: %s\n' "$destination" >&2
      exit 1
    fi
  else
    git init -q "$destination"
    git -C "$destination" remote add origin "$repository"
    git -C "$destination" fetch -q --depth=1 origin "$revision"
    git -C "$destination" checkout -q --detach FETCH_HEAD
  fi
}
checkout https://github.com/latex-lsp/tree-sitter-latex.git "$LATEX_REVISION" "$fixture_root/latex"
checkout https://github.com/uben0/tree-sitter-typst.git "$TYPST_REVISION" "$fixture_root/typst"
mkdir -p "$fixture_root/runtime/parser"
for language in latex typst; do
  (
    cd "$fixture_root/$language"
    tree-sitter generate --abi 15
    "${CC:-cc}" -O2 -fPIC -Isrc -c src/parser.c -o "$fixture_root/$language-parser.o"
    if [ -f src/scanner.c ]; then
      "${CC:-cc}" -O2 -fPIC -Isrc -c src/scanner.c -o "$fixture_root/$language-scanner.o"
      "${CC:-cc}" -shared "$fixture_root/$language-parser.o" "$fixture_root/$language-scanner.o" -o "$fixture_root/runtime/parser/$language.so"
    elif [ -f src/scanner.cc ]; then
      "${CXX:-c++}" -std=c++17 -O2 -fPIC -Isrc -c src/scanner.cc -o "$fixture_root/$language-scanner.o"
      "${CXX:-c++}" -shared "$fixture_root/$language-parser.o" "$fixture_root/$language-scanner.o" -o "$fixture_root/runtime/parser/$language.so"
    else
      "${CC:-cc}" -shared "$fixture_root/$language-parser.o" -o "$fixture_root/runtime/parser/$language.so"
    fi
  )
done
printf 'IMAGE_TOOLS_PARSER_ROOT=%s/runtime\n' "$fixture_root"

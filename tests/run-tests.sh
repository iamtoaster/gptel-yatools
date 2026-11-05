#!/bin/sh
# Run the gptel-yatools ERT suite in a clean, batch Emacs.
#
# Portable by construction: it knows nothing about this machine.  Emacs is
# taken from $EMACS (or found on PATH) and always started with -Q, so no
# user init file is loaded; the package is found through -L .; and the
# directories holding gptel and yaml are named by the caller, because only
# the caller knows where their packages are installed.
#
#   ./tests/run-tests.sh /path/to/gptel /path/to/yaml
#   GPTEL_YATOOLS_TEST_LOAD_PATH=/path/to/gptel:/path/to/yaml ./tests/run-tests.sh
#   ./tests/run-tests.sh /path/to/gptel /path/to/yaml '^gptel-yatools-test-vfs-'
#
# A third argument is an ERT selector regexp; without it every
# `gptel-yatools-test-' test runs.
#
# The suites build their fixtures with `make-temp-file', which honours
# `temporary-file-directory', so nothing is written outside the temp
# directory Emacs reports for itself.

set -eu

usage() {
    cat <<'EOF'
usage: run-tests.sh [LOAD-PATH-DIR...] [SELECTOR]

Run the gptel-yatools ERT suite under `emacs -Q --batch'.

LOAD-PATH-DIR   A directory added to `load-path' besides this repository.
                Pass one for each place gptel and yaml live.  May also be
                given, colon-separated, in GPTEL_YATOOLS_TEST_LOAD_PATH.
SELECTOR        An ERT selector regexp, e.g. '^gptel-yatools-test-vfs-'.

EMACS           The Emacs executable to use (default: emacs on PATH).
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

emacs=${EMACS:-$(command -v emacs || true)}
if [ -z "$emacs" ]; then
    echo "run-tests.sh: no Emacs found.  Set EMACS to the executable to use." >&2
    exit 127
fi

# Dependency directories: arguments first, then the environment variable.
# The last argument is a selector only when more than one was given with a
# caret, which is the only way to tell them apart without guessing.
selector=
dirs=
for arg in "$@"; do
    case $arg in
        /*) dirs="$dirs $arg" ;;
        *)  selector=$arg ;;
    esac
done

if [ -n "${GPTEL_YATOOLS_TEST_LOAD_PATH:-}" ]; then
    IFS=:
    for dir in $GPTEL_YATOOLS_TEST_LOAD_PATH; do
        [ -n "$dir" ] && dirs="$dirs $dir"
    done
    unset IFS
fi

if [ -z "$dirs" ]; then
    echo "run-tests.sh: name the directories holding gptel and yaml, either as" >&2
    echo "arguments or in GPTEL_YATOOLS_TEST_LOAD_PATH (colon-separated)." >&2
    echo >&2
    echo "  ./tests/run-tests.sh /path/to/gptel /path/to/yaml" >&2
    echo "  GPTEL_YATOOLS_TEST_LOAD_PATH=/path/to/gptel:/path/to/yaml ./tests/run-tests.sh" >&2
    exit 2
fi

set -- -Q --batch -L "$here"
for dir in $dirs; do
    set -- "$@" -L "$dir"
done

# `-l' each file, so a suite's own load is what fails when a dependency is
# missing rather than an `ert' run over tests that were never defined.
for suite in \
    "$here/gptel-yatools.el" \
    "$here/tests/gptel-yatools-tests.el" \
    "$here/tests/gptel-yatools-vfs-tests.el" \
    "$here/tests/gptel-yatools-skills-tests.el" \
    "$here/tests/gptel-yatools-diagram-tests.el" \
    "$here/tests/gptel-yatools-agents-tests.el"
do
    set -- "$@" -l "$suite"
done

if [ -n "$selector" ]; then
    exec "$emacs" "$@" --eval "(ert-run-tests-batch-and-exit \"$selector\")"
else
    exec "$emacs" "$@" -f ert-run-tests-batch-and-exit
fi

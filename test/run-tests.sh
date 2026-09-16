#!/usr/bin/env bash
# run-tests.sh — run all org-sty ERT test suites
# Exit code: 0 = all passed, non-zero = at least one failure
#
# ORG_STY_DEV=1 is required so the Emacs init file does not load the
# stable installed version of org-sty and friends before our -L . path
# can take precedence.  emacs --batch still reads the user init file.

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

EMACS=${EMACS:-emacs}
LOADPATH="-L ."
ERTFLAGS="-l ert"
RUNNER="-f ert-run-tests-batch-and-exit"

SUITES=(
    test/test-face-extra.el
    test/test-variable-spacing.el
    test/test-org-sty.el
    test/test-horizontal-layout.el
)

FAILED=0
for suite in "${SUITES[@]}"; do
    echo "=== Running $suite ==="
    if ORG_STY_DEV=1 "$EMACS" --batch $LOADPATH $ERTFLAGS -l "$suite" $RUNNER 2>&1; then
        echo "--- $suite: PASSED ---"
    else
        echo "--- $suite: FAILED ---"
        FAILED=1
    fi
    echo
done

if [ "$FAILED" -eq 0 ]; then
    echo "All suites PASSED."
else
    echo "One or more suites FAILED."
    exit 1
fi

# shellcheck shell=bash
ENTRYPOINT="${BATS_TEST_DIRNAME}/../../entrypoint.sh"
FIXTURES="${BATS_TEST_DIRNAME}/../fixtures"

# entrypoint.sh sets `set -euo pipefail` at the top, so it is always sourced in a
# subshell rather than into the bats test shell.
ep() {
    run bash -c "source '$ENTRYPOINT'; $*"
}

#!/bin/sh
#
# Fails if a .fw can write eMMC/SD LBA 64-16383, where the board's stock
# first-stage loader lives. Usage: check-loader-area.sh [--static-only] <fw>...
# Needs python3 and, for the dynamic part, fwup ($FWUP or PATH).

set -e
exec python3 -I "$(dirname "$0")"/guards/loader_area.py "$@"

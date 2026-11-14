#!/bin/sh
#
# Checks u-boot.itb against the FIT contract of the board's stock SPLs.
# Usage: check-fit.sh [--config <u-boot .config>] <u-boot.itb> <contract file>
#        check-fit.sh --print-contract <u-boot.itb>

set -e
exec python3 -I "$(dirname "$0")"/guards/fit.py "$@"

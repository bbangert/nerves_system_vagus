#!/usr/bin/env bash
# Runs uboot/uboot.env, unmodified, in U-Boot's sandbox against two
# file-backed MMC devices (mmc 0 = eMMC, mmc 1 = SD) and checks the boot
# matrix: disk choice, state load/save, A/B revert, what is written where.
#
# Usage:
#   scripts/test-boot-script.sh --src <unpacked U-Boot v2026.04 tree>
#   scripts/test-boot-script.sh --cache <dir>   # fetch + patch into <dir>
# Options:
#   --env <file>    boot script to test (default uboot/uboot.env)
#   --work <dir>    build and scratch directory (default: under the cache or
#                   a temporary directory); the sandbox build is reused
#   -j <n>          make jobs
#
# Host needs: gcc, make, bison, flex, python3, fwup. The sandbox build also
# needs a dtc plus a Python with libfdt: either set DTC and PYTHON3 to
# them (CI: apt device-tree-compiler python3-libfdt), or have swig and
# python3 setuptools so U-Boot builds its own. xxd is emulated if missing.
set -euo pipefail

UBOOT_VERSION=2026.04
UBOOT_URL="https://github.com/u-boot/u-boot/archive/refs/tags/v${UBOOT_VERSION}.tar.gz"

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
here="$repo/scripts/boot-script-test"
src=""
cache=""
env_file="$repo/uboot/uboot.env"
work=""
jobs=$(nproc 2>/dev/null || echo 4)

die() {
    echo "test-boot-script: $*" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
    --src) src=$2; shift 2 ;;
    --cache) cache=$2; shift 2 ;;
    --env) env_file=$2; shift 2 ;;
    --work) work=$2; shift 2 ;;
    -j) jobs=$2; shift 2 ;;
    -h | --help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
    esac
done

for tool in gcc make bison flex python3 fwup; do
    command -v "$tool" >/dev/null || die "missing host tool: $tool"
done
[ -f "$env_file" ] || die "no such env file: $env_file"
env_file=$(cd "$(dirname "$env_file")" && pwd)/$(basename "$env_file")

if [ -z "$src" ]; then
    [ -n "$cache" ] || die "give --src or --cache"
    mkdir -p "$cache"
    cache=$(cd "$cache" && pwd)
    src="$cache/u-boot-${UBOOT_VERSION}"
    if [ ! -f "$src/.green-patched" ]; then
        rm -rf "$src"
        curl -fsSL "$UBOOT_URL" -o "$cache/u-boot.tar.gz"
        tar -xzf "$cache/u-boot.tar.gz" -C "$cache"
        for p in "$repo"/uboot/patches/*.patch; do
            patch -s -p1 -d "$src" <"$p"
        done
        touch "$src/.green-patched"
    fi
fi
src=$(cd "$src" && pwd)
[ -f "$src/configs/sandbox_defconfig" ] || die "$src is not a U-Boot tree"

if [ -z "$work" ]; then
    if [ -n "$cache" ]; then
        work="$cache/work"
    else
        work=$(mktemp -d)
    fi
fi
mkdir -p "$work"
work=$(cd "$work" && pwd)
build="$work/sandbox"
mkdir -p "$build" "$work/bin"

# The default-env rule pipes the file through `xxd -i`.
if ! command -v xxd >/dev/null; then
    cp "$here/xxd" "$work/bin/xxd"
    chmod +x "$work/bin/xxd"
fi
export PATH="$work/bin:$PATH"

# The sandbox's default env is the real script with the stubbed leaf keys
# replaced, not shadowed: `env default -f <var>` takes a key's first
# occurrence, a full import its last.
stub_keys=$(sed -n 's/^\([a-z_0-9]*\)=.*/\1/p' "$here/stubs.env")
awk -v keys="$stub_keys" '
    BEGIN { n = split(keys, k, "\n"); for (i = 1; i <= n; i++) stub[k[i]] = 1 }
    { key = $0; sub(/=.*/, "", key) }
    key in stub {
        if ($0 ~ /\\$/) { print "stubbed key " key " is multi-line" > "/dev/stderr"; exit 1 }
        found[key] = 1
        next
    }
    { print }
    END { for (s in stub) if (!(s in found)) { print "stubbed key " s " not in env" > "/dev/stderr"; exit 1 } }
' "$env_file" >"$work/test.env.new"
cat "$here/stubs.env" >>"$work/test.env.new"
if ! cmp -s "$work/test.env.new" "$work/test.env"; then
    mv "$work/test.env.new" "$work/test.env"
else
    rm -f "$work/test.env.new"
fi

make_opts=(-s -C "$src" O="$build" NO_SDL=1)
if [ -n "${DTC:-}" ]; then
    make_opts+=(DTC="$DTC" PYTHON3="${PYTHON3:-python3}")
fi

{
    cat "$here/sandbox.fragment"
    echo "CONFIG_ENV_DEFAULT_ENV_TEXT_FILE=\"$work/test.env\""
} >"$work/sandbox.fragment"
if ! cmp -s "$work/sandbox.fragment" "$build/.green-fragment" 2>/dev/null; then
    make "${make_opts[@]}" sandbox_defconfig
    "$src/scripts/kconfig/merge_config.sh" -m -O "$build" "$build/.config" "$work/sandbox.fragment" >/dev/null
    make "${make_opts[@]}" olddefconfig
    cp "$work/sandbox.fragment" "$build/.green-fragment"
fi
echo "Building the sandbox (once; later runs relink only)..."
# `u-boot tools` stops short of binman, which would need pylibfdt.
make "${make_opts[@]}" -j"$jobs" u-boot tools >"$work/build.log" 2>&1 ||
    { tail -40 "$work/build.log"; die "sandbox build failed (log: $work/build.log)"; }

dtc_bin=${DTC:-$build/scripts/dtc/dtc}
exec python3 "$here/matrix.py" \
    --uboot "$build/u-boot" \
    --mkenvimage "$build/tools/mkenvimage" \
    --dtc "$dtc_bin" \
    --src "$src" \
    --build "$build" \
    --env "$env_file" \
    --repo "$repo" \
    --work "$work/run"

#!/usr/bin/env bash
# Fixture test for the merge rules of scripts/sync-base.sh.
set -euo pipefail

sync=$(cd "$(dirname "$0")" && pwd)/sync-base.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
t=$tmp/board
fails=0

ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

mixexs() {
    printf '{:nerves_system_br, "%s", runtime: false},\n{:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", runtime: false},\n' "$1"
}

reset() {
    rm -rf "$t"
    mkdir -p "$t/base/rootfs_overlay/etc"
    cat >"$t/base/nerves_defconfig" <<'DEF'
BR2_aarch64=y
# BR2_PACKAGE_A is not set
BR2_PACKAGE_B=y
# base comment
BR2_ROOTFS_OVERLAY="${BR2_EXTERNAL_NERVES_PATH}/x ${NERVES_DEFCONFIG_DIR}/rootfs_overlay"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="${NERVES_DEFCONFIG_DIR}/hw.config"
BR2_NERVES_SYSTEM_NAME="base"
DEF
    echo 'source "$NERVES_DEFCONFIG_DIR/package/a/Config.in"' >"$t/base/Config.in"
    echo '-c ttyX' >"$t/base/rootfs_overlay/etc/erlinit.config"
    mixexs 1.35.3 >"$t/base/mix.exs"
    mixexs 1.35.3 >"$t/mix.exs"
    cat >"$t/nerves_defconfig.fragment" <<'DEF'
BR2_NERVES_SYSTEM_NAME="product"
BR2_ROOTFS_OVERLAY="${NERVES_DEFCONFIG_DIR}/rootfs_overlay"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="${NERVES_DEFCONFIG_DIR}/a.config ${NERVES_DEFCONFIG_DIR}/b.config"
# product comment
BR2_PACKAGE_A=y
# BR2_PACKAGE_B is not set
DEF
    echo 'source "$NERVES_DEFCONFIG_DIR/package/p/Config.in"' >"$t/Config.in.fragment"
    echo '-m cgroup2:/sys/fs/cgroup:cgroup2::' >"$t/erlinit.config.fragment"
}

has() { grep -qxF -- "$2" "$1"; }
count() { grep -cE -- "$2" "$1" || true; }

reset
"$sync" "$t" >/dev/null
d=$t/nerves_defconfig

has "$d" 'BR2_NERVES_SYSTEM_NAME="product"' && [ "$(count "$d" '^BR2_NERVES_SYSTEM_NAME=')" = 1 ] &&
    ok "scalar override replaces the base value" || bad "scalar override"

has "$d" 'BR2_PACKAGE_A=y' && [ "$(count "$d" 'BR2_PACKAGE_A[= ]')" = 1 ] &&
    ok "scalar overrides a base 'is not set'" || bad "scalar over not-set"

has "$d" '# BR2_PACKAGE_B is not set' && [ "$(count "$d" 'BR2_PACKAGE_B[= ]')" = 1 ] &&
    ok "'is not set' overrides a base scalar" || bad "not-set over scalar"

has "$d" 'BR2_ROOTFS_OVERLAY="${BR2_EXTERNAL_NERVES_PATH}/x ${NERVES_DEFCONFIG_DIR}/base/rootfs_overlay ${NERVES_DEFCONFIG_DIR}/rootfs_overlay"' &&
    has "$d" 'BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="${NERVES_DEFCONFIG_DIR}/base/hw.config ${NERVES_DEFCONFIG_DIR}/a.config ${NERVES_DEFCONFIG_DIR}/b.config"' &&
    [ "$(count "$d" '^BR2_ROOTFS_OVERLAY=')" = 1 ] &&
    ok "list values append in place, base paths rewritten, fragment paths not" || bad "list append / path rewrite"

has "$d" '# base comment' && has "$d" '# product comment' &&
    ok "comments pass through" || bad "comments"

has "$t/Config.in" 'source "$NERVES_DEFCONFIG_DIR/base/package/a/Config.in"' &&
    has "$t/Config.in" 'source "$NERVES_DEFCONFIG_DIR/package/p/Config.in"' &&
    ok "Config.in rewrites base paths only" || bad "Config.in"

e=$t/rootfs_overlay/etc/erlinit.config
[ "$(head -n 1 "$e")" = '-c ttyX' ] && [ "$(tail -n 1 "$e")" = '-m cgroup2:/sys/fs/cgroup:cgroup2::' ] &&
    ok "erlinit.config is base then fragment" || bad "erlinit.config"

"$sync" "$t" --check >/dev/null && ok "--check passes right after a sync" || bad "--check clean"

echo "# edited" >>"$d"
if "$sync" "$t" --check >/dev/null; then bad "--check missed drift"; else ok "--check fails on drift"; fi

reset
echo 'BR2_LINUX_KERNEL_PATCH="${NERVES_DEFCONFIG_DIR}/p"' >>"$t/nerves_defconfig.fragment"
if "$sync" "$t" >/dev/null 2>&1; then bad "missing list"; else ok "appending to a list base does not set fails"; fi

reset
mixexs 1.35.2 >"$t/mix.exs"
if "$sync" "$t" >/dev/null 2>&1; then bad "pin mismatch"; else ok "a nerves_system_br pin mismatch fails"; fi

[ $fails -eq 0 ] || { echo "$fails sync-base test(s) failed"; exit 1; }

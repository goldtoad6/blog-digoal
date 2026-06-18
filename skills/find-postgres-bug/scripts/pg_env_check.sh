#!/usr/bin/env bash
# pg_env_check.sh [pg_install_dir]
# 体检: OS、kernel、locale、编译器、构建依赖、PG 可执行文件、动态库
set -uo pipefail
INSTALL="${1:-}"

echo "=== OS ==="
uname -a
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "ID=$ID VERSION=$VERSION_ID"
fi
echo
echo "=== Locale ==="
locale 2>/dev/null | head -8
echo
echo "=== Compilers / Build tools ==="
for t in gcc g++ clang make bison flex perl python3; do
    if command -v "$t" >/dev/null 2>&1; then
        printf '%-8s %s\n' "$t" "$($t --version 2>/dev/null | head -1)"
    else
        printf '%-8s MISSING\n' "$t"
    fi
done
echo
echo "=== Libraries ==="
for h in readline zlib openssl icu-uc xml2 xslt; do
    case "$h" in
        icu-uc) pkg="icu-uc";;
        *) pkg="$h";;
    esac
    if pkg-config --exists "$pkg" 2>/dev/null; then
        printf '%-8s %s\n' "$pkg" "$(pkg-config --modversion "$pkg")"
    else
        printf '%-8s not-found\n' "$pkg"
    fi
done
echo
echo "=== PG install dir: ${INSTALL:-<not given>} ==="
if [ -n "$INSTALL" ] && [ -d "$INSTALL" ]; then
    BIN="$INSTALL/bin"
    for b in postgres pg_ctl initdb psql pg_config pg_isready; do
        if [ -x "$BIN/$b" ]; then
            printf '%-12s %s\n' "$b" "$("$BIN/$b" --version 2>/dev/null || echo '?')"
        else
            printf '%-12s MISSING\n' "$b"
        fi
    done
    echo
    echo "--- pg_config ---"
    "$BIN/pg_config" 2>/dev/null || true
    echo
    echo "--- shared libs ---"
    for so in "$INSTALL/lib"/*.so*; do
        [ -e "$so" ] && ldd "$so" 2>/dev/null | grep -E "not found" && echo "  ^ missing dep on $so"
    done | head -20
else
    echo "(skipping PG install checks)"
fi
echo
echo "=== Core dump config ==="
ulimit -c
sysctl kern.corefile 2>/dev/null || true

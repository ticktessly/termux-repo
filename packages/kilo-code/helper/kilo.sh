#!/bin/sh
set -e

# kilo launcher: glibc bridge + exec-spawn shim, no proot.
#
# Kilo starts its background daemon by re-executing
# [process.execPath, "serve", ...]. Under an explicit loader invocation
# execPath is the loader itself, so that spawn would become
# `ld-linux "serve" ...` and fail with exit 127. execshim.so (LD_PRELOAD)
# rewrites it to `ld-linux $KILO_BIN serve ...`. The shim removes itself
# from child environments, so bionic tools Kilo spawns (shell, ripgrep,
# MCP servers, ...) are unaffected. See helper/execshim.c.

unset LD_PRELOAD
unset LD_LIBRARY_PATH

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LIBDIR="${PREFIX}/lib/kilo-code"
REAL_BIN="${LIBDIR}/kilo"

LD_LOADER="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"

export KILO_BIN="${REAL_BIN}"
export LD_PRELOAD="${LIBDIR}/execshim.so"
export SSL_CERT_FILE="${SSL_CERT_FILE:-${PREFIX}/etc/tls/cert.pem}"
# The .deb owns this install; never let upstream self-update replace it.
export KILO_DISABLE_AUTOUPDATE=1
# Bun is unable to locate the bundled /console and /tree-sitter assets when
# launched via the loader (execPath is the loader), so point at them here.
export KILO_TREE_SITTER_WASM_DIR="${KILO_TREE_SITTER_WASM_DIR:-${LIBDIR}/tree-sitter}"
export KILO_CONSOLE_ASSET_DIR="${KILO_CONSOLE_ASSET_DIR:-${LIBDIR}/console}"

exec "$LD_LOADER" "$REAL_BIN" "$@"

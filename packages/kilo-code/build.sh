#!/usr/bin/env bash
set -euo pipefail

# kilo-code: Kilo Code CLI (opencode fork) for Termux.
#
# Strategy: the upstream glibc Bun single-executable + runtime assets
# (MIT-licensed, redistributed) are bundled in the deb and exec'ed through
# Termux's glibc loader with an exec-spawn shim, so the daemon's
# [execPath, "serve", ...] self-re-exec keeps working; no proot required.
#
# Builds the aarch64 deb.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBS_DIR="$REPO_ROOT/debs"
mkdir -p "$DEBS_DIR"

VERSION="${KILO_VERSION:-$(cat "$SCRIPT_DIR/VERSION")}"
VERSION="${VERSION#v}"
DEB_VERSION="${VERSION}-1"
PREFIX="data/data/com.termux/files/usr"
ARCH="aarch64"
UPSTREAM_ARCH="arm64"
UPSTREAM_REPO="Kilo-Org/kilocode"

echo "=== Building kilo-code ${DEB_VERSION} (${ARCH}) ==="

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

PKG_DIR="${BUILD_DIR}/kilo-code_${DEB_VERSION}_${ARCH}"
LIB_DIR="${PKG_DIR}/${PREFIX}/lib/kilo-code"
mkdir -p "${PKG_DIR}/DEBIAN" \
         "${PKG_DIR}/${PREFIX}/bin" \
         "$LIB_DIR" \
         "${PKG_DIR}/${PREFIX}/share/doc/kilo-code"

# --- Download the release tarball + checksums, verify, extract ---
TARBALL="${BUILD_DIR}/kilo-linux-${UPSTREAM_ARCH}.tar.gz"
SUMS="${BUILD_DIR}/kilo-cli-SHA256SUMS"
BASE_URL="https://github.com/${UPSTREAM_REPO}/releases/download/v${VERSION}"
echo "Downloading kilo ${VERSION} (${UPSTREAM_ARCH})..."
curl -fSL "$BASE_URL/kilo-linux-${UPSTREAM_ARCH}.tar.gz" -o "$TARBALL"
curl -fSL "$BASE_URL/kilo-cli-SHA256SUMS" -o "$SUMS"

(cd "$BUILD_DIR" && grep " kilo-linux-${UPSTREAM_ARCH}.tar.gz$" kilo-cli-SHA256SUMS | sha256sum -c -)
echo "Checksum verified."

echo "Extracting..."
tar -xzf "$TARBALL" -C "$LIB_DIR"

for f in kilo bwrap kilo-sandbox-seccomp; do
    if [ -f "$LIB_DIR/$f" ]; then chmod 755 "$LIB_DIR/$f"; fi
done
find "$LIB_DIR" -type d -exec chmod 755 {} +
find "$LIB_DIR" -type f -name '*.js' -exec chmod 644 {} +
# Do NOT strip or patchelf the binary: Bun single-executable bundles embed
# their payload at fixed offsets and break when headers are rewritten.

# --- Compile the exec-spawn shim with a glibc-targeting compiler ---
# Must NOT be Termux's bionic gcc: the shim loads into the glibc process.
find_glibc_cc() {
    for c in "${CC:-aarch64-linux-gnu-gcc}" \
             "${TERMUX_PREFIX:-/data/data/com.termux/files/usr}/glibc/bin/aarch64-linux-gnu-gcc" \
             "${TERMUX_PREFIX:-/data/data/com.termux/files/usr}/glibc/bin/aarch64-linux-gnu-gcc-14.2.1"; do
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

SHIM_CC="$(find_glibc_cc)" || {
    echo "Error: no glibc-targeting C compiler found." >&2
    echo "On Termux: pkg install glibc-repo && pkg install gcc-glibc" >&2
    echo "On a build host: install gcc-aarch64-linux-gnu (or set CC)." >&2
    exit 1
}
echo "Compiling execshim.so with ${SHIM_CC}..."
# env -u: the glibc toolchain itself cannot start with Termux's bionic
# termux-exec preload active. PATH: the driver needs its sibling binutils.
env -u LD_PRELOAD -u LD_LIBRARY_PATH \
    PATH="$(dirname "$SHIM_CC"):$PATH" \
    "$SHIM_CC" -shared -fPIC -O2 -o "${BUILD_DIR}/execshim.so" "$SCRIPT_DIR/helper/execshim.c"
if ! readelf -d "${BUILD_DIR}/execshim.so" | grep -q 'libc\.so\.6'; then
    echo "Error: execshim.so is not glibc-linked (built with a bionic gcc?)" >&2
    exit 1
fi
install -Dm755 "${BUILD_DIR}/execshim.so" "$LIB_DIR/execshim.so"

install -Dm755 "$SCRIPT_DIR/helper/kilo.sh" "${PKG_DIR}/${PREFIX}/bin/kilo"
chmod 755 "${PKG_DIR}/${PREFIX}/bin/kilo"
ln -sf kilo "${PKG_DIR}/${PREFIX}/bin/kilocode"

install -Dm644 "$SCRIPT_DIR/helper/LICENSE" "${PKG_DIR}/${PREFIX}/share/doc/kilo-code/LICENSE"

cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: kilo-code
Version: ${DEB_VERSION}
Architecture: ${ARCH}
Maintainer: ticktessly <246650556+ticktessly@users.noreply.github.com>
Depends: glibc-repo, glibc, ripgrep, git, nodejs-lts, ca-certificates, bash
Conflicts: kilocode
Replaces: kilocode
Section: devel
Priority: optional
Homepage: https://github.com/${UPSTREAM_REPO}
Description: Kilo Code CLI - open source AI coding agent for the terminal
 Kilo Code is an agentic coding assistant available in VS Code, JetBrains,
 and the CLI. This package runs the upstream glibc binary on Termux's glibc
 bridge with an exec-spawn shim; no proot required. The binary and its
 runtime assets are bundled; update via APT, not 'kilo upgrade'.
EOF

DEB_FILE="${DEBS_DIR}/kilo-code_${DEB_VERSION}_termux_${ARCH}.deb"
export REPRO_MTIME
REPRO_MTIME="$(git -C "$REPO_ROOT" log -1 --format=%ct -- packages/kilo-code 2>/dev/null || git -C "$REPO_ROOT" log -1 --format=%ct)"
bash "$REPO_ROOT/scripts/build-deb.sh" "$PKG_DIR" "$DEB_FILE"
echo "Built: $DEB_FILE"

#!/usr/bin/env bash
#
# Build a universal (arm64 + x86_64) macOS xcframework bundling libgit2,
# libssh2, and mbedTLS as a single static archive. Output:
#
#   dist/libgit2.xcframework
#   dist/libgit2.xcframework.zip   (uploaded to a GitHub Release)
#   dist/libgit2.xcframework.zip.sha256
#
# Source tarballs are fetched from upstream by tag — this script does not
# require any sibling git clones.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
WORK_DIR="${TMPDIR:-/tmp}/pushysh-libgit2-build"

LIBGIT2_VERSION="1.9.2"
LIBSSH2_VERSION="1.11.1"
MBEDTLS_VERSION="3.6.2"

DEPLOYMENT_TARGET="14.0"
ARCHS="arm64;x86_64"

CLANG="$(xcrun --find clang)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "${WORK_DIR}" "${DIST_DIR}"
mkdir -p "${WORK_DIR}/src" "${WORK_DIR}/install" "${DIST_DIR}"

INSTALL_DIR="${WORK_DIR}/install"

fetch_tarball() {
    local url="$1"
    local out_dir="$2"
    local archive="${WORK_DIR}/$(basename "${url}")"
    curl -fsSL "${url}" -o "${archive}"
    mkdir -p "${out_dir}"
    tar -xf "${archive}" -C "${out_dir}" --strip-components=1
}

# ---------------------------------------------------------------------------
# mbedTLS — crypto backend for libssh2
#
# mbedTLS's CMake configuration depends on a `framework/` git submodule that
# is not bundled in the auto-generated GitHub archive tarball. Clone with
# --recursive instead.
# ---------------------------------------------------------------------------
MBEDTLS_SRC="${WORK_DIR}/src/mbedtls"
git clone --depth=1 --recursive \
    --branch "mbedtls-${MBEDTLS_VERSION}" \
    https://github.com/Mbed-TLS/mbedtls.git \
    "${MBEDTLS_SRC}"

cmake \
    -S "${MBEDTLS_SRC}" \
    -B "${WORK_DIR}/build/mbedtls" \
    -G "Unix Makefiles" \
    -DCMAKE_C_COMPILER="${CLANG}" \
    -DCMAKE_OSX_ARCHITECTURES="${ARCHS}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON
cmake --build "${WORK_DIR}/build/mbedtls" --config Release --target install

# ---------------------------------------------------------------------------
# libssh2 — SSH transport, mbedTLS-backed
# ---------------------------------------------------------------------------
LIBSSH2_SRC="${WORK_DIR}/src/libssh2"
fetch_tarball \
    "https://github.com/libssh2/libssh2/releases/download/libssh2-${LIBSSH2_VERSION}/libssh2-${LIBSSH2_VERSION}.tar.gz" \
    "${LIBSSH2_SRC}"

cmake \
    -S "${LIBSSH2_SRC}" \
    -B "${WORK_DIR}/build/libssh2" \
    -G "Unix Makefiles" \
    -DCMAKE_C_COMPILER="${CLANG}" \
    -DCMAKE_OSX_ARCHITECTURES="${ARCHS}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_PREFIX_PATH="${INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DCRYPTO_BACKEND=mbedTLS
cmake --build "${WORK_DIR}/build/libssh2" --config Release --target install

# ---------------------------------------------------------------------------
# libgit2 — HTTPS via SecureTransport, SSH via libssh2
# ---------------------------------------------------------------------------
LIBGIT2_SRC="${WORK_DIR}/src/libgit2"
fetch_tarball \
    "https://github.com/libgit2/libgit2/archive/refs/tags/v${LIBGIT2_VERSION}.tar.gz" \
    "${LIBGIT2_SRC}"

cmake \
    -S "${LIBGIT2_SRC}" \
    -B "${WORK_DIR}/build/libgit2" \
    -G "Unix Makefiles" \
    -DCMAKE_C_COMPILER="${CLANG}" \
    -DCMAKE_OSX_ARCHITECTURES="${ARCHS}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_PREFIX_PATH="${INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_CLI=OFF \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_SSH=libssh2 \
    -DUSE_GSSAPI=OFF \
    -DUSE_THREADS=ON \
    -DREGEX_BACKEND=builtin \
    -DUSE_HTTP_PARSER=builtin
cmake --build "${WORK_DIR}/build/libgit2" --config Release --target install

# ---------------------------------------------------------------------------
# Merge all static archives into a single fat libgit2-bundle.a
# ---------------------------------------------------------------------------
BUNDLE="${WORK_DIR}/libgit2-bundle.a"
LIB_DIR="${INSTALL_DIR}/lib"

REQUIRED_LIBS=(
    libgit2.a
    libssh2.a
    libmbedtls.a
    libmbedcrypto.a
    libmbedx509.a
)

LIB_PATHS=()
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "${LIB_DIR}/${lib}" ]]; then
        echo "Expected static archive missing: ${LIB_DIR}/${lib}" >&2
        exit 1
    fi
    LIB_PATHS+=("${LIB_DIR}/${lib}")
done

libtool -static -o "${BUNDLE}" "${LIB_PATHS[@]}"

# ---------------------------------------------------------------------------
# Stage headers (libgit2 only — that's what LibGit2Shims imports)
# ---------------------------------------------------------------------------
HEADERS_DIR="${WORK_DIR}/headers"
rm -rf "${HEADERS_DIR}"
mkdir -p "${HEADERS_DIR}"
cp -R "${INSTALL_DIR}/include/git2" "${HEADERS_DIR}/"
cp "${INSTALL_DIR}/include/git2.h" "${HEADERS_DIR}/"

# ---------------------------------------------------------------------------
# Build the xcframework
# ---------------------------------------------------------------------------
XCFRAMEWORK="${DIST_DIR}/libgit2.xcframework"
rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
    -library "${BUNDLE}" \
    -headers "${HEADERS_DIR}" \
    -output "${XCFRAMEWORK}"

cat > "${XCFRAMEWORK}/macos-arm64_x86_64/Headers/module.modulemap" <<'MODULEMAP'
module libgit2 {
    header "git2.h"
    export *
}
MODULEMAP

# ---------------------------------------------------------------------------
# Zip + checksum for SwiftPM .binaryTarget(url:, checksum:)
# ---------------------------------------------------------------------------
ZIP_PATH="${DIST_DIR}/libgit2.xcframework.zip"
( cd "${DIST_DIR}" && zip -qr "$(basename "${ZIP_PATH}")" "$(basename "${XCFRAMEWORK}")" )

SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo "${SHA256}" > "${ZIP_PATH}.sha256"

cat <<INFO

Build complete.

  xcframework : ${XCFRAMEWORK}
  zip         : ${ZIP_PATH}
  sha256      : ${SHA256}

Versions:
  libgit2     v${LIBGIT2_VERSION}
  libssh2     v${LIBSSH2_VERSION}
  mbedTLS     v${MBEDTLS_VERSION}

Next steps:
  1. git tag libgit2-v${LIBGIT2_VERSION}-1 && git push origin libgit2-v${LIBGIT2_VERSION}-1
  2. Create a GitHub Release on that tag and upload libgit2.xcframework.zip.
  3. In Pushy, set Packages/LibGit2Runtime/Package.swift binaryTarget to:
       url:      <release asset URL>
       checksum: ${SHA256}

INFO

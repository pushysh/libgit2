# libgit2

Build-and-publish repo for the `libgit2.xcframework` consumed by the Pushy
macOS app via Swift Package Manager.

This repo does **not** contain libgit2 source. `build.sh` fetches upstream
release tarballs (libgit2, libssh2, mbedTLS), compiles them as static
archives for `arm64;x86_64` (macOS 14+), merges them into a single
`libgit2-bundle.a`, and produces `dist/libgit2.xcframework.zip` plus a
sha256. The zip is uploaded to a GitHub Release on this repo, where Pushy's
`Packages/LibGit2Runtime/Package.swift` references it via
`.binaryTarget(url:, checksum:)`.

## Build

```sh
./build.sh
```

Outputs land in `dist/`:

- `libgit2.xcframework`
- `libgit2.xcframework.zip`
- `libgit2.xcframework.zip.sha256`

Required tools: Xcode (for `xcodebuild` + the macOS SDK), `cmake`, `curl`,
`libtool`, `zip`, `shasum`. All standard on macOS or available via Homebrew.

## Build flags

- libgit2: `USE_HTTPS=SecureTransport`, `USE_SSH=libssh2`,
  `BUILD_SHARED_LIBS=OFF`, `REGEX_BACKEND=builtin`,
  `USE_HTTP_PARSER=builtin`.
- libssh2: `CRYPTO_BACKEND=mbedTLS`, `BUILD_SHARED_LIBS=OFF`.
- mbedTLS: `ENABLE_PROGRAMS=OFF`, `ENABLE_TESTING=OFF`,
  `USE_STATIC_MBEDTLS_LIBRARY=ON`.

Deployment target: macOS 14.0. Architectures: arm64 + x86_64 universal.

## Releasing

1. `./build.sh` — capture the printed sha256.
2. `git tag libgit2-v<libgit2-version>-<build>` (e.g. `libgit2-v1.9.2-1`)
   and `git push origin <tag>`. Bump the `-<build>` suffix when only build
   flags change; bump the libgit2 version when the upstream pin moves.
3. Create a GitHub Release on the tag at
   <https://github.com/pushysh/libgit2/releases/new>, upload
   `dist/libgit2.xcframework.zip`.
4. In the Pushy app repo, update `url:` and `checksum:` in
   `Packages/LibGit2Runtime/Package.swift` to point at the new asset and
   the captured sha256. Commit. SwiftPM will fetch + checksum-verify on the
   next resolve.

## Versions currently pinned

| dep      | version |
|----------|---------|
| libgit2  | 1.9.2   |
| libssh2  | 1.11.1  |
| mbedTLS  | 3.6.2   |

Update by editing the constants at the top of `build.sh` and bumping the
release tag.

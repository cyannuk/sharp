# Minimal libvips with HEIC/HEVC support

Builds libvips and its dependencies for `linux-x64` (Debian 13 Trixie)
and `win32-x64` (Windows 10+, cross-compiled on Debian with llvm-mingw)
with support for:

- decoding: JPEG, PNG, WebP, TIFF, AVIF and HEIC (HEVC-compressed HEIF, via libde265)
- encoding: WebP

- linux-x64: shared `libvips-cpp.so` in `vendor/sharp-libvips-linux-x64`,
  used in place of `@img/sharp-libvips-linux-x64` both when building `sharp.node` and at runtime.
- win32-x64: static libraries in `vendor/sharp-libvips-win32-x64`, linked by `build-sharp-win32.sh`
  into a single `sharp-win32-x64-<version>.node` that depends only on Windows system DLLs
  (UCRT, kernel32 etc.) and on `node.exe` via Node-API. Unlike upstream, it is built with
  clang/libc++ (llvm-mingw) rather than MSVC, which Node-API's C ABI allows.

This is an adaptation of
[sharp-libvips v1.3.4](https://github.com/lovell/sharp-libvips/tree/v1.3.4)
`build/posix.sh` that runs natively without Docker.
Versions of the dependencies that are built are identical to upstream,
see `versions.properties`, with the addition of libde265.

Dependencies only needed for other formats are not built
(librsvg, cairo, pango and font libraries, cgif, libimagequant, libarchive, libultrahdr),
the AV1 encoder is excluded from aom and the built-in GIF loader is disabled.
ICC profiles (lcms) and EXIF (libexif) remain supported.

JPEG, PNG and TIFF output remain available, as these encoders are part of
the same libraries as the decoders. HEIF/AVIF output is not available.

## Prerequisites

```sh
sudo apt-get install --no-install-recommends build-essential pkgconf cmake nasm \
  gettext patch curl ca-certificates xz-utils binutils python3-packaging python3-venv
```

Meson >= 1.11 and Ninja are installed automatically into a venv within `.libvips-build`.

For win32-x64, [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (UCRT, Ubuntu x86_64 host build):

```sh
mkdir -p ~/.local && cd ~/.local
curl -L https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64.tar.xz | tar xJ
ln -sfn llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64 llvm-mingw
```

## Build

```sh
npm install
npm run build:libvips-heic                         # linux-x64 libvips and dependencies
PLATFORM=win32-x64 npm run build:libvips-heic      # win32-x64 libvips and dependencies
npm run package-heic         # dist, both sharp.node and sharp-<version>.tgz (runtime files only)
```

Environment variables:

- `JOBS`: parallel compile jobs, default 2 (each job may need ~1GB memory)
- `PLATFORM`: `linux-x64` (default) or `win32-x64`
- `BUILD_DIR`: sources and intermediate files, default `.libvips-build/<PLATFORM>`
- `OUTPUT_DIR`: resulting package, default `vendor/sharp-libvips-<PLATFORM>`
- `LLVM_MINGW`: llvm-mingw directory for win32-x64, default `~/.local/llvm-mingw`

A failed build can be re-run; dependencies that were already built are skipped.
Remove `BUILD_DIR` to start from scratch.

## Install

The package is restricted to Linux and Windows on x64 (`os` and `cpu` in `package.json`),
npm refuses to install it elsewhere with `EBADPLATFORM`.
Linux requires glibc: on musl (Alpine) it installs, but fails to load.
On Linux it has no dependencies on system libraries other than glibc, libstdc++ and libgcc,
GLib/GObject/GIO and all codecs are linked statically into `libvips-cpp.so`.
On Windows everything is linked statically into `sharp-win32-x64-<version>.node`.

Commit the tarball to the application repository and reference it from its `package.json`:

```json
"dependencies": {
  "sharp": "file:vendor/sharp-0.35.5.tgz"
}
```

```dockerfile
FROM node:24-trixie-slim
WORKDIR /app
COPY package.json package-lock.json ./
COPY vendor ./vendor
RUN npm ci --omit=dev
```

```ts
import sharp from 'sharp';
sharp.versions.de265; // '1.1.3'
await sharp('photo.heic').webp().toFile('photo.webp');
```

## Licensing

See `THIRD-PARTY-NOTICES.md`; libde265 is LGPL-3.0.
HEVC is covered by patents that may require a license in some jurisdictions.

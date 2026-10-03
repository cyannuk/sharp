#!/usr/bin/env bash
set -e

## Copyright 2017 Lovell Fuller and others.
## SPDX-License-Identifier: Apache-2.0

# Build a minimal libvips and its dependencies that decodes JPEG, PNG, WebP, TIFF, AVIF and HEIC, and encodes WebP, for:
# - linux-x64 (Debian 13 Trixie): shared libvips-cpp.so, built natively
# - win32-x64: static libraries, cross-compiled with llvm-mingw, to be linked into sharp.node (see build-sharp-win32.sh)
#
# Adapted from https://github.com/lovell/sharp-libvips/blob/v1.3.4/build/posix.sh
# to run on a Debian host without Docker. Differences from upstream:
# - libde265 is built and statically linked into libheif (decode only, no x265)
# - aom is built without the AV1 encoder
# - dependencies only needed for other formats are not built: SVG (librsvg, cairo, pango, fonts),
#   GIF output (cgif, libimagequant), Deep Zoom (libarchive), Ultra HDR (libultrahdr)
#   and the corresponding loaders/savers are disabled in libvips, including the built-in GIF loader
# - JPEG, PNG and TIFF output remain available, as these encoders are part of the same libraries as the decoders
# - each dependency is built once; re-running the script resumes after the last completed step
# - number of parallel jobs is limited via JOBS (default: 2) to fit hosts with little memory
#
# Usage: [PLATFORM=linux-x64|win32-x64] scripts/libvips-heic/build.sh
#
# Environment variables:
# - PLATFORM: linux-x64 (default) or win32-x64
# - JOBS: number of parallel compile jobs (default: 2)
# - BUILD_DIR: working directory for sources and intermediate files (default: <repo>/.libvips-build/<PLATFORM>)
# - OUTPUT_DIR: destination of the resulting package (default: <repo>/vendor/sharp-libvips-<PLATFORM>)
# - LLVM_MINGW: llvm-mingw toolchain directory for win32-x64 (default: ~/.local/llvm-mingw)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source ${SCRIPT_DIR}/versions.properties

PLATFORM=${PLATFORM:-linux-x64}
case ${PLATFORM} in
  linux-x64) LINUX=true ;;
  win32-x64)
    WIN=true
    CHOST=x86_64-w64-mingw32
    LLVM_MINGW=${LLVM_MINGW:-$HOME/.local/llvm-mingw}
    export PATH="${LLVM_MINGW}/bin:${PATH}"
    ;;
  *) echo "Unsupported PLATFORM: ${PLATFORM}" && exit 1 ;;
esac
JOBS=${JOBS:-2}
BUILD_DIR=${BUILD_DIR:-${REPO_DIR}/.libvips-build/${PLATFORM}}
OUTPUT_DIR=${OUTPUT_DIR:-${REPO_DIR}/vendor/sharp-libvips-${PLATFORM}}

# Recent dependencies require a newer Meson than Debian provides, install it into a venv (as upstream does via pip)
VENV_DIR=${REPO_DIR}/.libvips-build/venv
if ! [ -x "${VENV_DIR}/bin/meson" ]; then
  python3 -m venv ${VENV_DIR}
  ${VENV_DIR}/bin/pip install --quiet meson ninja
fi
export PATH="${VENV_DIR}/bin:${PATH}"

TOOLS="make cmake meson ninja nasm pkgconf curl patch strings"
if [ "$LINUX" = true ]; then
  TOOLS+=" gcc g++ readelf c++filt"
else
  TOOLS+=" ${CHOST}-clang ${CHOST}-clang++ ${CHOST}-ar ${CHOST}-windres ${CHOST}-objdump"
fi
for tool in $TOOLS; do
  if ! [ -x "$(command -v $tool)" ]; then
    echo "Required tool not found: $tool"
    echo "See ${SCRIPT_DIR}/README.md for prerequisites"
    exit 1
  fi
done

# Remove patch version component
without_patch() {
  echo "${1%.[[:digit:]]*}"
}
# Remove prerelease suffix
without_prerelease() {
  echo "${1%-[[:alnum:]]*}"
}

DEPS=${BUILD_DIR}/deps
TARGET=${BUILD_DIR}/target
ROOT=${SCRIPT_DIR}
VIPS_CPP_DEP=libvips-cpp.so.$(without_prerelease $VERSION_VIPS)

mkdir -p ${DEPS}
mkdir -p ${TARGET}

# Equivalent of the linux-x64 Docker image settings
export FLAGS="-march=nehalem"
mkdir -p ${BUILD_DIR}/bin
cp ${ROOT}/pkgconf-wrapper ${BUILD_DIR}/bin/x86_64-linux-gnu-pkgconf
chmod +x ${BUILD_DIR}/bin/x86_64-linux-gnu-pkgconf
export PATH="${BUILD_DIR}/bin:${PATH}"
export PKG_CONFIG="x86_64-linux-gnu-pkgconf --static"

# Default optimisation level is for binary size (-Os)
# Overridden to performance (-O3) for select dependencies that benefit
export FLAGS+=" -Os"

# Allow linker to remove unused sections
export FLAGS+=" -ffunction-sections -fdata-sections"

if [ "$LINUX" = true ]; then
  # Remove async exception unwind/backtrace tables
  export FLAGS+=" -fPIC -fno-asynchronous-unwind-tables"
  export MESON="--native-file=${ROOT}/meson.ini"
  TOOLCHAIN=${ROOT}/Toolchain.cmake
else
  # All dependencies are static libraries, ensure headers do not declare their symbols as dllimport
  export FLAGS+=" -DG_INTL_STATIC_COMPILATION -DLIBDE265_STATIC_BUILD -DLIBHEIF_STATIC_BUILD -DGLIB_STATIC_COMPILATION -DGOBJECT_STATIC_COMPILATION -DGIO_STATIC_COMPILATION -DGMODULE_STATIC_COMPILATION"
  export CC=${CHOST}-clang CXX=${CHOST}-clang++ AR=${CHOST}-ar RANLIB=${CHOST}-ranlib STRIP=${CHOST}-strip WINDRES=${CHOST}-windres RC=${CHOST}-windres
  TOOLCHAIN=${ROOT}/Toolchain-win32-x64.cmake
  # Meson ignores CFLAGS etc. of the environment for the host machine when cross-compiling
  MESON_FLAGS="'$(echo ${FLAGS} | sed "s/ /', '/g")'"
  cat > ${BUILD_DIR}/meson-cross.ini <<EOF_CROSS
[binaries]
c = '${CHOST}-clang'
cpp = '${CHOST}-clang++'
ar = '${CHOST}-ar'
strip = '${CHOST}-strip'
windres = '${CHOST}-windres'
pkg-config = ['x86_64-linux-gnu-pkgconf', '--static']

[properties]
pkg_config_libdir = '${TARGET}/lib/pkgconfig'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
libdir = 'lib'
wrap_mode = 'nofallback'
c_args = [${MESON_FLAGS}, '-I${TARGET}/include']
cpp_args = [${MESON_FLAGS}, '-I${TARGET}/include']
c_link_args = ['-L${TARGET}/lib', '-Wl,--gc-sections']
cpp_link_args = ['-L${TARGET}/lib', '-Wl,--gc-sections']
EOF_CROSS
  export MESON="--cross-file=${BUILD_DIR}/meson-cross.ini"
fi

# Common build paths and flags
export PKG_CONFIG_LIBDIR="${TARGET}/lib/pkgconfig"
export PATH="${PATH}:${TARGET}/bin"
export LD_LIBRARY_PATH="${TARGET}/lib"
export CFLAGS="${FLAGS}"
export CXXFLAGS="${FLAGS}"
export CPPFLAGS="-I${TARGET}/include"
export LDFLAGS="-L${TARGET}/lib"

export LDFLAGS+=" -Wl,--gc-sections"
if [ "$LINUX" = true ]; then
  # Create a relocatable library
  export LDFLAGS+=" -Wl,-rpath=\$ORIGIN/"
fi

export MAKEFLAGS="-j${JOBS}"

# Expose target sysroot to CMake
export TARGET_SYSROOT="${TARGET}"

# We don't want to use any native libraries, so unset PKG_CONFIG_PATH
unset PKG_CONFIG_PATH

# Common options for curl
CURL="curl --silent --show-error --fail --location --retry 3 --retry-max-time 30"

# Run a build step only once; a marker file records completion
step() {
  local name=$1
  shift
  if [ -f "${DEPS}/.done-${name}" ]; then
    echo "Skipping ${name} (already built)"
    return
  fi
  echo "Building ${name}..."
  rm -rf ${DEPS}/${name}
  mkdir ${DEPS}/${name}
  cd ${DEPS}/${name}
  "$@"
  touch "${DEPS}/.done-${name}"
}

# Limit parallelism of ninja, which otherwise ignores MAKEFLAGS
meson_install() {
  meson compile -C _build -j ${JOBS}
  meson install -C _build --no-rebuild "$@"
}

# Download and build dependencies from source

build_zlib_ng() {
  $CURL https://github.com/zlib-ng/zlib-ng/archive/${VERSION_ZLIB_NG}.tar.gz | tar xz --strip-components=1
  CFLAGS="${CFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=FALSE -DZLIB_COMPAT=TRUE -DWITH_ARMV6=FALSE
  make install/strip
}
step zlib-ng build_zlib_ng

build_ffi() {
  $CURL https://github.com/libffi/libffi/releases/download/v${VERSION_FFI}/libffi-${VERSION_FFI}.tar.gz | tar xz --strip-components=1
  ./configure ${CHOST:+--host=$CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-builddir --disable-multi-os-directory --disable-raw-api --disable-structs --disable-docs
  make install-strip
}
step ffi build_ffi

# Stub gettext, as Windows does not provide libintl (as upstream does for macOS and musl)
build_proxy_libintl() {
  $CURL https://github.com/frida/proxy-libintl/archive/${VERSION_PROXY_LIBINTL}.tar.gz | tar xz --strip-components=1
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON}
  meson_install --tags devel
}
if [ "$WIN" = true ]; then
  step proxy-libintl build_proxy_libintl
fi

build_glib() {
  $CURL https://download.gnome.org/sources/glib/$(without_patch $VERSION_GLIB)/glib-${VERSION_GLIB}.tar.xz | tar xJ --strip-components=1
  $CURL https://gist.github.com/kleisauke/284d685efa00908da99ea6afbaaf39ae/raw/bdad5489a61c217850631571caf57f5db6ea8b2c/glib-without-gregex.patch | patch -p1
  meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} --datadir=${TARGET}/share ${MESON} \
    --force-fallback-for=gvdb -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled -Dsysprof=disabled -Dlibelf=disabled \
    -Dtests=false -Dglib_assert=false -Dglib_checks=false -Dglib_debug=disabled
  # bin-devel is needed for glib-mkenums
  meson_install --tags bin-devel,devel
}
step glib build_glib

build_exif() {
  $CURL https://github.com/libexif/libexif/releases/download/v${VERSION_EXIF}/libexif-${VERSION_EXIF}.tar.xz | tar xJ --strip-components=1
  ./configure ${CHOST:+--host=$CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-nls --disable-docs --without-libiconv-prefix --without-libintl-prefix \
    CPPFLAGS="${CPPFLAGS} -DNO_VERBOSE_TAG_DATA"
  make install-strip doc_DATA=
}
step exif build_exif

build_lcms() {
  $CURL https://github.com/mm2/Little-CMS/releases/download/lcms${VERSION_LCMS}/lcms2-${VERSION_LCMS}.tar.gz | tar xz --strip-components=1
  CFLAGS="${CFLAGS} -O3" meson setup _build --default-library=static --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Dtests=disabled
  meson_install --tags devel
}
step lcms build_lcms

build_aom() {
  $CURL https://storage.googleapis.com/aom-releases/libaom-${VERSION_AOM}.tar.gz | tar xz --strip-components=1
  mkdir aom_build
  cd aom_build
  AOM_AS_FLAGS="${FLAGS}" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=FALSE -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DENABLE_TESTDATA=0 -DENABLE_TOOLS=0 -DENABLE_APPS=0 -DENABLE_EXAMPLES=0 \
    -DCONFIG_PIC=1 -DENABLE_NASM=1 -DENABLE_RVV=0 \
    -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_WEBM_IO=0 -DCONFIG_AV1_ENCODER=0 \
    ..
  make install/strip
}
# AV1 decoder only
step aom build_aom

# HEVC decoder for HEIC images (not part of upstream sharp-libvips)
build_de265() {
  $CURL https://github.com/strukturag/libde265/releases/download/v${VERSION_DE265}/libde265-${VERSION_DE265}.tar.gz | tar xz --strip-components=1
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DENABLE_SDL=OFF -DENABLE_DECODER=OFF -DENABLE_ENCODER=OFF -DENABLE_SHERLOCK265=OFF
  make install/strip
}
step de265 build_de265

build_heif() {
  $CURL https://github.com/strukturag/libheif/releases/download/v${VERSION_HEIF}/libheif-${VERSION_HEIF}.tar.gz | tar xz --strip-components=1
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_DOCUMENTATION=0 -DBUILD_TESTING=0 -DENABLE_PLUGIN_LOADING=0 -DWITH_EXAMPLES=0 \
    -DWITH_LIBDE265=1 -DWITH_LIBDE265_PLUGIN=0 -DWITH_X265=0 -DWITH_AOM_ENCODER=0 -DWITH_X264=0 -DWITH_OpenH264_DECODER=0
  # Ensure the HEVC decoder was found
  grep -qE '^WITH_LIBDE265:BOOL=(1|ON)' CMakeCache.txt
  grep -qF 'libde265' libheif.pc || (echo "libheif was not configured with libde265" && exit 1)
  make install/strip
}
step heif build_heif

build_jpeg() {
  $CURL https://github.com/mozilla/mozjpeg/archive/${VERSION_MOZJPEG}.tar.gz | tar xz --strip-components=1
  # [PATCH] fix: use saturating arithmetic in SIMD FDCT to prevent overflow
  $CURL https://github.com/mozilla/mozjpeg/commit/f90668e0e4fb79c81e1f24a0ccc0e2090af761bf.patch | patch -p1
  # Use libjpeg-turbo behaviour by default
  sed -i'.bak' 's/JCP_MAX_COMPRESSION/JCP_FASTEST/' jcapimin.c
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR:PATH=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=FALSE -DWITH_JPEG8=1 -DWITH_TURBOJPEG=FALSE -DPNG_SUPPORTED=FALSE
  make install/strip
}
step jpeg build_jpeg

build_png() {
  $CURL https://github.com/pnggroup/libpng/archive/v${VERSION_PNG}.tar.gz | tar xz --strip-components=1
  ./configure ${CHOST:+--host=$CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --disable-tools --without-binconfigs --disable-unversioned-libpng-config
  make install-strip dist_man_MANS=
}
step png build_png

build_webp() {
  $CURL https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${VERSION_WEBP}.tar.gz | tar xz --strip-components=1
  ./configure ${CHOST:+--host=$CHOST} --prefix=${TARGET} --enable-static --disable-shared --disable-dependency-tracking \
    --enable-libwebpmux --enable-libwebpdemux
  make install-strip bin_PROGRAMS= noinst_PROGRAMS= man_MANS=
}
step webp build_webp

build_tiff() {
  $CURL https://gitlab.com/libtiff/libtiff/-/archive/v${VERSION_TIFF}/libtiff-v${VERSION_TIFF}.tar.gz | tar xz --strip-components=1
  cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=FALSE -DCMath_HAVE_LIBC_POW=1 \
    -Dtiff-contrib=OFF -Dtiff-cxx=OFF -Dtiff-docs=OFF -Dtiff-tests=OFF -Dtiff-tools=OFF -Dmdi=OFF \
    -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dlzma=OFF -Dold-jpeg=OFF -Dpixarlog=OFF -Dtiff-opengl=OFF -Dzstd=OFF
  make install/strip
}
step tiff build_tiff

build_highway() {
  $CURL https://github.com/google/highway/archive/${VERSION_HIGHWAY}.tar.gz | tar xz --strip-components=1
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" cmake -G"Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_INSTALL_PREFIX=${TARGET} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=FALSE -DBUILD_TESTING=0 -DHWY_ENABLE_CONTRIB=0 -DHWY_ENABLE_EXAMPLES=0 -DHWY_ENABLE_TESTS=0
  make install/strip
}
step highway build_highway

# Required by libvips itself
build_expat() {
  $CURL https://github.com/libexpat/libexpat/releases/download/R_${VERSION_EXPAT//./_}/expat-${VERSION_EXPAT}.tar.xz | tar xJ --strip-components=1
  ./configure ${CHOST:+--host=$CHOST} --prefix=${TARGET} --enable-static --disable-shared \
    --disable-dependency-tracking --without-xmlwf --without-docbook --without-getrandom --without-sys-getrandom \
    --without-libbsd --without-examples --without-tests
  make install-strip dist_cmake_DATA= nodist_cmake_DATA=
}
step expat build_expat

build_vips() {
  $CURL https://github.com/libvips/libvips/releases/download/v${VERSION_VIPS}/vips-$(without_prerelease $VERSION_VIPS).tar.xz | tar xJ --strip-components=1
  if [ "$LINUX" = true ]; then
    # Use version number in SONAME
    $CURL https://gist.githubusercontent.com/lovell/313a6901e9db1bf285f2a1f1180499e4/raw/3988223c7dfa4d22745d9392034b0117abef1446/libvips-cpp-soversion.patch | patch -p1
    # Link libvips.so statically into libvips-cpp.so
    sed -i'.bak' "s/library('vips'/static_&/" libvips/meson.build
    sed -i'.bak' "/version: library_version/{N;d;}" libvips/meson.build
    # Ensure libvips-cpp.so is linked with -z nodelete
    sed -i'.bak' "/gnu_symbol_visibility: 'hidden',/a link_args: nodelete_link_args," cplusplus/meson.build
    # Ensure symbols from external libs (except for libglib-2.0.a and libgobject-2.0.a) are not exposed
    EXCLUDE_LIBS=$(find ${TARGET}/lib -maxdepth 1 -name '*.a' ! -name 'libglib-2.0.a' ! -name 'libgobject-2.0.a' -printf "-Wl,--exclude-libs=%f ")
    EXCLUDE_LIBS=${EXCLUDE_LIBS%?}
    # Localize the g_param_spec_types symbol to avoid collisions with shared libraries
    # See: https://github.com/lovell/sharp/issues/2535#issuecomment-766400693
    printf "{local:g_param_spec_types;};" > vips.map
    VIPS_LIBRARY="--default-library=shared"
    VIPS_LINK_ARGS="-Dcpp_link_args=$LDFLAGS -Wl,-Bsymbolic-functions -Wl,--version-script=${DEPS}/vips/vips.map $EXCLUDE_LIBS"
  else
    # Static libvips and libvips-cpp, linked into sharp.node
    VIPS_LIBRARY="--default-library=static"
    VIPS_LINK_ARGS=""
  fi
  # Disable building man pages, gettext po files, tools, and (fuzz-)tests
  sed -i'.bak' "/subdir('man')/{N;N;N;N;d;}" meson.build
  CFLAGS="${CFLAGS} -O3" CXXFLAGS="${CXXFLAGS} -O3" meson setup _build ${VIPS_LIBRARY} --buildtype=release --strip --prefix=${TARGET} ${MESON} \
    -Ddeprecated=false -Dexamples=false -Dauto_features=enabled -Dintrospection=disabled -Dmodules=disabled -Dcfitsio=disabled -Dfftw=disabled \
    -Djpeg-xl=disabled -Dorc=disabled -Dmagick=disabled -Dmatio=disabled -Dnifti=disabled -Dopenexr=disabled \
    -Dopenjpeg=disabled -Dopenslide=disabled -Dpdfium=disabled -Dpoppler=disabled -Dquantizr=disabled -Draw=disabled -Dspng=disabled \
    -Dppm=false -Danalyze=false -Dradiance=false \
    -Darchive=disabled -Dcgif=disabled -Dfontconfig=disabled -Dimagequant=disabled -Dpangocairo=disabled -Drsvg=disabled \
    -Duhdr=disabled -Dnsgif=false \
    ${VIPS_LINK_ARGS:+"$VIPS_LINK_ARGS"}
  meson_install --tags runtime,devel
}
step vips build_vips

# Package

rm -rf ${OUTPUT_DIR}
mkdir -p ${OUTPUT_DIR}

if [ "$WIN" = true ]; then
  cd ${TARGET}/lib
  # Check that the HEVC decoder is linked in
  strings libheif.a | grep -qF "libde265 HEVC" || (echo "libheif.a does not contain libde265" && exit 1)
  # Static libraries and pkg-config files (relocatable via pkgconf --define-prefix), used by build-sharp-win32.sh
  cp -r ${TARGET}/include ${OUTPUT_DIR}/
  mkdir ${OUTPUT_DIR}/lib
  cp -r ${TARGET}/lib/*.a ${TARGET}/lib/pkgconfig ${TARGET}/lib/glib-2.0 ${OUTPUT_DIR}/lib/
fi

if [ "$LINUX" = true ]; then
rm -rf ${TARGET}/lib-filtered
mkdir ${TARGET}/lib-filtered
cp -r ${TARGET}/lib/glib-2.0 ${TARGET}/lib-filtered

# Pack only the relevant libraries
copydeps() {
  local base=$1
  local dest_dir=$2

  cp -L $base $dest_dir/$base
  chmod 644 $dest_dir/$base

  local dependencies=$(readelf -d $base | grep NEEDED | awk '{ print $5 }' | tr -d '[]')

  for dep in $dependencies; do
    base_dep=$(basename $dep)

    [ ! -f "$PWD/$base_dep" ] && echo "$base_dep does not exist in $PWD" && continue
    echo "$base depends on $base_dep"

    if [ ! -f "$dest_dir/$base_dep" ]; then
      # Call this function (recursive) on each dependency of this library
      copydeps $base_dep $dest_dir
    fi
  done;
}

cd ${TARGET}/lib
# Check that we really linked with -z nodelete
readelf -Wd ${VIPS_CPP_DEP} | grep -qF NODELETE || (echo "$VIPS_CPP_DEP was not linked with -z nodelete" && exit 1)
# Check that we really use the "new" C++11 ABI
readelf -Ws ${VIPS_CPP_DEP} | c++filt | grep -qF "::__cxx11::" || (echo "$VIPS_CPP_DEP mistakenly uses the C++03 ABI" && exit 1)
# Check that the HEVC decoder is linked in
strings ${VIPS_CPP_DEP} | grep -qF "libde265 HEVC" || (echo "$VIPS_CPP_DEP does not contain libde265" && exit 1)
copydeps ${VIPS_CPP_DEP} ${TARGET}/lib-filtered

cp -r ${TARGET}/include ${OUTPUT_DIR}/
cp -r ${TARGET}/lib-filtered ${OUTPUT_DIR}/lib
fi

# Create JSON file of version numbers
printf "{\n\
  \"aom\": \"${VERSION_AOM}\",\n\
  \"de265\": \"${VERSION_DE265}\",\n\
  \"exif\": \"${VERSION_EXIF}\",\n\
  \"expat\": \"${VERSION_EXPAT}\",\n\
  \"ffi\": \"${VERSION_FFI}\",\n\
  \"glib\": \"${VERSION_GLIB}\",\n\
  \"heif\": \"${VERSION_HEIF}\",\n\
  \"highway\": \"${VERSION_HIGHWAY}\",\n\
  \"lcms\": \"${VERSION_LCMS}\",\n\
  \"mozjpeg\": \"${VERSION_MOZJPEG}\",\n\
  \"png\": \"${VERSION_PNG}\",\n\
${WIN:+  \"proxy-libintl\": \"${VERSION_PROXY_LIBINTL}\",\n\
}  \"tiff\": \"${VERSION_TIFF}\",\n\
  \"vips\": \"${VERSION_VIPS}\",\n\
  \"webp\": \"${VERSION_WEBP}\",\n\
  \"zlib-ng\": \"${VERSION_ZLIB_NG}\"\n\
}" >${OUTPUT_DIR}/versions.json

# Add third-party notices, including libde265
cp ${SCRIPT_DIR}/THIRD-PARTY-NOTICES.md ${OUTPUT_DIR}/

ls -al ${OUTPUT_DIR}/lib
echo "Built libvips ${VERSION_VIPS} for ${PLATFORM} with HEVC decoding support in ${OUTPUT_DIR}"

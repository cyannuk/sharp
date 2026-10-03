#!/usr/bin/env bash
set -e

# Cross-compile sharp.node for win32-x64 with llvm-mingw, statically linked with the libvips
# built by `PLATFORM=win32-x64 build.sh`, so the result is a single self-contained DLL
# that only depends on Windows system libraries and on node.exe (via Node-API).
#
# Usage: scripts/libvips-heic/build-sharp-win32.sh
#
# Environment variables:
# - JOBS: number of parallel compile jobs (default: 2)
# - LLVM_MINGW: llvm-mingw toolchain directory (default: ~/.local/llvm-mingw)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CHOST=x86_64-w64-mingw32
LLVM_MINGW=${LLVM_MINGW:-$HOME/.local/llvm-mingw}
export PATH="${LLVM_MINGW}/bin:${PATH}"
JOBS=${JOBS:-2}

LIBVIPS_DIR=${REPO_DIR}/vendor/sharp-libvips-win32-x64
BUILD_DIR=${REPO_DIR}/src/build/win32-x64
OUTPUT_DIR=${REPO_DIR}/src/build/Release

SHARP_VERSION=$(node -p "require('${REPO_DIR}/package.json').version")
NODE_VERSION=$(node -p "process.versions.node")
OUTPUT=${OUTPUT_DIR}/sharp-win32-x64-${SHARP_VERSION}.node

if ! [ -f "${LIBVIPS_DIR}/lib/pkgconfig/vips-cpp.pc" ]; then
  echo "libvips for win32-x64 not found, run: PLATFORM=win32-x64 scripts/libvips-heic/build.sh"
  exit 1
fi

mkdir -p ${BUILD_DIR} ${OUTPUT_DIR}

# Node-API headers and the import library of node.exe, as node-gyp uses on Windows.
# Node-API is ABI-stable, so these work with any Node.js version supported by package.json engines
NODE_DIR=${BUILD_DIR}/node-${NODE_VERSION}
if ! [ -f "${NODE_DIR}/node.lib" ]; then
  mkdir -p ${NODE_DIR}
  curl --silent --show-error --fail --location https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-headers.tar.gz \
    | tar xz -C ${NODE_DIR} --strip-components=1
  curl --silent --show-error --fail --location -o ${NODE_DIR}/node.lib https://nodejs.org/dist/v${NODE_VERSION}/win-x64/node.lib
fi

PKG_CONFIG="pkgconf --static --define-prefix"
export PKG_CONFIG_LIBDIR=${LIBVIPS_DIR}/lib/pkgconfig
unset PKG_CONFIG_PATH

# Equivalent of the defines and flags of src/binding.gyp
CXXFLAGS="-std=c++17 -fexceptions -Wall -Os -march=nehalem -ffunction-sections -fdata-sections \
  -DG_DISABLE_ASSERT -DG_DISABLE_CAST_CHECKS -DG_DISABLE_CHECKS \
  -DNAPI_VERSION=9 -DNODE_ADDON_API_DISABLE_DEPRECATED -DNODE_API_SWALLOW_UNTHROWABLE_EXCEPTIONS \
  -DBUILDING_NODE_EXTENSION -DNAPI_EXTERN=__declspec(dllimport) \
  -I${NODE_DIR}/include/node -I$(node -p "require('node-addon-api').include_dir" | sed "s|^|${REPO_DIR}/|") \
  $(${PKG_CONFIG} --cflags vips-cpp)"

# Compile
SOURCES="common metadata stats operations pipeline utilities sharp"
for src in ${SOURCES}; do
  echo "${CHOST}-clang++ -c src/${src}.cc"
  ${CHOST}-clang++ ${CXXFLAGS} -c ${REPO_DIR}/src/${src}.cc -o ${BUILD_DIR}/${src}.o &
  while [ "$(jobs -rp | wc -l)" -ge "${JOBS}" ]; do wait -n; done
done
for job in $(jobs -p); do wait ${job}; done

# Link, including the C++ runtime (libc++, libunwind) and winpthreads statically
echo "Linking ${OUTPUT}"
${CHOST}-clang++ -shared -static -s -Wl,--gc-sections -o ${OUTPUT} \
  $(for src in ${SOURCES}; do echo ${BUILD_DIR}/${src}.o; done) \
  $(${PKG_CONFIG} --libs vips-cpp) \
  ${NODE_DIR}/node.lib

# Check that the only non-system dependency is node.exe
IMPORTS=$(${CHOST}-objdump -p ${OUTPUT} | awk '/DLL Name:/ { print $3 }' | sort -u)
echo "Imports:" ${IMPORTS}
for dll in ${IMPORTS}; do
  case "${dll,,}" in
    node.exe|kernel32.dll|advapi32.dll|user32.dll|shell32.dll|ole32.dll|ws2_32.dll|shlwapi.dll|dnsapi.dll|iphlpapi.dll|bcrypt.dll|userenv.dll|api-ms-win-crt-*.dll|api-ms-win-core-*.dll) ;;
    *) echo "Unexpected dependency on ${dll}" && exit 1 ;;
  esac
done
${CHOST}-objdump -p ${OUTPUT} | grep -qF "napi_register_module_v1" || (echo "napi_register_module_v1 is not exported" && exit 1)

ls -l ${OUTPUT}

# Copyright 2013 Lovell Fuller and others.
# SPDX-License-Identifier: Apache-2.0

{ # noqa: B018
  'variables': {
    'vips_version': '<!(node -p "require(\'../dist/libvips.cjs\').minimumLibvipsVersion")',
    'platform_and_arch': '<!(node -p "require(\'../dist/libvips.cjs\').buildPlatformArch()")',
    'sharp_version': '<!(node -p "require(\'../package.json\').version")',
    'sharp_libvips_version': '<!(node -p "require(\'../package.json\').optionalDependencies?.[\'@img/sharp-libvips-<(platform_and_arch)\'] || \'\'")',
    'sharp_libvips_yarn_locator': '<!(node -p "require(\'../dist/libvips.cjs\').yarnLocator()")',
    'sharp_libvips_include_dir': '<!(node -p "require(\'../dist/libvips.cjs\').buildSharpLibvipsIncludeDir()")',
    'sharp_libvips_lib_dir': '<!(node -p "require(\'../dist/libvips.cjs\').buildSharpLibvipsLibDir()")'
  },
  'targets': [{
    'target_name': 'sharp-<(platform_and_arch)-<(sharp_version)',
    'defines': [
      'G_DISABLE_ASSERT',
      'G_DISABLE_CAST_CHECKS',
      'G_DISABLE_CHECKS',
      'NAPI_VERSION=9',
      'NODE_ADDON_API_DISABLE_DEPRECATED',
      'NODE_API_SWALLOW_UNTHROWABLE_EXCEPTIONS'
    ],
    'dependencies': [
      '<!(node -p "require(\'node-addon-api\').gyp")'
    ],
    'variables': {
      'pkg_config_path': '<!(node -p "require(\'../dist/libvips.cjs\').pkgConfigPath()")',
      'use_global_libvips': '<!(node -p "Boolean(require(\'../dist/libvips.cjs\').useGlobalLibvips()).toString()")'
    },
    'sources': [
      'common.cc',
      'metadata.cc',
      'stats.cc',
      'operations.cc',
      'pipeline.cc',
      'utilities.cc',
      'sharp.cc'
    ],
    'include_dirs': [
      '<!(node -p "require(\'node-addon-api\').include_dir")',
    ],
    'conditions': [
      ['use_global_libvips == "true"', {
        # Use pkg-config for include and lib
        'include_dirs': ['<!@(PKG_CONFIG_PATH="<(pkg_config_path)" pkg-config --cflags-only-I vips-cpp vips glib-2.0 | sed s/-I//g)'],
        'libraries': ['<!@(PKG_CONFIG_PATH="<(pkg_config_path)" pkg-config --libs vips-cpp)'],
        'defines': [
          'SHARP_USE_GLOBAL_LIBVIPS'
        ],
        'conditions': [
          ['OS == "linux"', {
            'defines': [
              # Inspect libvips-cpp.so to determine which C++11 ABI version was used and set _GLIBCXX_USE_CXX11_ABI accordingly. This is quite horrible.
              '_GLIBCXX_USE_CXX11_ABI=<!(if readelf -Ws "$(PKG_CONFIG_PATH="<(pkg_config_path)" pkg-config --variable libdir vips-cpp)/libvips-cpp.so" | c++filt | grep -qF __cxx11;then echo "1";else echo "0";fi)'
            ]
          }]
        ]
      }, {
        # Use pre-built libvips stored locally within node_modules
        'include_dirs': [
          '<(sharp_libvips_include_dir)',
          '<(sharp_libvips_include_dir)/glib-2.0',
          '<(sharp_libvips_lib_dir)/glib-2.0/include'
        ],
        'library_dirs': [
          '<(sharp_libvips_lib_dir)'
        ],
        'conditions': [
          ['OS == "mac"', {
            'link_settings': {
              'libraries': [
                'libvips-cpp.<(vips_version).dylib'
              ]
            },
            'xcode_settings': {
              'OTHER_LDFLAGS': [
                '-Wl,-s',
                '-Wl,-dead_strip',
                # Ensure runtime linking is relative to sharp.node
                '-Wl,-rpath,\'@loader_path/../../sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath,\'@loader_path/../../../sharp-libvips-<(platform_and_arch)/<(sharp_libvips_version)/lib\'',
                '-Wl,-rpath,\'@loader_path/../node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath,\'@loader_path/../../node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath,\'@loader_path/../../../node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath,\'@loader_path/../../../../../@img-sharp-libvips-<(platform_and_arch)-npm-<(sharp_libvips_version)-<(sharp_libvips_yarn_locator)/node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\''
              ]
            }
          }],
          ['OS == "linux"', {
            'defines': [
              '_GLIBCXX_USE_CXX11_ABI=1'
            ],
            'cflags_cc': [
              '<!(node -p "require(\'detect-libc\').isNonGlibcLinuxSync() ? \'\' : \'-flto=auto\'")'
            ],
            'link_settings': {
              'libraries': [
                '-l:libvips-cpp.so.<(vips_version)'
              ],
              'ldflags': [
                '-lstdc++fs',
                '-Wl,-s',
                '-Wl,--disable-new-dtags',
                '-Wl,-z,nodelete',
                '-Wl,-Bsymbolic-functions',
                # Locally-built libvips with HEIC/HEVC support takes precedence, see scripts/libvips-heic/build.sh
                '-Wl,-rpath=\'$$ORIGIN/../../../vendor/sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath=\'$$ORIGIN/../../sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath=\'$$ORIGIN/../../../sharp-libvips-<(platform_and_arch)/<(sharp_libvips_version)/lib\'',
                '-Wl,-rpath=\'$$ORIGIN/../../node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath=\'$$ORIGIN/../../../node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\'',
                '-Wl,-rpath,\'$$ORIGIN/../../../../../@img-sharp-libvips-<(platform_and_arch)-npm-<(sharp_libvips_version)-<(sharp_libvips_yarn_locator)/node_modules/@img/sharp-libvips-<(platform_and_arch)/lib\''
              ]
            }
          }]
        ]
      }]
    ],
    'cflags_cc': [
      '-std=c++17',
      '-fexceptions',
      '-Wall',
      '-Os'
    ],
    'xcode_settings': {
      'CLANG_CXX_LANGUAGE_STANDARD': 'c++17',
      'MACOSX_DEPLOYMENT_TARGET': '10.15',
      'GCC_ENABLE_CPP_EXCEPTIONS': 'YES',
      'GCC_ENABLE_CPP_RTTI': 'YES',
      'OTHER_CPLUSPLUSFLAGS': [
        '-fexceptions',
        '-Wall',
        '-Oz'
      ]
    },
    'configurations': {
      'Release': {
        'conditions': [
          ['target_arch == "arm"', {
            'cflags_cc': [
              '-Wno-psabi'
            ]
          }]
        ]
      }
    },
  }]
}

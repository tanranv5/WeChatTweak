#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
clang -arch arm64 -arch x86_64 -std=c11 -O2 -Wall -Wextra -Werror \
    -dynamiclib -mmacosx-version-min=12.0 -Wl,-no_fixup_chains \
    -Wl,-undefined,dynamic_lookup \
    -install_name "@executable_path/../Resources/libwxhotpatchguard.dylib" \
    wxhotpatchguard.c -o build/libwxhotpatchguard.dylib
codesign --force --sign - build/libwxhotpatchguard.dylib
lipo -info build/libwxhotpatchguard.dylib

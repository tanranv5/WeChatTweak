#!/bin/bash
# 编译 wxrevoketip.mm → build/libwxrevoketip.dylib（仅 x86_64）
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

SRC="wxrevoketip.mm"
OUT="build/libwxrevoketip.dylib"

clang++ -arch x86_64 -std=c++17 -O2 -dynamiclib \
    -mmacosx-version-min=11.0 \
    -install_name "@executable_path/../Resources/libwxrevoketip.dylib" \
    -Wl,-no_fixup_chains \
    -o "$OUT" "$SRC" \

echo "== built =="
lipo -info "$OUT"
nm -gU "$OUT" | head -5 || true
echo
echo "用法（见 run.sh）："
echo "  DYLD_INSERT_LIBRARIES=$(pwd)/$OUT [WXRT_APPLY=1] /Applications/wx.app/Contents/MacOS/WeChat"

#!/bin/bash
# 用 Xcode 自带的自洽工具链编译（CLT 的 swiftc 6.2.3 与 CLT SDK 26.2 不匹配，会报
# "this SDK is not supported by the compiler"）。module cache 必须放到可写目录。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV=/Applications/Xcode.app/Contents/Developer
SWIFTC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk"
ATLAS="${ATLAS:-$HERE/../spritesheet.png}"
OUT="${1:-$HERE/SpoutWhale.app}"

[ -x "$SWIFTC" ] || { echo "找不到 Xcode swiftc: $SWIFTC"; exit 1; }
[ -f "$ATLAS" ]  || { echo "找不到图集: $ATLAS"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$HERE/Info.plist" "$OUT/Contents/Info.plist"
cp "$ATLAS" "$OUT/Contents/Resources/spritesheet.png"

"$SWIFTC" -O -sdk "$SDK" -module-cache-path /tmp/swift-mc -swift-version 5 \
  -target x86_64-apple-macosx15.0 -framework AppKit \
  -o "$OUT/Contents/MacOS/SpoutWhale" "$HERE"/*.swift

codesign --force --sign - "$OUT" >/dev/null 2>&1 && echo "ad-hoc 签名 OK" || echo "签名跳过（不影响本机运行）"
echo "built: $OUT"

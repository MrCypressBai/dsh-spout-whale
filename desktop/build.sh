#!/bin/bash
# 用 Xcode 自带的自洽工具链编译（CLT 的 swiftc 6.2.3 与 CLT SDK 26.2 不匹配，会报
# "this SDK is not supported by the compiler"）。module cache 必须放到可写目录。
#
# 默认产出 **通用二进制**（x86_64 + arm64）：Intel 上原生跑，Apple Silicon 上原生跑，
# 不用 Rosetta。任一架构编不出来时自动退回单架构，不会整个构建失败。
#   ARCHS="x86_64" sh build.sh ./SpoutWhale.app    # 只要一个架构
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV=/Applications/Xcode.app/Contents/Developer
SWIFTC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="${SDK:-$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk}"
ATLAS="${ATLAS:-$HERE/../spritesheet.png}"
OUT="${1:-$HERE/SpoutWhale.app}"
ARCHS="${ARCHS:-x86_64 arm64}"
MIN=15.0

[ -x "$SWIFTC" ] || { echo "找不到 Xcode swiftc: $SWIFTC"; exit 1; }
[ -f "$ATLAS" ]  || { echo "找不到图集: $ATLAS"; exit 1; }
[ -d "$SDK" ]    || { echo "找不到 SDK: $SDK"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$HERE/Info.plist" "$OUT/Contents/Info.plist"
cp "$ATLAS" "$OUT/Contents/Resources/spritesheet.png"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SLICES=()
for A in $ARCHS; do
  echo "编译 $A …"
  if "$SWIFTC" -O -sdk "$SDK" -module-cache-path "/tmp/swift-mc-$A" -swift-version 5 \
       -target "${A}-apple-macosx${MIN}" -framework AppKit \
       -o "$TMP/SpoutWhale-$A" "$HERE"/*.swift 2>"$TMP/$A.log"; then
    SLICES+=("$TMP/SpoutWhale-$A")
  else
    echo "  $A 编译失败，跳过（详情见下）"; tail -3 "$TMP/$A.log" | sed 's/^/    /'
  fi
done

[ ${#SLICES[@]} -gt 0 ] || { echo "所有架构都编译失败"; exit 1; }
if [ ${#SLICES[@]} -gt 1 ]; then
  lipo -create -output "$OUT/Contents/MacOS/SpoutWhale" "${SLICES[@]}"
else
  cp "${SLICES[0]}" "$OUT/Contents/MacOS/SpoutWhale"
fi

codesign --force --sign - "$OUT" >/dev/null 2>&1 && echo "ad-hoc 签名 OK" || echo "签名跳过（不影响本机运行）"
echo "built: $OUT  [$(lipo -info "$OUT/Contents/MacOS/SpoutWhale" | sed 's/.*are: //')]"

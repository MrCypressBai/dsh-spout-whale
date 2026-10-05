#!/bin/sh
# SpoutWhale 安装脚本：把 App 装到 ~/Applications（或指定目录），可选注册开机自启。
#   sh scripts/install.sh                  # 装到 ~/Applications
#   sh scripts/install.sh /Applications    # 装到系统 Applications（可能需要 sudo）
#   sh scripts/install.sh ~/Applications --autostart
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
# App 可能来自仓库根目录（desktop/build.sh 的默认输出）或 build/ 子目录
APP_SRC="${APP_SRC:-$HERE/../SpoutWhale.app}"
[ -d "$APP_SRC" ] || APP_SRC="$HERE/../build/SpoutWhale.app"
DEST_DIR="${1:-$HOME/Applications}"
DEST="$DEST_DIR/SpoutWhale.app"

if [ ! -d "$APP_SRC" ]; then
  echo "错误：找不到 SpoutWhale.app（找过 $HERE/../SpoutWhale.app）" >&2
  echo "请先构建：sh desktop/build.sh ./SpoutWhale.app" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$APP_SRC" "$DEST"

# 从网络/压缩包带来的隔离标记会让 Gatekeeper 拦一下；本地构建其实没有，清掉无副作用
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# ad-hoc 重签一次，确保 cp 之后签名与新路径仍然自洽
codesign --force --sign - "$DEST" >/dev/null 2>&1 || true

echo "已安装: $DEST"
echo "启动:   open \"$DEST\""

if [ "$2" = "--autostart" ]; then
  PL="$HOME/Library/LaunchAgents/ai.micheng.spoutwhale.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed "s|__APP__|$DEST|g" "$HERE/ai.micheng.spoutwhale.plist" > "$PL"
  launchctl unload "$PL" 2>/dev/null || true
  launchctl load "$PL"
  echo "已注册开机自启: $PL"
  echo "取消自启:      launchctl unload \"$PL\" && rm \"$PL\""
fi

#!/bin/sh
# 喷水鲸鱼桌宠 · 控制脚本
#
#   sh spoutwhale-ctl.sh           # 没跑就打开，已在跑就报告（默认）
#   sh spoutwhale-ctl.sh start     # 同上
#   sh spoutwhale-ctl.sh stop      # 关掉
#   sh spoutwhale-ctl.sh restart   # 重启
#   sh spoutwhale-ctl.sh status    # 查状态
#
# 自动找 App：先 $HOME/Applications，再仓库内构建出来的 ./SpoutWhale.app。
HERE="$(cd "$(dirname "$0")" && pwd)"
APP=""
for c in "$HOME/Applications/SpoutWhale.app" \
         "$HERE/../SpoutWhale.app" \
         "$HERE/../build/SpoutWhale.app"; do
    [ -d "$c" ] && APP="$c" && break
done
[ -z "$APP" ] && { echo "找不到 SpoutWhale.app，请先运行 scripts/install.sh 或 desktop/build.sh"; exit 1; }

# 注意：用 `open SpoutWhale.app`（相对路径）启动时，进程 argv 是**相对路径**；
# 从 Finder 双击时是绝对路径。所以只匹配 .app 之后的固定后缀，两种都能命中。
PAT='SpoutWhale[.]app/Contents/MacOS/SpoutWhale'
running() { pgrep -f "$PAT" >/dev/null 2>&1; }
pid_of()  { pgrep -f "$PAT" | head -1; }

case "${1:-start}" in
    start)
        if running; then
            echo "已在运行（pid $(pid_of)）—— 没有重复启动。$APP"
        else
            open "$APP"
            sleep 1
            if running; then echo "已启动（pid $(pid_of)）$APP"
            else echo "启动失败：请手动打开 $APP"; exit 1; fi
        fi
        ;;
    stop)
        if running; then pkill -f "$PAT"; echo "已关闭"; else echo "本来就没跑"; fi
        ;;
    restart)
        running && pkill -f "$PAT" && sleep 1
        open "$APP"; sleep 1
        running && echo "已重启（pid $(pid_of)）" || { echo "重启失败"; exit 1; }
        ;;
    status)
        if running; then echo "运行中 pid $(pid_of)"; else echo "未运行"; fi
        echo "App: $APP"
        ;;
    *) echo "用法: sh spoutwhale-ctl.sh [start|stop|restart|status]"; exit 2 ;;
esac

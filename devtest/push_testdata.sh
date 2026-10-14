#!/usr/bin/env bash
# 把 testdata/ 里的测试卡组推到模拟器的「文件管理 > 我的手机 > Documents」,
# 在 App 里点导入就能直接选到,不用每次自己找文件。
#
# 用法(WSL):  bash devtest/push_testdata.sh [设备]     默认设备 127.0.0.1:5555(模拟器)
# 模拟器重置 / 换新模拟器之后再跑一次即可。
# 测试数据本身由 devtest/merge_math1000.py 从 PKB 生成。
set -euo pipefail

HDC="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
TARGET="${1:-127.0.0.1:5555}"
# 只能直接放进 Documents:hdc shell 用户没有在这里 mkdir 的权限,
# 但 hdc file send 可以写文件
DEST="/storage/media/100/local/files/Docs/Documents"
SRC="$(cd "$(dirname "$0")/.." && pwd)/testdata"

# 每条 hdc 命令都带超时:设备没响应时宁可报错,也不要无限挂住
timeout 10 "$HDC" list targets | tr -d '\r' | grep -qx "$TARGET" || { echo "设备 $TARGET 不在线"; exit 1; }
for f in "$SRC"/*.md "$SRC"/*.yml; do
  timeout 60 "$HDC" -t "$TARGET" file send "$(wslpath -w "$f")" "$DEST/$(basename "$f")"
done
timeout 10 "$HDC" -t "$TARGET" shell "ls -la $DEST"

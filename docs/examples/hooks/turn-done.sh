#!/bin/sh
# FlyTerm — Claude Code Stop hook：本轮耗时超阈值才通知。
#
# 为什么要门槛：Stop 是 once per turn，不是「整个任务完成」。连续对话十轮
# 就是十条通知，还会把服务端 50 条的事件队列冲爆。
#
# 为什么每条路径都必须 exit 0：Stop hook 的 exit 2 会**阻止 Claude 停止**
# 并让它继续对话；其它非零码会在 transcript 里留错误行。

input=$(cat)

sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$sid" ] || sid=default

f="${TMPDIR:-/tmp}/flyterm-hooks/$sid"
start=$(cat "$f" 2>/dev/null)
rm -f "$f" 2>/dev/null

# 空值或非数字直接退出：未加保护的 $(( )) 会让脚本以非零码退出。
case "$start" in
  ''|*[!0-9]*) exit 0 ;;
esac

elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -ge "${FLYTERM_NOTIFY_MIN_SECONDS:-60}" ] || exit 0

"${FLYTERM_BIN:-$HOME/.flyterm-server/bin/flyterm}" notify "Claude Code 完成（${elapsed}s）" 2>/dev/null

exit 0

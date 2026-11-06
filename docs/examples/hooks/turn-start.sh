#!/bin/sh
# FlyTerm — Claude Code UserPromptSubmit hook：记录本轮开始时间。
#
# 与 turn-done.sh 配对使用：Stop 时算差值，只有长任务才通知。
# 部署方式见 docs/agent-notifications.md。

input=$(cat)

# 用 sed 而不是 jq —— 远端不一定装了 jq。session_id 是顶层扁平字符串，
# 正则足够；抠不到就退化成 default，不影响主流程。
sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$sid" ] || sid=default

dir="${TMPDIR:-/tmp}/flyterm-hooks"
mkdir -p "$dir" 2>/dev/null
date +%s > "$dir/$sid" 2>/dev/null

exit 0

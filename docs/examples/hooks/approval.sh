#!/bin/sh
# FlyTerm — Claude Code Notification hook（matcher: permission_prompt）。
#
# agent 停下来等审批时告知一声。这只解决「知道」，不解决「应答」——收到
# 之后仍需切回终端操作。锁屏直接 allow/deny 需要另一条腿。
#
# 该事件的退出码与 stderr 被 Claude Code 忽略，本脚本不可能干扰主流程；
# 仍然显式 exit 0，避免将来被复制到别的 hook 上时踩坑。

# 必须读干净 stdin：不读的话写端可能拿到 SIGPIPE。
cat > /dev/null

"${FLYTERM_BIN:-$HOME/.flyterm-server/bin/flyterm}" notify "Claude Code 在等审批" 2>/dev/null

exit 0

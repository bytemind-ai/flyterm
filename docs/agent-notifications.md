# 任务完成通知（Claude Code / codex）

远端 agent 干完活、或者停下来等你审批时，往手机推一条锁屏通知。

**全程零第三方**：事件只在你自己的服务器和你自己的手机之间流动，不过任何
中继、不需要账号。

---

## 前提

- **必须是 QUIC 会话**（服务器上装了 `flyterm-server`）。SSH / Mosh 没有服务端
  组件，收不到通知。
- **Android**。iOS 暂不支持。
- 首次连接 QUIC 时 app 会提示安装 `flyterm-server`，同意即可；它会顺带装好
  `~/.flyterm-server/bin/flyterm` 这个命令。
- **必须打开「后台保活」**（设置 → 连接）。这个开关**默认是关的** —— 它会在
  通知栏常驻一条通知，Android 强制前台服务显示它、无法隐藏，所以不适合当
  默认行为。但关着的时候 app 切后台连接就断了，锁屏通知也就收不到。**只想
  在 app 开着的时候收提示，可以不开；要锁屏推送，必须开。**

先验证命令能用（手机上应该立刻收到一条）：

```bash
~/.flyterm-server/bin/flyterm notify "测试"
```

把它加进 PATH 会更顺手：

```bash
echo 'export PATH="$HOME/.flyterm-server/bin:$PATH"' >> ~/.bashrc
```

---

## 手动通知

任何命令链末尾都能挂：

```bash
make && flyterm notify "构建完成"
```

`flyterm notify` **永远返回 0**，不会因为通知失败污染你的命令链的退出码。

---

## Claude Code 自动通知

### 一键安装脚本

```sh
mkdir -p ~/.flyterm-server/hooks

cat > ~/.flyterm-server/hooks/turn-start.sh <<'FLYTERM_EOF'
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
FLYTERM_EOF

cat > ~/.flyterm-server/hooks/turn-done.sh <<'FLYTERM_EOF'
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
FLYTERM_EOF

cat > ~/.flyterm-server/hooks/approval.sh <<'FLYTERM_EOF'
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
FLYTERM_EOF

chmod +x ~/.flyterm-server/hooks/*.sh
```

### 注册 hook

把下面这段合并进 `~/.claude/settings.json`（已有 `hooks` 字段的话就往里加）：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "$HOME/.flyterm-server/hooks/turn-start.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$HOME/.flyterm-server/hooks/turn-done.sh" }] }
    ],
    "Notification": [
      { "matcher": "permission_prompt",
        "hooks": [{ "type": "command", "command": "$HOME/.flyterm-server/hooks/approval.sh" }] }
    ]
  }
}
```

`Stop` 和 `UserPromptSubmit` **不支持 matcher**，加了会被静默忽略。

在 Claude Code 里执行 `/hooks` 可以确认注册生效。

### 调阈值

默认只有耗时 ≥60 秒的轮次才通知。想改：

```sh
export FLYTERM_NOTIFY_MIN_SECONDS=120
```

设成 `0` 则每轮都通知。

---

## codex

codex 的 `notify` 配置项存在（`array<string>`，**只在用户级
`~/.codex/config.toml` 生效**，项目级的会被忽略），但它的触发条件和 JSON
payload 字段官方文档没有给出。

先抓一次真实 payload 再配：

```toml
# ~/.codex/config.toml
notify = ["/bin/sh", "-c", "cat >> /tmp/codex-notify.jsonl"]
```

跑一轮任务，看 `/tmp/codex-notify.jsonl` 的内容，再据此写自己的脚本。

codex 另有 `[hooks]` 机制（需开启 `features.hooks`），事件名与 Claude Code
同构（`Stop` / `PermissionRequest` 等）。

---

## 限制

这些是设计取舍，不是缺陷：

- **仅 QUIC 会话** —— SSH / Mosh 没有服务端组件
- **仅 Android** —— iOS 的锁屏推送必须走 APNs，那需要一个中继服务器，与
  「零第三方」的前提冲突
- **离线队列 50 条 / 24 小时** —— 更早的事件直接丢弃
- **多设备「谁先收到算谁的」** —— 手机和平板同时连着时只有一个会收到
- **锁屏通知需要「后台保活」开关** —— 它默认关闭。打开后通知栏会常驻一条
  通知：Android 强制前台服务显示它，无法隐藏（`IMPORTANCE_NONE` 也不行，
  importance 只影响打扰级别、不影响它在抽屉里的存在）。这是「app 不在前台
  也能收到通知」的唯一代价。关着的话，通知只在 app 前台时以应用内提示出现
- **审批只能告知，不能应答** —— 收到后仍需切回终端操作
- **点通知落到服务器而非具体 tab** —— agent 跑在 tmux 里时 tab 归属会过期，
  一律降级到服务器级

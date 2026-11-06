// SPDX-License-Identifier: GPL-3.0-or-later
/// 旧品牌（AITerm → TermIQ）时期在远端留下的两个目录，改名 FlyTerm 后要搬家。
///
/// | 旧 | 新 | 内容 |
/// |---|---|---|
/// | `~/.aiterm-server/` | `~/.flyterm-server/` | QUIC server 的 binary、state、hooks |
/// | `~/.aiterm/` | `~/.flyterm/` | **用户资产**：手写的 AGENTS.md、skills/、jobs/ |
///
/// 两个目录**不能合并**成一个：`~/.aiterm-server/` 是程序装进去的，丢了可以
/// 重新上传；`~/.aiterm/` 里是用户自己在那台服务器上写的东西，丢了拿不回来。
/// 所以这里用 mv 把它搬过去，而不是让它走「探测不到就当没装过」那条路 ——
/// 后者对 server binary 只是多一次 SFTP 上传，对用户的 AGENTS.md 就是静默丢失。
library;

/// 迁移用的 shell 片段，拼在任何**读这两个目录的远端命令**前面。
///
/// ## 为什么是一段 shell 而不是几次独立调用
///
/// 迁移必须发生在任何读取之前，而 QUIC 的探测命令本身就是一段复合 shell。
/// 拼在它前面等于白嫖那一次 exec 往返，不额外增加 RTT。
///
/// ## 幂等
///
/// 新目录已存在就整段跳过，重复执行只花两个 `[ -d ]` 判断。可以无脑拼在
/// 每次探测前，不需要在客户端记「这台迁移过没有」。
///
/// ## mv 一个正在运行的 daemon 为什么是安全的
///
/// mv 是同一文件系统内的 rename，inode 不变。Linux 按 inode 持有已打开的
/// 可执行文件，所以旧 daemon 继续跑、不受影响；下一次 bootstrap 会在新路径
/// 找到同一个 binary。
///
/// ## 为什么 hook 脚本要改内容而不只是搬位置
///
/// 远端 `hooks/*.sh` 里硬编码了 `${AITERM_BIN:-$HOME/.aiterm-server/bin/aiterm}`。
/// 目录搬走后这些路径全部指向不存在的位置，所以要就地改写。
///
/// 改写用 `sed > tmp && mv` 而不是 `sed -i`：后者在 BSD sed 上要求 `-i ''`，
/// 写法不跨平台。
///
/// ## 末尾那个 `:`
///
/// 吃掉前面所有判断可能留下的非零退出码。否则当两个目录都不存在（绝大多数
/// 情况）时，整段以 `[ -d ]` 的 false 结尾，会把调用方那条命令串的退出码
/// 整体带成失败。
const String kLegacyRemoteMigration =
    // ── ~/.aiterm-server/ → ~/.flyterm-server/ ──
    r'if [ -d "$HOME/.aiterm-server" ] && [ ! -e "$HOME/.flyterm-server" ]; then '
    r'mv "$HOME/.aiterm-server" "$HOME/.flyterm-server" 2>/dev/null; '
    r'B="$HOME/.flyterm-server/bin"; '
    // bin/ 下有两个名字：canonical 的 flyterm-server，和给 hook 用的短名 flyterm。
    r'[ -e "$B/aiterm-server" ] && mv "$B/aiterm-server" "$B/flyterm-server" 2>/dev/null; '
    r'[ -e "$B/aiterm" ] && mv "$B/aiterm" "$B/flyterm" 2>/dev/null; '
    // hooks 目录不存在时 glob 不展开，$f 保持字面量，被 [ -f ] 挡掉。
    r'for f in "$HOME/.flyterm-server/hooks/"*.sh; do '
    r'[ -f "$f" ] || continue; '
    // 顺序有讲究：先把目录名换掉，再处理 bin/ 下的两个 binary 名
    // （长的先行，否则 bin/aiterm 会先吃掉 bin/aiterm-server 的前缀）。
    r"sed -e 's|\.aiterm-server|.flyterm-server|g' "
    r"-e 's|bin/aiterm-server|bin/flyterm-server|g' "
    r"-e 's|bin/aiterm|bin/flyterm|g' "
    r"-e 's|AITERM_|FLYTERM_|g' "
    r'"$f" > "$f.mig" 2>/dev/null && mv "$f.mig" "$f" 2>/dev/null; '
    r'done; '
    r'fi; '
    // ── ~/.aiterm/ → ~/.flyterm/（用户资产）──
    r'if [ -d "$HOME/.aiterm" ] && [ ! -e "$HOME/.flyterm" ]; then '
    r'mv "$HOME/.aiterm" "$HOME/.flyterm" 2>/dev/null; '
    r'fi; '
    r':; ';

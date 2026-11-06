// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// FlyTerm 设计系统的唯一真相源。
///
/// ## 视觉立场：专业仪表盘
///
/// FlyTerm 是**给工程师用的终端工具**，不是消费级 App。这决定了三条取舍，
/// 也是本文件所有取值的依据：
///
/// 1. **颜色只编码状态，不做装饰。** 绿=已连接、琥珀=进行中、红=失败。
///    除编码状态外一律灰阶。一个颜色扛多种语义（品牌/选中/状态/徽标）会
///    让界面到处是彩色，反而没有重点。
/// 2. **信息密度优先于留白。** 一屏尽可能多事实。行高 52-56、左右内边距
///    12-16、字号以 13/11.5 为主。宁可密，不可疏。
/// 3. **层级靠划格与亮度差，不靠浮动卡片。** 分区用 0.5px hairline 与
///    header 标签表达，不用圆角浮起 + 阴影 —— 后者是消费级列表的做法。
///
/// ## 一次走过的弯路（别再走回去）
///
/// 这套 token 的第一版曾按「iOS 原生 App」重写过：纯黑底 + `#1C1C1E` 浮起
/// 卡片 + 系统蓝 `#0A84FF` + 全站系统字体 + 34pt 大标题。**每一条单独看都是
/// 「iOS 的」，合起来却是在宣称「我是个 iOS 消费应用」** —— 把 FlyTerm 赖以
/// 立足的工程感整个抹掉了，用户实测反馈「不是 FlyTerm 了」，随后整体回退。
///
/// 判准记在这里：**对齐参照物要看层次**。终端内容区可以对齐 iTerm2（那是
/// 同一类东西）；app 外壳对齐的应是**专业工具**（VS Code / Linear 那种密度与
/// 克制），而不是 iOS 系统设置页。同屏出现的东西可以互相参照，跨层次照搬
/// 形态则会把产品身份带跑。
///
/// ## 尺度是怎么收敛的
///
/// 改造前：字号 17 档、圆角 6 档、间距 7 档、`Color(0x..)` 77 处散在 20 个
/// 文件、`#00C896` 手写 37 次。意图本身是好的（hairline、mono 微标签、mint
/// 点缀都是刻意选的），缺的是**落点** —— 每加一页都要重新「记得」一遍。
///
/// 本文件把那套意图固化成可引用的常量。**新增 UI 一律引用这里，不再手写
/// 数值**；要调整时改这里一处。

// ─────────────────────────────────────────────────────────────
// 颜色
// ─────────────────────────────────────────────────────────────

/// 暗色仪表盘色板。
///
/// 只提供暗色 —— 产品当前 `brightness` 写死 dark，一次做两套会让每处引用
/// 都要多回答一个「亮色时是什么」，在只有一套皮肤时是纯负债。将来要加亮色，
/// 按这里的语义名逐一给值即可。
abstract final class FlyColors {
  // ── 层级 ────────────────────────────────────────────────
  //
  // 三级亮度差。注意这是**亮度差**而非「浮起」：面板和页面之差只有几个
  // 色阶，不配阴影、不配圆角，所以看起来是「划分」而非「悬浮」。
  //
  // 为什么不用纯黑：外壳用中性纯黑会和终端内容区（暖灰 #1E1E1E 系）糊成
  // 一片，终端的外边界消失。带冷蓝的近黑能把终端「框」出来，且在暗环境下
  // 比中性灰耐看、不易显脏。

  /// L0 —— 页面底。极深冷灰，不是纯黑。
  static const Color background = Color(0xFF0D0F12);

  /// L1 —— 分区容器（面板、卡片、表单组）。
  static const Color panel = Color(0xFF14171C);

  /// L2 —— 面板内的次级元素（输入框、内嵌块）。
  static const Color panelElevated = Color(0xFF1A1E24);

  /// 行高亮 / 悬停 / 选中底。比 L1 再亮一档。
  static const Color rowHighlight = Color(0xFF1F242B);

  /// hairline 分线色。
  static const Color divider = Color(0xFF23272E);

  /// 用户消息气泡的填充（AI 面板里「我说的那句」）。
  ///
  /// **不要退回 `colorScheme.primaryContainer`。** 那个槽位在本主题里被映射成
  /// [panelElevated]（`buildFlyTermTheme` 里显式指定的），而 AI 面板自身的
  /// 底色是 `surfaceContainerHighest` —— **也是** [panelElevated]。两者色值
  /// 完全相同，于是气泡画在一模一样的背景上，边界只剩圆角，扫读时根本看不出
  /// 哪条是自己说的。用户反馈「输入内容的背景色与面板背景色相近」即此。
  ///
  /// 改成低透明度品牌 mint：既和面板拉开亮度差，又贴合「我说的那句 = 我这边」
  /// 的语义。mint 在这里是**染色**不是状态编码，用量克制（12%），不会把面板
  /// 染成一片绿。
  ///
  /// 配对使用 [userBubbleBorder]。
  static const Color userBubbleFill = Color(0x1F00C896); // active @ 12%

  /// 用户消息气泡的描边。
  ///
  /// 与 [userBubbleFill] 配对：填充拉开亮度差，描边给出**精确的边界** ——
  /// 对齐本文件开头「层级靠划格与亮度差」的立场。只靠填充时，气泡在深色
  /// 面板上仍偏软，描边是那条 0.5px 的「划格」。
  static const Color userBubbleBorder = Color(0x3D00C896); // active @ 24%

  // ── 文字（三级灰阶）────────────────────────────────────

  /// 主文字。**不用纯白** —— 纯白在深底上过曝，长时间看不适，且会压过
  /// 状态色的辨识度。
  static const Color textPrimary = Color(0xFFD4D4D4);

  /// 次级文字（`root@10.0.1.5`、说明句）。
  static const Color textSecondary = Color(0xFF8A8F98);

  /// 三级文字（section header、最弱的注释、禁用态）。
  static const Color textTertiary = Color(0xFF5C6370);

  // ── 状态色（**只编码状态**）──────────────────────────────

  /// 已连接 / 活动 / 成功。也是品牌色。
  ///
  /// mint 回归到「活动态」这个位置是刻意的：它本来就是这个意思。上一版把它
  /// 判定为「品牌色，该退到图标」，实际是误判 —— 用户在这个 app 里最常需要
  /// 一眼确认的信息就是「哪台连着」。
  static const Color active = Color(0xFF00C896);

  /// 进行中（后台任务）。沿用原值，不回退到别处。
  static const Color pending = Color(0xFFFFB74D);

  /// 失败 / 危险 / 删除。对齐 iTerm2 主题里的 red，让外壳与终端内容区
  /// 用同一支红。
  static const Color danger = Color(0xFFF44747);

  /// 信息 / 次要状态。对齐终端主题的 blue。
  static const Color info = Color(0xFF569CD6);

  /// 警示但非错误（如「本地终端不可用」）。
  static const Color warning = Color(0xFFD7BA7D);

  /// 品牌 mint —— 与 [active] 同值。
  ///
  /// 保留这个别名是为了让「品牌标识」（app 图标、启动页）与「状态编码」
  /// 在语义上可分开引用：将来若要单独调品牌色，不必连带改状态色。
  static const Color brand = active;

  // ── AI 面板装饰色 ────────────────────────────────────────
  //
  // 与上面的「状态色」分开成组，原因很实际：
  //
  // 1. **状态色有语义，改动会误导用户。** `danger` 从红改成橙，用户会
  //    以为「危险等级降低了」。装饰色改了只是换了观感，不涉语义。
  // 2. **方便整组回调。** 这组色彩是 2026-10 加的（用户要「加色彩」），
  //    而本文件顶部的立场是「颜色只编码状态，不做装饰」—— 两者是有张力
  //    的。分组之后，要回退只需删掉这一组 + 把引用改回 `info`/`tertiary`，
  //    不必在 30 个文件里翻找。
  //
  // 用法：**统一走 [aiTintOf] 取色，不要直接引用下面的常量** —— 那个函数
  // 承担了「同一色相在不同亮度下怎么取」这一层，散落引用会重现改造前的
  // 「一个色号手写 37 次」问题。

  /// 助手回答 / 一般信息流。青蓝（hue 190°）。
  static const Color tintBlue = Color(0xFF61C4D8);

  /// 计划 / 方案。紫（hue 262°）—— 「需要你阅读并判断」的语气。
  static const Color tintViolet = Color(0xFF8D61D8);

  /// 知识 / 沉淀。洋红（hue 334°）—— 区别于 mint 的「活动」语义。
  static const Color tintCyan = Color(0xFFD86195);

  /// 数据流动 / 传输。黄（hue 46°）。
  static const Color tintSky = Color(0xFFD8BC61);

  /// 强调的读者注意力落点（新建会话、快捷入口）。绿（hue 118°）。
  static const Color tintAmber = Color(0xFF65D861);

  // ↑ 五个色相在色相环上**等距分布**（190/262/334/46/118，间隔 72°），
  //   固定饱和度 0.55 / 亮度 0.85。这样做的两个好处：
  //
  //   1. **可辨性有数学保证**，不是凭手感选色。实测两两 RGB 距离最小
  //      0.0518，是测试阈值 0.02 的 2.6 倍。此前手选色值连续两轮被
  //      测试打回（blue/cyan 0.018、blue/sky 0.009）—— 说明「看着差不多」
  //      就是真的差不多。
  //   2. **观感分量均等**，没有哪个色相显得比别的「重」。各项饱和度/亮度
  //      一致，仅在色相上分开 —— 这对「同一层级的事件卡」是必要的。

  /// 取一个装饰色的**淡版**，用于卡片底/描边等大面填充。
  ///
  /// 之所以不直接写 `tintX.withValues(alpha: 0.1)`：大面填充上 10% 与 14%
  /// 的观感差异比小图标大得多，而这个值会被反复用到（卡片底、描边、图标
  /// 底三处）。集中在这里，想整体调浓调淡只改一个数。
  static Color tintFill(Color tint) => tint.withValues(alpha: 0.06);

  /// 取一个装饰色的**描边版**。比填充浓一档 —— 填充拉开亮度差，描边走边界。
  static Color tintBorder(Color tint) => tint.withValues(alpha: 0.40);

  // ── 角色层（第一层）────────────────────────────────
  //
  // 2026-10 参考 pi-web 重新分层。之前的问题：事件类型色（上面那组）
  // **直接铺满卡片底色**，一屏出现 5 种大色块 —— 用户看到的是「一片花」，
  // 而且两个语义层（「谁在说话」 vs 「这是哪类事件」）叠在一起分不开。
  //
  // pi-web 的做法是给**角色**定底色（`--user-bg` / `--assistant-bg` /
  // `--tool-bg`），这是有道理的：角色才是对话流的骨架，事件类型是细节。
  //
  // 所以改成两层：
  //
  //   第一层·角色 → **底色**（下面这三个）
  //   第二层·事件 → **描边 + 图标**（上面那组 tint*）
  //
  // 效果：大面上只有「用户的 / 工具的」两种微染，色相退到描边和图标上 ——
  // 信息量不减，但不再是色块混战。

  /// 工具类事件卡的中性底。比面板底亮一档，但不带色相。
  ///
  /// 不带色相是**刻意的**：具体是哪类工具事件由描边色相表达（第二层）。
  static const Color roleToolFill = Color(0x0AD4D4D4); // textPrimary @ 4%

  /// 工具类事件卡的描边色（无事件色相时的默认值）。
  static const Color roleToolBorder = Color(0x1FD4D4D4); // textPrimary @ 12%

  // ── 协议色 ──────────────────────────────────────────────
  //
  // 与 `TerminalScreen._StatusDot` 同源，避免「列表里 QUIC 一个颜色、
  // 终端里另一个颜色」的认知错位。

  static const Color protoSsh = active;
  static const Color protoMosh = info;
  static const Color protoQuic = pending;
}

// ─────────────────────────────────────────────────────────────
// 字阶
// ─────────────────────────────────────────────────────────────

/// 五档字阶 + 一档微标签。
///
/// 改造前 17 档（13 占 48 处、11.5 占 45 处、还有 12.5/13.5/14.5/15.5 这些
/// 只出现一两次的）。那不是在用字阶，是在逐处微调 —— 而逐处微调的结果就是
/// 没有节奏。这里收敛成固定台阶，用法是先问语义（这是标题还是正文？）再选。
abstract final class FlyText {
  /// 20 —— 页面标题。**不是 iOS 的 34pt 大标题**：那种尺寸占掉近 1/4 屏，
  /// 与「信息密度优先」直接冲突。
  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  /// 13 semibold —— 面板标题、分组标题。
  static const TextStyle panelTitle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// 13 —— 正文、列表行主文字、表单。
  static const TextStyle body = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  /// 11.5 —— 次级信息（`root@10.0.1.5`、设置项描述）。
  static const TextStyle secondary = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  /// 10.5 等宽大写 —— 微标签（`SSH` / `QUIC` / section header）。
  ///
  /// 这是仪表盘的标志性手法，**刻意保留**。字距 0.8 是为了让小号大写字母
  /// 不糊在一起；`letterSpacing` 只在字母语言有意义，中文调用处需去掉。
  static const TextStyle micro = TextStyle(
    fontFamily: monoFamily,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    height: 1.0,
    letterSpacing: 0.8,
  );

  /// 等宽字体族名。**只在机器数据上使用** —— IP、端口、路径、命令、
  /// 终端输出、微标签。这些内容等宽是功能性的（对齐、辨认 0/O 与 1/l）。
  ///
  /// **不要拿它排中文句子。** JetBrains Mono 没有中文字形，会 fallback 到
  /// 系统字体，结果是中英混排宽度不匀、基线错位。
  static const String monoFamily = 'JetBrainsMono';
}

// ─────────────────────────────────────────────────────────────
// 间距与圆角
// ─────────────────────────────────────────────────────────────

/// 4 的倍数刻度。改造前有 12/16/8/24/10/14/6 七档且不成体系，
/// 归到一条线上布局才「对得齐」。
abstract final class FlySpace {
  /// 4 —— 紧邻元素（图标与文字之间）。
  static const double xs = 4;

  /// 8 —— 行内元素之间。
  static const double sm = 8;

  /// 12 —— 列表行左右内边距。比消费级的 16 紧，是为密度。
  static const double md = 12;

  /// 16 —— 页面左右边距。
  static const double lg = 16;

  /// 20 —— 分组之间。
  static const double xl = 20;

  /// 24 —— 大段落分隔。
  static const double xxl = 24;
}

/// 圆角。改造前 6 档（8/6/4/2/10/12）。
///
/// **控件整体偏小是刻意的** —— 仪表盘不做圆润。超过 6 就进入消费级的视觉语汇，
/// 与「线条精确」的立场冲突。
///
/// ## 为什么有 [card] / [bubble] 这两档「超标」值
///
/// token 化的第一版只定义了 chip/control/panel 三档（2/4/6），结果**缺档的
/// 语义无处可去，只能继续手写数值** —— 实测 `circular(8)` 有 32 处、
/// `circular(10)` 9 处、`circular(12)` 5 处，`8` 用得比任何合法档位都多。
///
/// 那些 8/10/12 **不是违规，是 token 系统不完备的证据**：它们承载的是
/// 小控件之外的语义（容器、气泡）。修法是**补档**，不是把它们压到 6 ——
/// 强行压平会让对话气泡和卡片变得棱角分明，那是视觉倒退而非优化。
///
/// 界限划在「控件 vs 内容」：控件（输入框、按钮、图标底）收紧到 \u2264 6；
/// 承载内容的大面（卡片、气泡）可以到 10。
abstract final class FlyRadius {
  /// 2 —— chip / 徽标。原来也是 2，保留：小元素上圆角要小于 1/4 边长才
  /// 看得出是「圆角」而不是「缺角」。
  static const double chip = 2;

  /// 4 —— 控件（输入框、按钮、图标底）。
  static const double control = 4;

  /// 6 —— 容器（面板、表单组）。控件语汇的上限。
  static const double panel = 6;

  /// 8 —— 卡片（设置页分组、审批卡、工具调用卡、浮层）。
  ///
  /// 与 [panel] 的分工：`panel` 是**无边框的内嵌分区**，`card` 是**有
  /// 背景/描边、与周围有明确边界的块**。后者需要更大的圆角才不会显得像
  /// 被裁掉一角的矩形。
  static const double card = 8;

  /// 10 —— 对话气泡（用户/助手消息、附件预览）。
  ///
  /// 比 [card] 更圆是**有意的**：气泡是「说出来的话」，卡片是「装东西的
  /// 盒子」，两者的形态本来就不同。这是本文件里唯一为「内容形态」而非
  /// 「控件形态」留的档位。
  static const double bubble = 10;

  /// 胶囊 —— 全圆角的输入框（高度的一半）。
  ///
  /// 2026-10-13 从 `panel_chrome.dart` 里一个写死的 `circular(24)` 提上来。
  /// 那个数字的问题不是大小，而是**它不在 token 体系里** —— 于是 AI 输入框
  /// 既没有全局一致的**高度**，也没有可追溯的**圆角**，成了自成一套的控件。
  ///
  /// 用 999 而不是「高度 / 2」：圆角超过半径就等价于胶囊，写死一个很大的
  /// 值让它在任何高度下都是胶囊形（输入框将来若因为多行变高，圆角仍对）。
  /// 同一条思路在 `FlyRadius` 之外也有先例（`circular(999)` 在本仓库已用过）。
  static const double pill = 999;

  static const BorderRadius chipRadius = BorderRadius.all(
    Radius.circular(chip),
  );
  static const BorderRadius controlRadius = BorderRadius.all(
    Radius.circular(control),
  );
  static const BorderRadius panelRadius = BorderRadius.all(
    Radius.circular(panel),
  );
  static const BorderRadius cardRadius = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius bubbleRadius = BorderRadius.all(
    Radius.circular(bubble),
  );

  /// 全圆角。见 [pill]。
  static const BorderRadius pillRadius = BorderRadius.all(
    Radius.circular(pill),
  );
}

/// 底部 tab 导航栏里**未选中**项的不透明度（乘在 `onSurface` 上）。
///
/// 改造前是 0.45，实测叠在 `#0D0F12` 底上得到 `#676869`，与底色只有
/// **3.44:1** —— 刚过图标最低可辨线（3:1），手机强光下图标发暗。
/// 提到 0.55 后是 **4.53:1**，与正文的 4.5:1 门槛对齐。
///
/// ## 不要再靠调这个值来拉开「选中 vs 未选中」
///
/// 实测：提高未选中亮度会让两者**靠近**，该对比度反而下降 ——
///
/// | alpha | 未选中实际色 | vs 底色 | vs 选中 |
/// |-------|-------------|---------|--------|
/// | 0.45  | `#676869`   | 3.44    | **2.58** |
/// | 0.55  | `#7A7B7D`   | 4.53    | **1.96** |
/// | 0.75  | `#A2A3A4`   | 7.60    | **1.17** |
///
/// 这是**单维度表达的固有缺陷**：只靠颜色，两个值总会在某处靠拢。所以
/// 选中态必须另有形态标记（指示条 + 字重），见 `ShellNavBar`。
const double kNavIdleOpacity = 0.55;

/// 底部 tab 导航栏选中指示条的尺寸。
///
/// 宽 20：比图标（20）略短，看起来是「托住图标」而不是「划一格」。
/// 高 2：与 hairline 同族的细线语汇，不做成 Material 那种 3-4px 的粗条。
const double kNavIndicatorWidth = 20;
const double kNavIndicatorHeight = 2;

/// hairline —— 视觉上 1 物理像素，逻辑值 0.5。
///
/// 这是产品**刻意保留**的一处非 Material 选择。Flutter 里布局小于 1 逻辑
/// 像素的线会被抗锯齿成一段发灰的虚影；0.5 在 2x/3x 屏上正好落在物理像素
/// 边界，是这套视觉语汇里最干净的一条线。
const double kHairline = 0.5;

/// 表单里相邻字段之间的**最小竖向间距**。
///
/// ## 为什么需要一个显式常量
///
/// 原先服务器的字段是一个扁平 `ListView` 里的 `TextFormField` 序列，
/// **彼此之间没有任何显式间距** —— 全靠 `InputDecoration` 自带的空间撑着。
/// 这在带 `helperText` 的字段上会绷不住：辅助文案的占位高度和下一个字段的
/// 边框挤在一起，用户看到的就是「行之间没有间隔，内容重叠」。
///
/// 取 12（= [FlySpace.md]）而不是更大：本产品的立场是「信息密度优先」，
/// 表单一旦拉到 16-20 就开始像 iOS 设置页。12 足够把两个描边框分开，
/// 又不至于散架。
const double kFormFieldGap = FlySpace.md;

// ─────────────────────────────────────────────────────────────
// ThemeData 装配
// ─────────────────────────────────────────────────────────────

/// 把 token 接到 Flutter 的 `ThemeData` 上。
///
/// ## 为什么建整套 colorScheme 而不只设几个字段
///
/// 30k 行 UI 里已有 127 处 `Theme.of(context).colorScheme.x`。把 M3 槽位
/// 映射到这套色板，那批既有引用会自动跟上，不必逐个改 —— 这是「不动页面
/// 结构就完成换肤」得以成立的技术前提。
///
/// ## 为什么不用 `ColorScheme.fromSeed`
///
/// seed 生成法会按色相旋转出一批产品从未选过的颜色（卡片泛绿、面板泛蓝），
/// 与「颜色只编码状态」的立场冲突 —— 装饰性彩色正是要消除的东西。
ThemeData buildFlyTermTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,

    // 主色 = 活动态 mint
    primary: FlyColors.active,
    onPrimary: FlyColors.background,
    primaryContainer: FlyColors.panelElevated,
    onPrimaryContainer: FlyColors.textPrimary,

    secondary: FlyColors.info,
    onSecondary: FlyColors.background,
    secondaryContainer: FlyColors.panelElevated,
    onSecondaryContainer: FlyColors.textPrimary,

    tertiary: FlyColors.textSecondary,
    onTertiary: FlyColors.background,

    error: FlyColors.danger,
    onError: FlyColors.background,
    errorContainer: FlyColors.danger,
    onErrorContainer: FlyColors.background,

    // 表面层级 —— 「亮度差划分」落到 M3 槽位的地方。
    surface: FlyColors.background,
    onSurface: FlyColors.textPrimary,
    surfaceContainerLowest: FlyColors.background,
    surfaceContainerLow: FlyColors.panel,
    surfaceContainer: FlyColors.panel,
    surfaceContainerHigh: FlyColors.panelElevated,
    surfaceContainerHighest: FlyColors.panelElevated,
    // `surfaceVariant` 在新版 M3 被 `surfaceContainerHighest` 取代，但仓库里
    // 既有代码仍在读它。两个槽位给同一个值，等全站清理完再摘掉。
    // ignore: deprecated_member_use
    surfaceVariant: FlyColors.panelElevated,
    onSurfaceVariant: FlyColors.textSecondary,

    outline: FlyColors.divider,
    outlineVariant: FlyColors.divider,

    inverseSurface: FlyColors.textPrimary,
    onInverseSurface: FlyColors.background,
    inversePrimary: FlyColors.active,

    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: FlyColors.background,

    // 关掉 M3 的 surfaceTint 染色 —— 它给每个 Card/AppBar 叠一层主色调，
    // 会让面板跟着 mint 泛绿，与「只编码状态」直接冲突。
    appBarTheme: const AppBarTheme(
      backgroundColor: FlyColors.background,
      foregroundColor: FlyColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: FlyColors.textPrimary,
        height: 1.2,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: FlyColors.divider,
      thickness: kHairline,
      space: kHairline,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: FlyColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(FlyRadius.panel),
        ),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: FlyColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(FlyRadius.panel)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: FlyColors.textSecondary,
      textColor: FlyColors.textPrimary,
      dense: true,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: FlyColors.panelElevated,
      contentTextStyle: TextStyle(
        fontSize: 13,
        color: FlyColors.textPrimary,
        height: 1.35,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: FlyColors.panelElevated,
      hintStyle: FlyText.secondary.copyWith(color: FlyColors.textTertiary),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: FlySpace.md,
        // vertical 2026-10-13 从 `FlySpace.sm + 2`（10）收到 `FlySpace.sm`（8）。
        //
        // 动机是全局一致性：AI 面板底部输入框当时被单独压到 40dp，而它是
        // 全 app 最矮的一档（主流 44dp）—— 跨页跳转时那个差异看得出来。
        // 两个选择：把 AI 那个改回去，或把标准整体收紧一次。选了后者，
        // 因为“面板底部寸土寸金”对其它页面同样成立。
        //
        // 这一处改动会同时影响所有**没自己写 contentPadding** 的输入框。
        // `input_height_baseline_test` 钉住了改动后的标准高度。
        // 仍自己写 contentPadding 的那一批是**遗留不一致**（见那个测试的
        // 第二条）—— 逐步删掉那些覆盖、交给 theme，而不是各自调数字。
        vertical: FlySpace.sm,
      ),
      border: const OutlineInputBorder(
        borderRadius: FlyRadius.controlRadius,
        borderSide: BorderSide(color: FlyColors.divider, width: kHairline),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: FlyRadius.controlRadius,
        borderSide: BorderSide(color: FlyColors.divider, width: kHairline),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: FlyRadius.controlRadius,
        borderSide: BorderSide(color: FlyColors.active, width: 1),
      ),
    ),
    // 字体：不设 fontFamily，交给系统。等宽只在需要处显式指定
    // `FlyText.monoFamily`。这也是「中英混排」能正常显示的前提。
    textTheme: base.textTheme.apply(
      bodyColor: FlyColors.textPrimary,
      displayColor: FlyColors.textPrimary,
    ),
  );
}

// ---------------------------------------------------------------------------
// 统一的搜索框形态
// ---------------------------------------------------------------------------

/// 搜索框的图标槽尺寸。
///
/// **这不是随便定的数，是为了让搜索框与其它输入框同高。**
///
/// `prefixIcon` / `suffixIcon` 默认带 48×48 的最小触摸区（Material 的
/// 可点击目标建议值）。而标准输入框是 40dp —— 比 48 矮。不显式约束的话，
/// 那个 48 会把输入框**撑高**到 48dp。
///
/// 2026-10-13 审计发现的真实数据（全 app 4 个搜索框，4 种高度）：
///
/// | 搜索框 | 高度 | 主因 |
/// |---|---|---|
/// | 全局标准（无图标） | 40dp | — |
/// | AI 历史会话 | 48dp | prefixIcon 默认 48 撑高 |
/// | 服务器/隧道 | 38dp | contentPadding.vertical: 7 压低 |
/// | SFTP | 36dp | contentPadding.vertical: 6 压低 |
/// | 终端 | 40dp | 恰好写对 |
///
/// 取值 40 而不是 48：40 与输入框等高，图标自然居中；48 会反过来撑高
/// 输入框。图标本体只有 17–18dp，40 的槽仍远比它宽裕，触摸区域也够
/// （整行都是输入框的点击区，点图标槽等于聚焦输入框）。
const double kSearchIconSlot = 40;

/// 嵌在 **AppBar** 里的搜索框高度（SFTP 那个）。
///
/// 页面级搜索框的标准高度是 `40dp`（走 theme，见 [searchFieldDecoration]），
/// 但那个值要求父容器不是 AppBar —— AppBar 的 action 槽高度由 toolbar 决定，
/// 让一个 40dp 的控件在里面会顶着上下边、而且输入时 AppBar 可能跟着重算高度。
///
/// 所以嵌在 AppBar 里的那一档单独命名。36 是改动前 SFTP 就用的值（那里写着
/// “Fixed height prevents the AppBar from resizing while typing”），行为不变，
/// 只是从魔数变成有名字的档位。
const double kSearchFieldAppBarHeight = 36;

/// 搜索框的图标槽约束。见 [kSearchIconSlot]。
const BoxConstraints kSearchIconConstraints =
    BoxConstraints(minWidth: kSearchIconSlot, minHeight: kSearchIconSlot);

/// 搜索框的统一 decoration。
///
/// ## 为什么需要这个函数
///
/// 审计发现全 app 4 个搜索框有 4 种高度（36 / 38 / 40 / 48）。根因是两个
/// 各自为政的旋钮：
///
/// 1. **`contentPadding` 覆盖** —— 每个页面自己写一个 vertical
///    （终端 8、服务器 7、SFTP 6）。本该交给 theme。
/// 2. **`prefixIcon` 的默认 48 触摸区** —— 会把输入框撑到 48。只有一处
///    记得显式约束。
///
/// 两个旋钮都不该由调用方逐个调：它们是**搜索框这个形态**的属性，不是
/// 某个页面的偏好。这个函数就是那个形态的唯一定义。
///
/// ## 与普通输入框的唯一差别
///
/// 只有图标槽约束（[kSearchIconConstraints]）。其它一律走 theme ——
/// **包括高度**。搜索框在视觉上可以更"轻"，但"轻"该由图标大小和 hint
/// 文案表达，不由高度表达：高度不一致就是跳页时看得出别扭的那种不一致。
///
/// [accent] 为 true 时边框用强调色（当前是给需要突出"这是临时过滤条"的
/// 场景留的口子，暂无调用方；留着是为了让新增搜索框有地方放这类需求，
/// 而不是又各自写一套 decoration）。传 false（默认）则完全走 theme。
InputDecoration searchFieldDecoration({
  required String hintText,
  Widget? prefixIcon,
  /// 清除按钮的 onPressed。null = 不显示清除按钮。
  ///
  /// **不要自己传 `suffixIcon`**：`IconButton` 自带 48×48 的 minimumSize，
  /// 会把输入框撑到 48dp —— 外层给 `suffixIconConstraints` 也拦不住它
  /// （2026-10-13 实测：`Icon` 做 suffix 是 40dp，`IconButton` 做 suffix
  /// 就是 48dp，无论 constraints 怎么给）。
  ///
  /// 所以清除按钮由本函数统一构造，把 `constraints` / `visualDensity` /
  /// `padding` 都设对。调用方只需给一个回调。
  VoidCallback? onClear,
  bool accent = false,
}) {
  return InputDecoration(
    hintText: hintText,
    // `isDense` 与 theme 一致，显式写出来是为了让这个函数的输出**不依赖**
    // theme 当前的值 —— 将来 theme 改了，搜索框的行为仍然可预测。
    isDense: true,
    prefixIcon: prefixIcon,
    // 图标槽必须显式约束，理由见 [kSearchIconSlot]。prefix/suffix 都要：
    // 只约束一个的话，另一个仍会把行撑高。
    prefixIconConstraints: kSearchIconConstraints,
    suffixIcon: onClear == null
        ? null
        : IconButton(
            icon: const Icon(Icons.clear, size: 18),
            color: FlyColors.textTertiary,
            onPressed: onClear,
            // 三件都要：只给 constraints 拦不住 IconButton 自己的
            // minimumSize（见上面 onClear 的文档）。
            constraints: kSearchIconConstraints,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
    suffixIconConstraints: kSearchIconConstraints,
    // **不写 contentPadding / border** —— 交给 theme。
    // 写了就又回到「每个页面自己调数字」那条老路上。
  );
}

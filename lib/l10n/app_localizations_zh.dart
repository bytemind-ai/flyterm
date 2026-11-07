// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'FlyTerm';

  @override
  String get newConnection => '新建连接';

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get save => '保存';

  @override
  String get add => '添加';

  @override
  String get edit => '编辑';

  @override
  String get sftpViewSource => '查看源码';

  @override
  String get sftpViewPreview => '查看渲染';

  @override
  String get sftpMarkdownTruncated => '文件较大，仅显示开头部分。';

  @override
  String get required => '必填';

  @override
  String get confirm => '确定';

  @override
  String get importAction => '导入';

  @override
  String get noServers => '暂无服务器';

  @override
  String get addServer => '添加服务器';

  @override
  String get viaJumpHost => '通过跳板机连接';

  @override
  String get newSession => '新建会话';

  @override
  String get sftpFileBrowser => 'SFTP 文件管理';

  @override
  String get newTunnel => '新建隧道';

  @override
  String get deleteServerTitle => '删除服务器？';

  @override
  String confirmDeleteServer(String name) {
    return '确定删除 \"$name\"？';
  }

  @override
  String sftpConnectFailed(String error) {
    return 'SFTP 连接失败：$error';
  }

  @override
  String get editServer => '编辑服务器';

  @override
  String get newServer => '新建服务器';

  @override
  String get labelName => '名称';

  @override
  String get labelHost => '主机地址';

  @override
  String get labelHostHelper => '支持 IPv4 / IPv6 / 主机名（IPv6 可带可不带方括号）';

  @override
  String get labelPort => '端口';

  @override
  String get addressFamilyLabel => '地址协议';

  @override
  String get addressFamilyAuto => '自动（优先 IPv6）';

  @override
  String get addressFamilyIpv4 => '强制 IPv4';

  @override
  String get addressFamilyIpv6 => '强制 IPv6';

  @override
  String get invalidPort => '端口无效';

  @override
  String get labelUsername => '用户名';

  @override
  String get labelStartupCommand => '连接后执行的命令（可选）';

  @override
  String get hintStartupCommand => '如：tmux、cd /var/log';

  @override
  String get authMethod => '认证方式';

  @override
  String get authPassword => '密码';

  @override
  String get authSshKey => 'SSH 密钥';

  @override
  String get labelPassword => '密码';

  @override
  String get selectKey => '选择密钥';

  @override
  String get keyRequired => '请选择密钥';

  @override
  String get addSshKey => '新建密钥';

  @override
  String get hostKeyTofuTitle => '首次连接 — 校验主机密钥';

  @override
  String get hostKeyTofuBody => 'FlyTerm 第一次连接到这台服务器。请与管理员确认指纹一致后再接受。';

  @override
  String get hostKeyMismatchTitle => '主机密钥已改变！';

  @override
  String get hostKeyMismatchBody =>
      '服务器密钥与已保存的不一致。可能是服务器重装，也可能是中间人攻击。在确认安全前不要继续。';

  @override
  String get hostKeyHost => '主机';

  @override
  String get hostKeyType => '密钥类型';

  @override
  String get hostKeyFingerprint => '指纹（MD5）';

  @override
  String get hostKeyExpected => '期望指纹';

  @override
  String get hostKeyActual => '实际收到指纹';

  @override
  String get hostKeyAccept => '信任并连接';

  @override
  String get hostKeyAcceptAnyway => '仍然连接（覆盖保存的密钥）';

  @override
  String get hostKeyReject => '取消';

  @override
  String get knownHostsTitle => '已信任主机';

  @override
  String get knownHostsEntry => '已信任主机';

  @override
  String get knownHostsEntrySubtitle => '服务器指纹白名单';

  @override
  String get knownHostsEmpty => '尚未信任任何主机。首次连接新服务器时会提示你确认指纹。';

  @override
  String get knownHostDelete => '删除';

  @override
  String get knownHostDeleteTitle => '忘记此主机？';

  @override
  String get sshCompressionTitle => 'SSH 压缩';

  @override
  String get sshCompressionDesc =>
      '对 SSH 流量启用 zlib — 慢速 / 计费网络下显著省带宽；高速 LAN 上 CPU 开销大于收益时可关闭。';

  @override
  String get backgroundKeepAliveTitle => '后台保活';

  @override
  String get backgroundKeepAliveDesc =>
      'app 切到后台时保持终端连接不断。代价是通知栏会常驻一条通知 —— Android 强制前台服务显示它，无法隐藏。关闭后切后台会断线，也收不到服务器推来的任务通知。';

  @override
  String get notificationPermissionTitle => '通知权限';

  @override
  String get notificationPermissionGranted => '通知已允许';

  @override
  String get notificationPermissionDenied =>
      'FlyTerm 的通知被系统挡住 —— 任务完成与审批提醒都无法显示';

  @override
  String get notificationPermissionChannelDisabled => '「任务通知」频道被关闭 —— 提醒无法显示';

  @override
  String get notificationPermissionUnknown => '在这台设备上无法判断通知权限';

  @override
  String get notificationPermissionOpenSettings => '打开系统设置';

  @override
  String get notificationPermissionRequest => '允许通知';

  @override
  String get notifySessionGone => '那个会话已经关闭了';

  @override
  String knownHostDeleteBody(String host) {
    return '下次连接 $host 时 FlyTerm 会重新要求确认指纹。';
  }

  @override
  String get tmuxAutoRecover => 'tmux 自动会话恢复';

  @override
  String get tmuxAutoRecoverDesc => '切网/重连后自动恢复上次终端会话，需服务器已安装 tmux';

  @override
  String get transport => '传输协议';

  @override
  String get transportRecommended => '推荐';

  @override
  String get useTmux => '使用 tmux (进程持久化)';

  @override
  String get useTmuxDesc => '仅当远端 server 重启后 PTY 不丢才需要';

  @override
  String get useDaemon => 'Daemon 模式 (远端常驻)';

  @override
  String get useDaemonDesc => '支持跨 SSH 会话恢复；启动失败显式报错，不静默回退';

  @override
  String get useMosh => '使用 Mosh';

  @override
  String get moshDesc => '通过 UDP 连接，支持漫游，需服务端安装 mosh-server';

  @override
  String get moshNotSupportedWithJump => 'Mosh 不支持跳板机 — 请改传输协议或取消跳板机';

  @override
  String get moshPortRange => 'Mosh 端口范围';

  @override
  String get moshPortRangeFormat => '格式：起始端口:终止端口';

  @override
  String get moshPortMustBeInt => '端口必须为整数';

  @override
  String get moshStartBeforeEnd => '起始端口必须小于终止端口';

  @override
  String get useJumpHost => '通过跳板机连接';

  @override
  String get useJumpHostDesc => '经由另一台服务器跳转到此服务器';

  @override
  String get selectJumpServer => '选择跳板服务器';

  @override
  String get jumpServerRequired => '请选择跳板服务器';

  @override
  String get addJumpServer => '新建跳板服务器';

  @override
  String get sectionConnection => '连接';

  @override
  String get sectionAccount => '账户';

  @override
  String get sectionAppearance => '外观';

  @override
  String get sectionInput => '输入';

  @override
  String get sectionSecurity => '安全';

  @override
  String get sectionAbout => '关于';

  @override
  String get appearanceSettingsTitle => '外观设置';

  @override
  String get connectionAdvancedTitle => '高级连接选项';

  @override
  String get securitySettingsTitle => '安全设置';

  @override
  String get aboutTitle => '关于';

  @override
  String keybarCount(int count) {
    return '$count 项';
  }

  @override
  String get enabled => '已启用';

  @override
  String get disabled => '已关闭';

  @override
  String get sectionAI => 'AI';

  @override
  String get sectionData => '数据与隐私';

  @override
  String get settings => '设置';

  @override
  String get sshKeys => 'SSH 密钥';

  @override
  String get sshKeysSubtitle => '管理 SSH 密钥对';

  @override
  String get aiProviders => 'AI 服务商';

  @override
  String get aiProvidersSubtitle => '配置 AI API 密钥';

  @override
  String get tunnels => '隧道';

  @override
  String tunnelCountBadge(int count) {
    return '$count 隧道';
  }

  @override
  String get aiErrorHint => 'AI 错误智能提示';

  @override
  String get aiErrorHintDesc => '检测到错误时提示 AI 分析';

  @override
  String get terminalFontSize => '终端字体大小';

  @override
  String get terminalCursorStyle => '光标样式';

  @override
  String get terminalCursorStyleDefault => '默认';

  @override
  String get terminalCursorStyleVerticalBar => '竖线';

  @override
  String get terminalCursorStyleBlock => '块状';

  @override
  String get terminalCursorStyleUnderline => '下划线';

  @override
  String get dangerousCommandGuard => '危险命令保护';

  @override
  String get dangerousCommandGuardDesc => '手动输入 rm -rf、dd 等高风险命令时弹窗确认';

  @override
  String get commandCompletionTitle => '命令补全';

  @override
  String get commandCompletionSubtitle =>
      '从命令历史与远端 shell 给出候选。本地完成，不需要配置 AI provider。';

  @override
  String get noKeys => '暂无密钥';

  @override
  String get copyPublicKey => '复制公钥';

  @override
  String get addKey => '添加密钥';

  @override
  String get publicKeyCopied => '公钥已复制到剪贴板';

  @override
  String get deleteKeyTitle => '删除密钥？';

  @override
  String confirmDeleteKey(String name) {
    return '确定删除 \"$name\"？';
  }

  @override
  String get generateEd25519 => '生成 Ed25519 密钥';

  @override
  String get generateRsa4096 => '生成 RSA 4096 密钥';

  @override
  String get importFromPem => '从 PEM 导入';

  @override
  String get keyName => '密钥名称';

  @override
  String get keyNameHint => '例如 my-macbook';

  @override
  String get pastePem => '粘贴私钥 (PEM 格式)';

  @override
  String get noProviders => '暂无 AI 服务商';

  @override
  String get setDefault => '设为默认';

  @override
  String get addProvider => '添加服务商';

  @override
  String get deleteProviderTitle => '删除服务商？';

  @override
  String confirmDeleteProvider(String name) {
    return '确定删除 \"$name\"？';
  }

  @override
  String get editProvider => '编辑服务商';

  @override
  String get displayName => '显示名称';

  @override
  String get providerType => '服务商类型';

  @override
  String get model => '模型';

  @override
  String get baseUrl => 'Base URL（可选）';

  @override
  String get apiKey => 'API Key';

  @override
  String get apiKeyEditHint => 'API Key（留空保留原有密钥）';

  @override
  String get extrasJson => '扩展参数 (JSON，可选)';

  @override
  String get invalidJson => '请输入合法的 JSON 对象';

  @override
  String get setAsDefault => '设为默认服务商';

  @override
  String get providerSectionIdentity => 'IDENTITY';

  @override
  String get providerSectionEndpoint => 'ENDPOINT';

  @override
  String get providerSectionAuth => 'AUTH';

  @override
  String get providerSectionAdvanced => 'ADVANCED';

  @override
  String get providerSectionPresets => 'PRESETS';

  @override
  String get providerModelVolatileHint => '模型名会变动。若接口报模型不存在，到服务商控制台核对当前名称。';

  @override
  String get noTunnels => '暂无隧道';

  @override
  String get tapPlusToAdd => '点击右下角 + 新建';

  @override
  String get reconnect => '重连';

  @override
  String get deleteTunnelTitle => '删除隧道？';

  @override
  String confirmDeleteTunnel(String name) {
    return '删除 \"$name\" 及其保存的配置？';
  }

  @override
  String get disableAutoConnect => '禁用自动连接';

  @override
  String get enableAutoConnect => '启用自动连接';

  @override
  String get startTunnel => '启动';

  @override
  String get stopTunnel => '停止';

  @override
  String get deleteConfig => '删除配置';

  @override
  String get tunnelStatusActive => '运行中';

  @override
  String get tunnelStatusConnecting => '连接中…';

  @override
  String tunnelStatusReconnecting(int count, int max) {
    return '重连中 ($count/$max)…';
  }

  @override
  String get tunnelStatusFailed => '重连失败';

  @override
  String get tunnelStatusError => '错误';

  @override
  String get tunnelStatusStopped => '已停止';

  @override
  String get selectServer => '选择服务器';

  @override
  String get tunnelDirLocal => '本地';

  @override
  String get tunnelDirRemote => '远程';

  @override
  String get tunnelDescLocal => '手机端口 → 服务器端口（访问远程服务）';

  @override
  String get tunnelDescRemote => '服务器端口 → 手机端口（暴露本地服务）';

  @override
  String get tunnelDescSocks5 => '在手机端口启动 SOCKS5 代理（流量经 SSH 转发）';

  @override
  String get labelLocalPort => '本地端口（手机）';

  @override
  String get invalidTunnelPort => '请输入有效端口（1–65535）';

  @override
  String get labelRemoteHost => '远程主机';

  @override
  String get labelRemotePort => '远程端口';

  @override
  String get labelTunnelLabel => '标签（可选）';

  @override
  String get hintTunnelLabel => '例如 MySQL 3306';

  @override
  String get autoStartTunnel => '启动时自动连接';

  @override
  String get autoStartTunnelDesc => '每次启动应用时自动重连此隧道';

  @override
  String get submitOnce => '仅此一次';

  @override
  String get submitSaveAndStart => '保存并启动';

  @override
  String tunnelFailed(String error) {
    return '失败：$error';
  }

  @override
  String get pleaseSelectServer => '请选择服务器';

  @override
  String get errorDetected => '检测到错误，AI 可以帮你分析';

  @override
  String get aiAnalyze => 'AI 分析';

  @override
  String get aiAnalyzeError => '帮我分析终端里的这个错误';

  @override
  String get aiAnalyzeErrorChip => '分析错误';

  @override
  String moshFallback(String message) {
    return 'Mosh 降级为 SSH: $message';
  }

  @override
  String get reconnectInProgress => '重新连接中...';

  @override
  String get refreshing => '正在刷新...';

  @override
  String get reconnectSuccess => '已重新连接';

  @override
  String reconnectFailedWithError(String error) {
    return '重连失败：$error';
  }

  @override
  String get reconnectErrTimeout => '连接超时，请检查网络';

  @override
  String get reconnectErrRefused => '连接被拒绝';

  @override
  String get reconnectErrReset => '连接被重置';

  @override
  String get reconnectErrUnreachable => '网络不可达';

  @override
  String get reconnectErrDns => '域名解析失败';

  @override
  String get reconnectErrAuth => '认证失败';

  @override
  String get reconnectErrPermission => '权限被拒绝';

  @override
  String get reconnectErrSocket => '网络连接错误';

  @override
  String reconnectRetryCountdown(
    int seconds,
    int round,
    int attempt,
    int total,
  ) {
    return '${seconds}s 后重试（第 $round 轮 $attempt/$total）...';
  }

  @override
  String get reconnectNetworkUnstableRetry => '网络不稳定，30s 后重试';

  @override
  String reconnectCascadeWarning(String protocol, int count, int minutes) {
    return '$protocol: $minutes 分钟内已重连 $count 次，网络可能不稳定';
  }

  @override
  String reconnectLoopDetected(String protocol) {
    return '$protocol: 重连循环检测到，已停止自动重连，请手动刷新';
  }

  @override
  String get reconnectMoshHandshake => 'Mosh 握手中...';

  @override
  String get reconnectMoshConnected => 'Mosh SSP 连接成功';

  @override
  String get reconnectMoshFallback => 'Mosh 降级为 SSH';

  @override
  String reconnectMoshFallbackWithReason(String reason) {
    return 'Mosh 降级为 SSH：$reason';
  }

  @override
  String get reconnectMoshDisconnectedRestoring => 'Mosh 断线，尝试恢复会话...';

  @override
  String get reconnectMoshSessionRestored => 'Mosh 会话已恢复';

  @override
  String get reconnectMoshRestoreFailedRehandshake => 'Mosh 会话无法恢复，重新握手...';

  @override
  String get tmuxNotFoundDisabled => 'tmux 未找到，已自动关闭';

  @override
  String get enterPassword => '输入密码';

  @override
  String get split => '分屏';

  @override
  String get tabMove => '移动';

  @override
  String get splitVertical => '上下分屏';

  @override
  String get splitHorizontal => '左右分屏';

  @override
  String get layoutPickerTitle => '分屏';

  @override
  String get layoutSingle => '单屏';

  @override
  String layoutWithCurrent(String state) {
    return '分屏 · $state';
  }

  @override
  String get closeSplit => '关闭分屏';

  @override
  String get floatTerminal => '悬浮终端';

  @override
  String get closeFloat => '关闭悬浮';

  @override
  String get saveFavoriteDialogTitle => '收藏命令';

  @override
  String get favoriteCommandNameLabel => '命令名称';

  @override
  String get commandSaved => '命令已收藏';

  @override
  String get notConnected => '未连接';

  @override
  String get back => '返回';

  @override
  String connectingTo(String host) {
    return '正在连接 $host…';
  }

  @override
  String get voiceUnavailable => '语音输入暂不可用';

  @override
  String get voicePermissionTitle => '开启语音输入';

  @override
  String get voiceMicrophonePermissionContent =>
      '语音输入需要麦克风权限。请在系统设置中允许 FlyTerm 使用麦克风。';

  @override
  String get voiceSpeechPermissionContent =>
      'iPhone/iPad 上语音输入还需要「语音识别」权限。请在系统设置中允许 FlyTerm 使用语音识别。';

  @override
  String get voiceRecognizerUnavailableContent =>
      '麦克风权限已检查，但当前系统语音识别服务不可用或被禁用。请在系统设置中启用语音输入/语音助手，或安装 Google App / 系统语音服务后重试。如果仍然不行，大多数输入法自带麦克风按键——它走的是输入法自己的识别通道，与本应用无关，可以试试那个。';

  @override
  String get voiceNoSpeechContent =>
      '未检测到语音。请确认系统麦克风开关已开启、设备有可用麦克风，并检查是否有其他应用正在占用麦克风。';

  @override
  String get voiceBusyContent => '语音识别服务正忙。请稍后重试。';

  @override
  String get voiceNetworkContent => '语音识别需要网络连接。请检查网络后重试。';

  @override
  String get voiceUnknownContent => '语音输入暂时不可用。请检查麦克风权限和系统语音识别服务后重试。';

  @override
  String get voiceOpenSettings => '去设置';

  @override
  String get voiceRetry => '重新检测';

  @override
  String get voiceLater => '稍后';

  @override
  String get voiceErrorTitle => '语音输入出错';

  @override
  String get voiceErrorHint => '可长按选中下面这段文字复制，发给开发者定位问题：';

  @override
  String get voiceCopyDiagnostics => '复制诊断';

  @override
  String get voiceDiagnosticsCopied => '已复制';

  @override
  String sftpSaved(String name) {
    return '已保存：$name';
  }

  @override
  String sftpSymlinkTarget(String target) {
    return '→ $target';
  }

  @override
  String get sftpSymlinkDangling => '链接目标不存在';

  @override
  String get sftpErrPermissionDenied => '权限不足，请检查文件权限。';

  @override
  String get sftpErrNotFound => '路径不存在，可能已被移动或删除。';

  @override
  String get sftpErrDiskFull => '远端空间不足。';

  @override
  String get sftpErrDisconnected => '连接已断开，请重连后重试。';

  @override
  String get sftpErrAlreadyExists => '同名文件已存在。';

  @override
  String get sftpErrRawDetail => '详细信息';

  @override
  String downloadSavedToPublic(String path) {
    return '已保存到 $path';
  }

  @override
  String get open => '打开';

  @override
  String sftpDownloadFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String get sftpBatchSelect => '批量选择';

  @override
  String get sftpDownloadFolder => '下载文件夹';

  @override
  String get sftpDownload => '下载';

  @override
  String get sftpOpenWithSystem => '使用其他应用打开';

  @override
  String sftpConfirmLargeOpen(String name, String size) {
    return '$name 大小为 $size，确定下载并用其他应用打开？';
  }

  @override
  String sftpOpeningFile(String name) {
    return '正在下载 $name…';
  }

  @override
  String get rename => '重命名';

  @override
  String get permissions => '权限';

  @override
  String get sftpNewName => '新名称';

  @override
  String sftpConfirmDeleteEntry(String name) {
    return '删除 \"$name\"？';
  }

  @override
  String get sftpNewFolderTitle => '新建文件夹';

  @override
  String get sftpFolderName => '文件夹名称';

  @override
  String get sftpNewFileTitle => '新建文件';

  @override
  String get sftpFileName => '文件名称';

  @override
  String get sftpJumpToPath => '跳转到路径';

  @override
  String get create => '创建';

  @override
  String get jump => '跳转';

  @override
  String get apply => '应用';

  @override
  String sftpPermissionsTitle(String name) {
    return '权限 — $name';
  }

  @override
  String get sftpOwner => '拥有者';

  @override
  String get sftpGroup => '群组';

  @override
  String get sftpOther => '其他';

  @override
  String get sftpRead => '读';

  @override
  String get sftpWrite => '写';

  @override
  String get sftpExecute => '执';

  @override
  String sftpSelectedCount(int count) {
    return '已选 $count 个';
  }

  @override
  String get sftpSelectAll => '全选';

  @override
  String sftpSelectedItems(int count) {
    return '$count 个已选';
  }

  @override
  String sftpScanningFiles(int count) {
    return '扫描中... 已发现 $count 个文件';
  }

  @override
  String sftpUploading(String filename) {
    return '上传 $filename';
  }

  @override
  String get sftpEmptyDirectory => '空目录';

  @override
  String sftpRenameFailed(String error) {
    return '重命名失败：$error';
  }

  @override
  String sftpDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String sftpCreateFailed(String error) {
    return '创建失败：$error';
  }

  @override
  String sftpChmodFailed(String error) {
    return '修改失败：$error';
  }

  @override
  String sftpDownloadsCompleted(int count) {
    return '已完成 $count 个下载';
  }

  @override
  String sftpConfirmDeleteSelected(int count) {
    return '删除已选的 $count 个项目？此操作不可撤销。';
  }

  @override
  String get sftpCreateFolderAction => '新建目录';

  @override
  String get sftpCreateFileAction => '新建文件';

  @override
  String get sftpUploadFileAction => '上传文件';

  @override
  String get sftpUploadFolderAction => '上传文件夹';

  @override
  String sftpConflictTitle(int count) {
    return '有 $count 个文件已存在';
  }

  @override
  String get sftpConflictBody => '上传会覆盖它们，且无法撤销。';

  @override
  String get sftpConflictOverwriteAll => '全部覆盖';

  @override
  String get sftpConflictSkipAll => '跳过已存在';

  @override
  String sftpConflictSkipped(int count) {
    return '已跳过 $count 个已存在的文件';
  }

  @override
  String get aiAssistant => 'AI 助手';

  @override
  String get aiMicUnavailableTitle => '无法使用语音输入';

  @override
  String get aiMicUnavailableContent =>
      '麦克风权限未授予或设备不支持语音识别。\n\n请前往手机「设置 → 应用 → FlyTerm → 权限」，开启麦克风权限后重新进入应用。';

  @override
  String get aiNoProvider => '未配置 AI 服务商，请前往 设置 → AI 服务商 添加。';

  @override
  String get aiEmptyHint => '描述你想执行的操作，AI 会生成命令并让你一键执行。\n\n例如：找出占用内存最多的进程';

  @override
  String get aiGoConfig => '去配置 →';

  @override
  String get aiListeningHint => '正在聆听…';

  @override
  String get aiInputHint => '描述操作或提问…';

  @override
  String get aiClearHistory => '清空对话';

  @override
  String get aiNewSession => '新建会话';

  @override
  String get aiMoreActions => '更多操作';

  @override
  String get aiSessionHistory => '历史会话';

  @override
  String get aiHistoryEmpty => '还没有归档的会话';

  @override
  String get aiHistorySearchHint => '搜标题';

  @override
  String get aiHistoryNoMatch => '没有匹配的会话';

  @override
  String aiHistoryQuotaHint(int keep) {
    return '每台机器保留最近 $keep 段；标星的不计入。';
  }

  @override
  String aiHistoryEvents(int count) {
    return '$count 条';
  }

  @override
  String get aiHistoryUntitled => '(无标题)';

  @override
  String get aiHistoryDeleteTitle => '删除这段会话？';

  @override
  String get aiHistoryDelete => '删除';

  @override
  String get aiCopyAction => '复制';

  @override
  String get aiMessageCopied => '已复制';

  @override
  String get aiRetryAction => '重试';

  @override
  String get aiEditAction => '编辑';

  @override
  String get aiExplainAction => '解释';

  @override
  String get aiSaveAction => '收藏';

  @override
  String get aiRunAction => '执行';

  @override
  String get aiCommandFailed => '命令执行失败';

  @override
  String aiOutputLines(int count) {
    return '$count 行';
  }

  @override
  String get aiGotIt => '知道了';

  @override
  String get favoritesTitle => '收藏命令';

  @override
  String get addFavoriteTooltip => '添加收藏';

  @override
  String get noFavorites => '暂无收藏命令\n点击右上角 + 添加';

  @override
  String get editFavoriteTitle => '编辑收藏命令';

  @override
  String get addFavoriteTitle => '添加收藏命令';

  @override
  String get favoriteName => '名称';

  @override
  String get favoriteNameHint => '如：更新系统';

  @override
  String get favoriteCommand => '命令';

  @override
  String get favoriteCommandHint => '支持模板变量';

  @override
  String get favoriteRun => '执行';

  @override
  String get favoriteAiEnabled => '允许 AI 调用';

  @override
  String get favoriteAiEnabledHint => 'AI 会看到这条命令的名字和模板';

  @override
  String favoriteAiBudget(int count, int tokens) {
    return '$count 条对 AI 开放，每次请求约 $tokens token';
  }

  @override
  String favoriteAiOverflow(int count) {
    return '$count 条超出上限，不会提供给 AI';
  }

  @override
  String get sftpDownloadDir => '下载目录';

  @override
  String get sftpDownloadDirDownloads => '公共下载目录（文件 App 可见）';

  @override
  String get sftpDownloadDirDocuments => '文稿文件夹';

  @override
  String get sftpDownloadDirCustom => '自定义路径';

  @override
  String get sftpCustomPathHint => '例如 /storage/emulated/0/MyFolder';

  @override
  String get searchServers => '搜索服务器…';

  @override
  String get noSearchResults => '未找到匹配的服务器';

  @override
  String get serverGroup => '分组（可选）';

  @override
  String get close => '关闭';

  @override
  String get terminalTheme => '终端主题';

  @override
  String get terminalThemeDefault => '默认深色';

  @override
  String get terminalThemeDracula => 'Dracula';

  @override
  String get terminalThemeSolarizedDark => 'Solarized Dark';

  @override
  String get terminalThemeMonokai => 'Monokai';

  @override
  String get terminalThemeSolarizedLight => 'Solarized 浅色';

  @override
  String get terminalThemeNord => 'Nord';

  @override
  String get terminalThemeGruvboxDark => 'Gruvbox Dark';

  @override
  String get terminalThemeOneDark => 'One Dark';

  @override
  String get terminalThemeTokyoNight => 'Tokyo Night';

  @override
  String get cursorBlink => '光标闪烁';

  @override
  String get cursorBlinkSubtitle => '终端获得焦点时光标闪烁';

  @override
  String get selectionColor => '选中文字颜色';

  @override
  String get selectionColorSubtitle => '选中文本时的高亮颜色';

  @override
  String get keybarCustomize => 'KeyBar 自定义';

  @override
  String get keybarCustomizeSubtitle => '重排、编辑、新增按键';

  @override
  String get fetSettingsTitle => 'SFTP 切换按钮';

  @override
  String get fetSettingsSubtitle => '切换终端与 SFTP 视图的悬浮按钮';

  @override
  String get fetSettingsShow => '显示悬浮按钮';

  @override
  String get fetSettingsShowSubtitle => '在终端右侧显示快速切换 SFTP 的悬浮按钮';

  @override
  String get fetSettingsAutoHide => '自动隐藏到边缘';

  @override
  String get fetSettingsAutoHideSubtitle => '无操作 7 秒后贴边隐藏';

  @override
  String get fetSettingsOpacity => '透明度';

  @override
  String get fetSettingsResetPosition => '重置位置';

  @override
  String get fetSettingsResetPositionSubtitle => '将悬浮按钮恢复到屏幕中央';

  @override
  String get fetSettingsResetDone => '已重置悬浮按钮位置';

  @override
  String get sftpSwitchToSftp => '切换 SFTP';

  @override
  String get sftpSwitchToTerminal => '返回终端';

  @override
  String get sftpOnboardingHint => '点击切换 SFTP/终端，拖动可调位置，向右快速甩动可隐藏';

  @override
  String get keybarLongPressEdit => '编辑';

  @override
  String get keybarLongPressDelete => '删除';

  @override
  String get keybarEmptyHint => '长按按键或打开 设置 → KeyBar 自定义 以添加按键';

  @override
  String get keybarEditorTitle => 'KeyBar 自定义';

  @override
  String get keybarEditorAddTooltip => '新建按键';

  @override
  String get keybarEditorRestoreDefaults => '恢复默认配置';

  @override
  String get keybarEditorConfirmRestoreTitle => '恢复默认 KeyBar？';

  @override
  String get keybarEditorConfirmRestoreBody => '所有自定义按键将被移除。';

  @override
  String get keybarEditorConfirmRestoreOk => '恢复';

  @override
  String get keybarEditorConfirmRestoreCancel => '取消';

  @override
  String get keybarEditItemTitle => '编辑按键';

  @override
  String get keybarEditItemNew => '新建按键';

  @override
  String get keybarEditItemLabel => '标签';

  @override
  String get keybarEditItemSequence => '序列';

  @override
  String get keybarEditItemInsertSpecial => '插入特殊键';

  @override
  String get keybarEditItemRepeatable => '长按自动重复';

  @override
  String get keybarEditItemSave => '保存';

  @override
  String get keybarEditItemValidationLabel => '标签不能为空';

  @override
  String get keybarEditItemValidationSequence => '序列不能为空';

  @override
  String get keybarSpecialPickerTitle => '选择特殊键';

  @override
  String get keybarSpecialCategoryControl => '控制';

  @override
  String get keybarSpecialCategoryModifiers => '修饰键';

  @override
  String get keybarSpecialCategoryArrows => '方向';

  @override
  String get keybarSpecialCategoryNav => '导航';

  @override
  String get keybarSpecialCategoryModifierCombos => '修饰组合';

  @override
  String get keybarSpecialCategoryFunction => '功能键';

  @override
  String get keybarSpecialCategoryCtrl => 'Ctrl 组合';

  @override
  String get keybarEditItemSequenceHint => '输入文本…';

  @override
  String get keybarEditItemSticky => '粘性修饰键（CTRL 类型）';

  @override
  String get keybarEditItemStickyHint => '不发送字节，仅切换一个标志；下一个按键会带 Ctrl 修饰发送。';

  @override
  String get keybarCtrlNotApplicable => '该按键不支持 CTRL 修饰';

  @override
  String get keybarShiftNotApplicable => '该按键不支持 SHIFT 修饰';

  @override
  String get keybarEditorSectionKeyboardMode => '键盘弹出方式';

  @override
  String get keybarEditorSectionLeftKeys => '终端键';

  @override
  String get keybarEditorSectionRightButtons => '右侧功能按钮';

  @override
  String get keybarRightButtonKeyboard => '键盘';

  @override
  String get keybarRightButtonFavorites => '收藏';

  @override
  String get keybarRightButtonMicrophone => '麦克风';

  @override
  String get keybarRightButtonAi => 'AI';

  @override
  String get keybarRightButtonAttachFile => '附件';

  @override
  String get attachFileNoConnection => '连接不可用，先重连再试';

  @override
  String get attachFileNameTaken => '同名文件太多，请先清理一下';

  @override
  String attachFileFailed(String error) {
    return '上传失败：$error';
  }

  @override
  String attachFileRenamed(String name) {
    return '文件名含特殊字符，已改为 $name';
  }

  @override
  String get agentForwarding => 'SSH Agent 转发';

  @override
  String get agentForwardingDesc => '允许远程主机通过本机密钥认证下一跳';

  @override
  String get importConfigPreviewSkills => 'AI 技能';

  @override
  String get exportConfigSubject => 'FlyTerm 配置备份';

  @override
  String exportConfigDone(String path) {
    return '已导出：$path';
  }

  @override
  String exportConfigFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String importConfigFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String importConfigDone(int count) {
    return '已导入 $count 项';
  }

  @override
  String get exportConfigEmpty => '（空配置）';

  @override
  String get exportConfigIncludeAi => '包含 AI 服务商配置';

  @override
  String get exportConfigIncludeAiDesc =>
      '关闭后备份不含 provider 配置（API Key 本就不在备份里）';

  @override
  String get exportConfigIncludeKnowledge => '包含 AI 知识与笔记';

  @override
  String get exportConfigIncludeKnowledgeDesc => '技能库与各机器的 agent 笔记。体积可能较大';

  @override
  String get importConfigKeepAppearance => '保留我当前的外观设置';

  @override
  String get importConfigKeepAppearanceDesc => '不覆盖主题、字体与 KeyBar 布局';

  @override
  String get importConfigPreviewSshKeysNotIncluded =>
      'SSH 私钥不在备份中 —— 导入后需重新导入私钥才能用这些密钥连接';

  @override
  String exportConfigCountServers(int count) {
    return '$count 台服务器';
  }

  @override
  String exportConfigCountKeys(int count) {
    return '$count 个密钥';
  }

  @override
  String exportConfigCountFavCmds(int count) {
    return '$count 条收藏';
  }

  @override
  String exportConfigCountAi(int count) {
    return '$count 个 AI 配置';
  }

  @override
  String exportConfigCountTunnels(int count) {
    return '$count 条隧道';
  }

  @override
  String exportConfigCountKnownHosts(int count) {
    return '$count 个已知主机';
  }

  @override
  String exportConfigCountNotes(int count) {
    return '$count 条机器笔记';
  }

  @override
  String exportConfigCountSkills(int count) {
    return '$count 条 AI 技能';
  }

  @override
  String get exportConfig => '导出配置';

  @override
  String get exportConfigSubtitle => '将服务器和密钥元数据保存为 JSON 文件';

  @override
  String get importConfig => '导入配置';

  @override
  String get importConfigSubtitle => '从之前导出的 JSON 文件恢复';

  @override
  String get exportConfigSendToDevice => '发送到其他设备';

  @override
  String get exportConfigSaveLocal => '保存到下载目录';

  @override
  String get exportConfigHasAiKeys => '⚠ AI 密钥（API Key）不会被导出，导入后需重新填写';

  @override
  String get importConfigPreviewKnownHosts => '已知主机';

  @override
  String get importConfigPreviewKeybarWarning => '⚠ 屏幕键盘栏将被覆盖';

  @override
  String get importConfigPreviewAiKeysNotIncluded =>
      '⚠ 不含 AI 密钥（API Key），导入后需重新填写';

  @override
  String get exportConfigNeverBackedUp => '从未备份';

  @override
  String exportConfigLastBackup(String timeAgo) {
    return '上次备份：$timeAgo';
  }

  @override
  String get importConfigPreviewTitle => '导入预览';

  @override
  String get importConfigPreviewServers => '服务器';

  @override
  String get importConfigPreviewKeys => 'SSH 密钥';

  @override
  String get importConfigPreviewFavCmds => '收藏命令';

  @override
  String get importConfigPreviewAiProviders => 'AI 配置';

  @override
  String get importConfigPreviewTunnels => '隧道';

  @override
  String importConfigPreviewNew(int count) {
    return '$count 个（全部新增）';
  }

  @override
  String importConfigPreviewWithSkip(int newCount, int skipCount) {
    return '$newCount 个新增，$skipCount 个重复将跳过';
  }

  @override
  String get importConfigPreviewSettingsWarning => '⚠ 终端设置（主题、字体大小）将覆盖当前值';

  @override
  String get importConfigConfirm => '确认导入';

  @override
  String importConfigSuccessWithSkip(int newCount, int skipCount) {
    return '已导入 $newCount 项，$skipCount 项重复已跳过';
  }

  @override
  String get sessionSummary => '会话摘要';

  @override
  String get sessionSummaryPrompt => '请帮我总结这段终端会话：执行了哪些关键操作、哪些成功/失败了、当前状态如何。';

  @override
  String get sftpSearchHint => '搜索文件名…';

  @override
  String get sftpSortByName => '按名称';

  @override
  String get sftpSortBySize => '按大小';

  @override
  String get sftpSortByTime => '按时间';

  @override
  String get sftpSortAscending => '升序';

  @override
  String get sftpSortDescending => '降序';

  @override
  String get sftpSortToggleToDesc => '改为降序';

  @override
  String get sftpSortToggleToAsc => '改为升序';

  @override
  String get sftpSortDirectionLabel => '顺序';

  @override
  String get sftpSortTooltip => '排序';

  @override
  String sftpResuming(String filename) {
    return '续传 $filename';
  }

  @override
  String get tabRefresh => '刷新';

  @override
  String get version => '版本';

  @override
  String versionSubtitleDebugActive(String version) {
    return '$version · 调试面板已开启（连点切换）';
  }

  @override
  String get debugOverlayEnabled => '调试面板已开启';

  @override
  String get debugOverlayDisabled => '调试面板已关闭';

  @override
  String debugOverlayTapsRemaining(int count) {
    return '再点 $count 次切换调试面板';
  }

  @override
  String get keyboardTrigger => '键盘弹出方式';

  @override
  String get keyboardTriggerSingleTap => '单击弹出';

  @override
  String get keyboardTriggerSingleTapDesc => '点击终端区域即弹出键盘';

  @override
  String get keyboardTriggerDoubleTap => '双击弹出';

  @override
  String get keyboardTriggerDoubleTapDesc => '快速双击终端区域弹出键盘';

  @override
  String get keyboardTriggerIconButton => '图标按钮';

  @override
  String get keyboardTriggerIconButtonDesc => '点击工具栏键盘图标弹出';

  @override
  String get selectionCopy => '复制';

  @override
  String selectionCopied(int count) {
    return '已复制 $count 个字符';
  }

  @override
  String get selectionExpired => '选区已失效，请重新选择';

  @override
  String get selectionSelect => '选择';

  @override
  String get selectionPaste => '粘贴';

  @override
  String get pasteClipboardEmpty => '剪贴板为空';

  @override
  String get pasteNotConnected => '未连接，无法粘贴';

  @override
  String pasteTooLarge(String size) {
    return '剪贴板内容过大（$size），已取消粘贴';
  }

  @override
  String get fontSection => '终端字体';

  @override
  String get fontSize => '大小';

  @override
  String get codeFont => '代码字体';

  @override
  String get codeFontDesc => '英文、数字、符号显示';

  @override
  String get fontFamilySystem => '系统默认';

  @override
  String get lineHeight => '行间距';

  @override
  String get lineHeightDesc => '字行之间的留白,数值越大越宽松';

  @override
  String get serverTypeSshMosh => 'SSH / Mosh';

  @override
  String get serverTypeRemote => '远程';

  @override
  String get serverTypeLocal => '本地';

  @override
  String get localShellUnsupported => '本平台不支持本地终端，请改为连接远程服务器。';

  @override
  String get ungrouped => '其他';

  @override
  String get consentTitle => '欢迎使用 FlyTerm';

  @override
  String get consentIntro => '在使用本应用前，请阅读并同意以下条款：';

  @override
  String get consentPrivacyLink => '隐私政策';

  @override
  String get consentTosLink => '服务条款';

  @override
  String get consentCrashOptIn => '允许发送崩溃报告帮助修复问题（可在设置中关闭）';

  @override
  String get consentAcceptButton => '同意并继续';

  @override
  String get consentDeclineButton => '拒绝并退出';

  @override
  String get privacyPolicyTitle => '隐私政策';

  @override
  String get termsOfServiceTitle => '服务条款';

  @override
  String get privacyPreferences => '隐私偏好';

  @override
  String get privacyCrashReportingToggle => '崩溃报告';

  @override
  String get privacyCrashReportingDesc => '发生崩溃时上传堆栈帮助修复（已脱敏，不含主机信息）';

  @override
  String get privacyAnalyticsToggle => '使用统计';

  @override
  String get privacyAnalyticsDesc => '上传关键操作事件用于产品改进';

  @override
  String get privacyViewPolicy => '查看隐私政策';

  @override
  String get privacyViewToS => '查看服务条款';

  @override
  String get privacyRevokeButton => '撤回同意并退出应用';

  @override
  String get privacyRevokeConfirmTitle => '撤回同意？';

  @override
  String get privacyRevokeConfirmDesc => '撤回后将退出应用，下次启动需要重新同意条款。';

  @override
  String get privacyRevokeConfirmYes => '撤回并退出';

  @override
  String get privacyRevokeConfirmNo => '取消';

  @override
  String get consentSubtitle => '一款尊重你隐私的移动终端工具';

  @override
  String get consentHighlightKeysTitle => '密钥本地存储';

  @override
  String get consentHighlightKeysDesc => '加密保存在系统 Keychain / Keystore，从不上传';

  @override
  String get consentHighlightCrashTitle => '匿名崩溃报告';

  @override
  String get consentHighlightCrashDesc => '已脱敏，不含主机或账号信息';

  @override
  String get consentHighlightControlTitle => '随时可控';

  @override
  String get consentHighlightControlDesc => '在设置中可关闭崩溃报告与统计';

  @override
  String get consentAgreeBoilerplate => '继续即表示您同意我们的';

  @override
  String get consentAgreeBoilerplateAnd => '和';

  @override
  String get consentDeclineHint => '不同意？';

  @override
  String get consentDeclineExit => '退出';

  @override
  String get privacySectionDocuments => '文档';

  @override
  String get privacySectionDangerZone => '危险操作';

  @override
  String get privacyRevokeCardDesc => '撤回后下次启动需要重新同意条款';

  @override
  String get paywallTitle => 'FlyTerm Pro';

  @override
  String get paywallSubtitle => '一次性买断，永久解锁全部高级功能';

  @override
  String get paywallFeatureQuic => 'QUIC 协议 — 低延迟 + 网络漫游';

  @override
  String get paywallFeatureAi => 'AI 集成 — 语音输入与错误分析';

  @override
  String get paywallFeatureTunnel => '端口转发 / SFTP / Mosh';

  @override
  String get paywallFeatureFutureUpdates => '永久接收未来 Pro 功能更新';

  @override
  String paywallPurchaseButton(String price) {
    return '购买 $price';
  }

  @override
  String get paywallRestoreButton => '已购买？恢复';

  @override
  String get paywallContinueLater => '稍后再说';

  @override
  String get paywallLoadingPrice => '加载价格中…';

  @override
  String get paywallUnavailable => '应用商店不可用，请稍后再试';

  @override
  String get paywallPurchasePending => '支付确认中…';

  @override
  String paywallPurchaseError(String error) {
    return '购买失败：$error';
  }

  @override
  String get paywallRestoreNoneFound => '未找到此账号下的购买记录';

  @override
  String get paywallRestoreSuccess => '已恢复购买，Pro 已解锁';

  @override
  String get proStatusPro => 'FlyTerm Pro · 已激活';

  @override
  String get proStatusFree => '免费版';

  @override
  String proStatusPurchasedAt(String date) {
    return '于 $date 购买';
  }

  @override
  String get proStatusUpgrade => '升级到 Pro';

  @override
  String get proStatusRestore => '恢复购买';

  @override
  String get settingsOpenSourceLicenses => '开源许可';

  @override
  String get settingsOpenSourceLicensesSubtitle => '查看第三方库及许可证';

  @override
  String get updatePromptTitleOptional => '有可用更新';

  @override
  String get updatePromptTitleMandatory => '需要更新';

  @override
  String updatePromptBody(Object latest, Object current) {
    return '新版本 $latest 已发布（当前 $current）。';
  }

  @override
  String get updatePromptReleaseNotes => '更新内容';

  @override
  String get updatePromptUpdate => '立即更新';

  @override
  String get updatePromptLater => '稍后';

  @override
  String get agentToolRunning => '执行中';

  @override
  String get agentToolDone => '完成';

  @override
  String get agentToolFailed => '失败';

  @override
  String get agentToolRejected => '已拒绝';

  @override
  String get agentToolAwaiting => '等待批准';

  @override
  String get agentToolExpand => '展开输出';

  @override
  String get agentToolCollapse => '收起';

  @override
  String agentExitCode(int code) {
    return '退出码 $code';
  }

  @override
  String get agentApprovalTitle => '需要你批准';

  @override
  String get agentAllowOnce => '允许一次';

  @override
  String get agentSilenceInSession => '本轮不再问';

  @override
  String agentDenyWarning(String provider) {
    return '此命令涉及凭据文件，允许后内容将发送给 $provider';
  }

  @override
  String get agentReasonMetachar => '命令含 shell 元字符，必须逐条确认';

  @override
  String get agentReasonNoRule => '没有匹配的允许规则';

  @override
  String get agentReasonFileWrite => '会写入文件——每次都需要确认';

  @override
  String get agentInstructionsTitle => 'AI 助手说明';

  @override
  String get agentInstructionsEntry => '自定义说明';

  @override
  String get agentInstructionsEntrySet => '已设置';

  @override
  String get agentInstructionsEntryEmpty => '未设置';

  @override
  String get agentInstructionsHint =>
      '告诉 AI 你希望它怎么回答。例如：回答简洁点，别铺排；先说结论再说过程；用中文。\n\n这份说明对所有服务器生效。某台机器自己的特殊之处（用 podman、日志在 /data/logs）请写进下面那台机器的笔记里，而不是这里。';

  @override
  String get agentInstructionsLocalLabel => '全局说明（所有服务器共用，只存在这台手机上）';

  @override
  String get agentInstructionsSaved => '已保存';

  @override
  String agentInstructionsRemaining(int n) {
    return '还可以输入 $n 字节';
  }

  @override
  String agentInstructionsTooLong(int max) {
    return '超出 $max 字节，超出部分不会发给 AI';
  }

  @override
  String get agentSkillsEntry => '技能';

  @override
  String get agentSkillsEntryEmpty => '还没有';

  @override
  String agentSkillsEntryCount(int count) {
    return '已存 $count 个';
  }

  @override
  String get agentSkillsTitle => '技能';

  @override
  String get agentSkillsHint => '助手在相关时会自己取用的排查流程和工具说明。每次请求只带上每条的那一行描述。';

  @override
  String agentSkillsBudget(int count, int tokens) {
    return '$count 个技能，每次请求约 $tokens token';
  }

  @override
  String agentSkillsOverflow(int count) {
    return '$count 个技能超出索引上限，模型要先检索才能找到';
  }

  @override
  String get agentSkillsEmpty => '还没有技能。让助手在解决完一个问题后存一个，或者从服务器、文件导入。';

  @override
  String get agentSkillsImportFromServer => '从这台服务器导入';

  @override
  String get agentSkillsImportFromFile => '从文件导入';

  @override
  String get agentSkillsImportFromFolder => '导入技能目录';

  @override
  String get agentSkillsImportFromArchive => '导入 .zip 包';

  @override
  String skillImportAssetCount(int n) {
    return '$n 个附件';
  }

  @override
  String get agentSkillsCreateManually => '手动新建';

  @override
  String get agentSkillsImportTitle => '导入技能';

  @override
  String get agentSkillsImportNone => '这台服务器的 ~/.flyterm/skills 里没有技能。';

  @override
  String agentSkillsImportSkipped(int count) {
    return '$count 个文件无法解析，已跳过';
  }

  @override
  String get agentSkillsImportConfirm => '导入所选';

  @override
  String get agentSkillsImportNeedsDescription => '补一行描述';

  @override
  String agentSkillsConflictTitle(String name) {
    return '已经有一个叫「$name」的技能';
  }

  @override
  String get agentSkillsConflictOverwrite => '覆盖';

  @override
  String get agentSkillsConflictKeepBoth => '两份都留';

  @override
  String get agentSkillsConflictSkip => '跳过';

  @override
  String get agentSkillsSourceAi => '助手写的';

  @override
  String get agentSkillsSourceRemote => '来自服务器';

  @override
  String get agentSkillsSourceFile => '来自文件';

  @override
  String get agentSkillsSourceManual => '手动创建';

  @override
  String get agentKnowledgeCaptureTitle => '排查完自动提议沉淀';

  @override
  String get agentKnowledgeCaptureDesc => '排查完自动整理成卡片，可存为技能或机器笔记';

  @override
  String get agentSkillDetailTitle => '技能';

  @override
  String get agentSkillCreateTitle => '新建技能';

  @override
  String get agentSkillNameLabel => '名称';

  @override
  String get agentSkillDescriptionLabel => '描述（每次请求都会带上）';

  @override
  String get agentSkillBodyLabel => '正文';

  @override
  String get agentSkillAssetsLabel => '附件（由 install_skill_assets 投送到服务器）';

  @override
  String get agentSkillAssetExecutable => '可执行 —— 投送时加 x 位';

  @override
  String get agentSkillAssetData => '数据文件';

  @override
  String get skillAssetAdd => '添加文件';

  @override
  String get skillAssetEdit => '编辑文件';

  @override
  String get skillAssetEmptyHint => '没有附件。如果某段脚本每次都一样，可以加成附件。';

  @override
  String get skillAssetPathLabel => '技能目录内的路径';

  @override
  String get skillAssetPathHelper =>
      '相对路径，如 scripts/check.sh —— 不能以 / 开头，不能有 ..';

  @override
  String get skillAssetPathInvalid => '必须是相对路径，且不含 .. 或反斜杠';

  @override
  String get skillAssetExecutableToggle => '可执行';

  @override
  String get skillAssetExecutableHint => '投送时在服务器上标记 +x';

  @override
  String get skillAssetContentLabel => '文件内容';

  @override
  String skillAssetTotalTooBig(int bytes, int limit) {
    return '这些附件合计 $bytes 字节，上限是 $limit。';
  }

  @override
  String get agentSkillDelete => '删除技能';

  @override
  String get agentSkillDeleteConfirm => '删除这个技能？不可撤销。';

  @override
  String get agentSkillSaved => '已保存';

  @override
  String agentSkillLoadedInPanel(String name) {
    return '使用技能：$name';
  }

  @override
  String agentSkillSaveCardTitle(String name) {
    return '保存技能「$name」？';
  }

  @override
  String agentSkillUpdateCardTitle(String name) {
    return '更新技能「$name」？';
  }

  @override
  String get agentSkillNeverUsed => '从未用过';

  @override
  String agentSkillUsedDaysAgo(int days) {
    return '$days 天没用了';
  }

  @override
  String get agentSkillUsedToday => '今天用过';

  @override
  String agentSkillHits(int n) {
    return '用过 $n 次';
  }

  @override
  String get agentSkillNotLoaded => '未进索引 · 需检索';

  @override
  String get agentSkillNotLoadedHint =>
      '超出索引上限的技能不会直接出现在 system prompt 里，模型需要先调 search_skills 才能找到它们，多花一轮工具往返。想让它一眼就看见，就腾出索引位置（禁用或删掉用不上的），而不是删掉这些。';

  @override
  String get agentBuiltinSkillsSection => '内置';

  @override
  String get agentBuiltinSkillsHint => '随 App 出厂。可以关掉，但不能删除或修改。';

  @override
  String get agentBuiltinSkillBadge => '内置';

  @override
  String get agentBuiltinSkillTitleTroubleshoot => '排查故障';

  @override
  String get agentBuiltinSkillDescTroubleshoot => '出问题时：先定位原因再动手，改完独立验证。';

  @override
  String get agentBuiltinSkillTitlePlanChange => '规划改动';

  @override
  String get agentBuiltinSkillDescPlanChange => '多步骤任务：先澄清需求，方案获批后再一步一验地改。';

  @override
  String get agentBuiltinSkillTitleSkillCreator => '写技能';

  @override
  String get agentBuiltinSkillDescSkillCreator =>
      '写技能时：把描述写成触发条件、正文写成步骤、脚本用附件而不是写进正文。';

  @override
  String get agentAddToPlan => '加入方案';

  @override
  String get agentAddToPlanHint => '攒起来，稍后连同其他改动一起批准';

  @override
  String get agentProposalTitle => '要执行这些改动吗？';

  @override
  String agentProposalCount(int n) {
    return '$n 项待执行';
  }

  @override
  String get agentProposalApprove => '全部执行';

  @override
  String get agentProposalDiscard => '丢弃';

  @override
  String get agentProposalNote => '批准后这几项会依次执行；其中一项失败就会停下，剩下的留着等你决定。';

  @override
  String get agentKnowledgeTitle => '要把这次学到的存下来吗？';

  @override
  String get agentKnowledgeTargetSkill => '技能';

  @override
  String get agentKnowledgeTargetNotes => '本机笔记';

  @override
  String get agentKnowledgeSave => '存入';

  @override
  String agentKnowledgeUpdate(String name) {
    return '更新 $name';
  }

  @override
  String get agentKnowledgeDismiss => '忽略';

  @override
  String get agentKnowledgeSaved => '已存入';

  @override
  String get agentKnowledgeExpand => '看全文';

  @override
  String get agentKnowledgeCollapse => '收起';

  @override
  String agentKnowledgeNotesFull(int bytes) {
    return '本机笔记已满，还需精简 $bytes 字节';
  }

  @override
  String get agentKnowledgeSwitchHint => '点归属标识可以改存到哪';

  @override
  String get agentAdvancedRules => '高级：自动执行清单';

  @override
  String get agentUndo => '撤销';

  @override
  String get agentUndone => '已撤销';

  @override
  String get agentUndoBackupMissing => '备份已不存在，无法撤销';

  @override
  String get agentToolSuperseded => '抢跑结果已弃用，此命令已重新执行';

  @override
  String get agentDiffEmpty => '（空）';

  @override
  String agentDiffAtLine(String path, int line) {
    return '$path · 第 $line 行';
  }

  @override
  String get agentDiffExpand => '显示全部';

  @override
  String get agentDiffCollapse => '收起';

  @override
  String get agentRejectReasonHint => '（可选）告诉 AI 为什么拒绝';

  @override
  String get agentStop => '停止';

  @override
  String get agentThinking => '思考中…';

  @override
  String agentRateLimited(int seconds) {
    return '已被限流，$seconds 秒后重试';
  }

  @override
  String get agentRunning => '执行中…';

  @override
  String agentThinkingFor(int seconds) {
    return '思考中 ${seconds}s';
  }

  @override
  String agentRunningFor(int seconds) {
    return '执行中 ${seconds}s';
  }

  @override
  String agentExecutingMany(int count, int seconds) {
    return '执行 $count 个命令 ${seconds}s';
  }

  @override
  String get agentAwaitingYou => '等你确认';

  @override
  String get agentAwaitingAnswer => '等你回答';

  @override
  String agentRunningCalls(int count) {
    return '已调用 $count 次';
  }

  @override
  String get agentAskOther => '其他…';

  @override
  String get agentAskUnanswered => '未回答';

  @override
  String get mentionServerColonHint => '打 : 浏览这台机器的文件';

  @override
  String mentionUnknownServer(String name) {
    return '没有这台机器：$name';
  }

  @override
  String agentTurnSummary(String duration, int calls, String tokens) {
    return '本轮 $duration · $calls 次调用 · $tokens token';
  }

  @override
  String get agentTurnSummaryTooltip => '时长含 app 切到后台的时间';

  @override
  String agentStoppedMaxTurns(int n) {
    return '已达轮数上限（$n 轮）。要继续吗？';
  }

  @override
  String get agentStoppedTokenBudget => '上下文已接近上限。要继续吗？';

  @override
  String get agentStoppedCancelled => '已停止。已经发出的命令不会撤销。';

  @override
  String get agentStoppedInvalidArgs => '模型连续给出无效的工具参数，已中止。';

  @override
  String get agentContinue => '继续';

  @override
  String get agentRetry => '重试';

  @override
  String get agentInputHint => '描述要排查的问题，@ 引用服务器，/ 开头用技能';

  @override
  String get attachPick => '添加图片或文件';

  @override
  String get attachRemove => '移除';

  @override
  String get attachUnsupportedVision => '当前模型不支持图片输入';

  @override
  String get attachTryAnyway => '仍要试一次';

  @override
  String get attachRejectBinary => '只支持图片和文本文件';

  @override
  String get attachRejectEmpty => '文件是空的';

  @override
  String attachTooLarge(String size) {
    return '图片太大（$size），请裁剪后再试';
  }

  @override
  String attachTextTruncated(String size) {
    return '（文件已截断，原始大小 $size）';
  }

  @override
  String get attachMissing => '图片已不可用';

  @override
  String attachSkippedOnSend(int count) {
    return '$count 个附件已不可用，未随本轮发送';
  }

  @override
  String get attachSaveFailed => '附件保存失败';

  @override
  String get attachUnreadable => '读不到这个文件。云盘或在线文档里的文件需要先下载到本机再选。';

  @override
  String attachContextOverflow(int tokens) {
    return '上下文超出模型上限，图片约占 $tokens token；新建会话或移除图片后重试';
  }

  @override
  String get mentionFilesUnavailable => '文件浏览不可用';

  @override
  String get mentionNeedAbsolutePath => '请使用绝对路径（以 / 开头）';

  @override
  String mentionDirLoadFailed(String error) {
    return '读取目录失败：$error';
  }

  @override
  String mentionMoreEntries(int count) {
    return '还有 $count 条，继续输入以缩小范围';
  }

  @override
  String get agentPendingWithdrawHint => '待发送，点击撤回';

  @override
  String agentUsage(String input, String output) {
    return '输入 $input · 输出 $output';
  }

  @override
  String agentUsageCumulative(String session, String total) {
    return '$session · 累计 $total';
  }

  @override
  String agentUsageCached(String input, String cached, String output) {
    return '输入 $input（缓存命中 $cached）· 输出 $output';
  }

  @override
  String get agentNoCredentials => '该服务器没有已保存的凭据，agent 模式不可用';

  @override
  String get agentGoToServerSettings => '去设置';

  @override
  String get agentNoToolSupport => '当前模型不支持工具调用';

  @override
  String get agentSettingsTitle => 'AI Agent';

  @override
  String get agentModeBypassWarning =>
      'AI 将在这台服务器上直接执行任何命令，也能修改 FlyTerm 自身的设置。触碰凭据文件的操作和不可撤销的操作仍会询问。';

  @override
  String get agentRulesTitle => '自动允许的命令';

  @override
  String get agentRulesBuiltinGroup => '默认规则';

  @override
  String get agentRulesUserGroup => '你批准过的';

  @override
  String get agentRulesEmpty => '还没有你自己批准的规则';

  @override
  String get agentRulesFirstReview => '这些命令 AI 可以直接执行，不会问你。请过目一遍——你可以关掉任何一条。';

  @override
  String get agentRulesGotIt => '我知道了';

  @override
  String get agentRulesGoReview => '去过目放行清单';

  @override
  String get agentMemorySection => '助手记忆';

  @override
  String get agentAllowlistEntry => '自动执行清单';

  @override
  String agentAllowlistSubtitleEnabled(int enabled, int total) {
    return '$enabled / $total 类已放行';
  }

  @override
  String get agentToolTierGroup => '工具档位';

  @override
  String get agentToolTierAuto => '自动';

  @override
  String get agentToolTierLean => '精简';

  @override
  String get agentToolTierFull => '完整';

  @override
  String get agentToolTierAutoDesc => '自动：云端模型用完整工具集，本地模型（如 Ollama）用精简的 2 个工具';

  @override
  String get agentToolTierLeanDesc => '精简：只有 bash 和 read_file——适合小模型/本地模型';

  @override
  String get agentToolTierFullDesc =>
      '完整：额外提供 write_file、edit_file、set_plan——适合能力强的云端模型';

  @override
  String get agentBannerAskTitle => '当前：会先问我';

  @override
  String get agentBannerBypassTitle => '当前：不会问你';

  @override
  String get agentBannerPlanTitle => '当前：先出方案';

  @override
  String get agentCapabilityAutoLabel => '自动执行';

  @override
  String get agentCapabilityAutoValue => '查看日志、看进程、读文件、查容器';

  @override
  String get agentCapabilityAskLabel => '需要你确认';

  @override
  String get agentCapabilityAskValue => '改文件、重启服务、删除、任何带管道的命令';

  @override
  String get agentRuleGroupServiceTitle => '服务状态与日志';

  @override
  String get agentRuleGroupServiceSubtitle => '服务在不在跑、它的日志';

  @override
  String get agentRuleGroupSystemTitle => '系统与进程';

  @override
  String get agentRuleGroupSystemSubtitle => '谁在跑、磁盘内存还剩多少';

  @override
  String get agentRuleGroupNetworkTitle => '网络监听';

  @override
  String get agentRuleGroupNetworkSubtitle => '哪些端口在听、连到了哪里';

  @override
  String get agentRuleGroupFilesTitle => '文件内容';

  @override
  String get agentRuleGroupFilesSubtitle => '会把文件内容发给 AI';

  @override
  String get agentRuleGroupFilesWarning =>
      '私钥、.env、.kube/config 这类文件即使这组开着也会单独弹审批。';

  @override
  String get agentRuleGroupDockerTitle => 'Docker 容器';

  @override
  String get agentRuleGroupDockerSubtitle => '容器状态与日志';

  @override
  String get agentRuleGroupK8sTitle => 'Kubernetes';

  @override
  String get agentRuleGroupK8sSubtitle => '集群资源与日志';

  @override
  String get agentRuleGroupOtherTitle => '其他';

  @override
  String get agentPanelBypassActiveTooltip => '全部放行已开启，agent 不会再询问';

  @override
  String get agentInstructionsExamplesLabel => '试试这些：';

  @override
  String get agentInstructionsExample1 => '回答简洁点，别铺排';

  @override
  String get agentInstructionsExample2 => '先说结论，再说过程';

  @override
  String get agentInstructionsExample3 => '用中文回答';

  @override
  String get agentServerNotesEntry => '这台机器的笔记';

  @override
  String agentServerNotesLines(int n) {
    return '$n 行';
  }

  @override
  String get agentServerNotesNone => '未创建';

  @override
  String get agentServerNotesTitle => '这台机器的笔记';

  @override
  String get agentServerNotesHint =>
      '这台机器的约定和脾气 —— 「用 podman 不用 docker」「日志在 /data」。每轮都会发给模型，写短一点。';

  @override
  String get agentServerNotesEmpty => '还没有内容';

  @override
  String agentServerNotesBytes(int used, int max) {
    return '$used / $max 字节';
  }

  @override
  String get agentServerNotesSave => '保存';

  @override
  String agentServerNotesTooLong(int n) {
    return '超出 $n 字节，精简一下。';
  }

  @override
  String get agentServerNotesOverviewEntry => '机器笔记';

  @override
  String agentServerNotesOverviewSubtitle(int n) {
    return '$n 台机器';
  }

  @override
  String get agentServerNotesOverviewEmpty =>
      '还没有任何机器笔记。它们会在你干活的过程中攒起来，也可以在某台服务器的设置里手写。';

  @override
  String agentServerNotesUpdatedAt(String time) {
    return '最后更新：$time';
  }

  @override
  String get agentServerNotesDelete => '删除这份笔记';

  @override
  String agentServerNotesForMachine(String name) {
    return '机器笔记：$name';
  }

  @override
  String agentToolRunningFor(int seconds) {
    return '已运行 ${seconds}s';
  }

  @override
  String agentToolTook(String duration) {
    return '耗时 $duration';
  }

  @override
  String agentJobRunning(String elapsed) {
    return '已运行 $elapsed';
  }

  @override
  String agentJobFinished(int code) {
    return '已结束 · 退出码 $code';
  }

  @override
  String get agentJobKilling => '正在终止…';

  @override
  String agentJobSinceStart(String elapsed) {
    return '距启动 $elapsed';
  }

  @override
  String get agentJobCheckedJustNow => '刚确认过';

  @override
  String agentJobCheckedMinutes(int n) {
    return '$n 分钟前确认';
  }

  @override
  String agentJobCheckedHours(int n) {
    return '$n 小时前确认';
  }

  @override
  String agentJobCheckedDays(int n) {
    return '$n 天前确认';
  }

  @override
  String agentJobsBarCount(int count) {
    return '$count 个后台任务';
  }

  @override
  String get agentJobStop => '终止';

  @override
  String get transferDownloading => '正在下载';

  @override
  String get transferUploading => '正在上传';

  @override
  String transferRelayDownloading(String from) {
    return '正在从 $from 取';
  }

  @override
  String transferRelayUploading(String to) {
    return '正在送往 $to';
  }

  @override
  String get transferDone => '完成';

  @override
  String get transferCancelled => '已取消';

  @override
  String get transferFailed => '失败';

  @override
  String get transferInterrupted => '已中断';

  @override
  String get transferCancel => '取消';

  @override
  String get transferOpen => '打开';

  @override
  String get transferLetAiRead => '让 AI 读完';

  @override
  String get transferShare => '分享';

  @override
  String get transferCredentialWarning => '凭据文件 —— 内容不会发给 AI';

  @override
  String transferBackupKept(String path) {
    return '原文件已保留在 $path';
  }

  @override
  String agentCompacted(int count) {
    return '已压缩前面 $count 条消息';
  }

  @override
  String agentTruncated(int count) {
    return '更早的 $count 条已省略';
  }

  @override
  String agentToolOutputLines(int count) {
    return '$count 行';
  }

  @override
  String agentPlanUpdatedCollapsed(int count) {
    return '计划已更新（$count 步）';
  }

  @override
  String get agentKnowledgeResolved => '知识提议 · 已处理';

  @override
  String get agentExportMetrics => '导出耗时计量';

  @override
  String get batchApprovalTitle => '需要你批准';

  @override
  String batchApprovalCount(int count) {
    return '$count 条';
  }

  @override
  String get batchApprovalCurrentSession => '当前会话';

  @override
  String get batchApprovalApproveAll => '全部同意';

  @override
  String get batchApprovalDiscard => '取消';

  @override
  String get agentInterruptedTitle => '上次会话被中断';

  @override
  String agentInterruptedRunning(String calls) {
    return '中断时正在执行：\n$calls';
  }

  @override
  String get aiSwitchModel => '切换模型';

  @override
  String get aiModelNoToolSupport => '不支持工具调用';

  @override
  String get aiModelNoApiKey => '未配置 API Key';

  @override
  String get aiModelLeanTools => '精简工具集，不能传文件';

  @override
  String get aiExportSession => '导出会话';

  @override
  String get aiExportPreviewTitle => '导出预览';

  @override
  String aiExportRedacted(int count) {
    return '已脱敏 $count 处';
  }

  @override
  String get aiExportShare => '分享';

  @override
  String get aiExportEmpty => '这段会话还没有可导出的内容';

  @override
  String agentSupersededCollapsed(int count) {
    return '已重发，$count 条已收起';
  }

  @override
  String get agentInterruptedResume => '继续';

  @override
  String get navAI => 'AI';

  @override
  String get navServers => '服务器';

  @override
  String get navSettings => '设置';

  @override
  String get aiGlobalEmptyTitle => '有什么可以帮你？';

  @override
  String get aiGlobalSuggest1 => '解释这段报错';

  @override
  String get aiGlobalSuggest2 => '写一条 shell 命令';

  @override
  String get aiGlobalSuggest3 => '讲讲这个配置文件';

  @override
  String get aiGlobalClearHistory => '清空历史';

  @override
  String get aiRunOnServer => '在服务器上执行…';

  @override
  String get aiGlobalAgentEmptyTitle => '想做点什么？';

  @override
  String get aiGlobalAgentSuggest1 => '哪台机器磁盘快满了';

  @override
  String get aiGlobalAgentSuggest2 => '检查所有机器的负载';

  @override
  String get aiGlobalAgentSuggest3 => '看看 nginx 有没有报错';

  @override
  String get aiGlobalAgentSuggest4 => '把终端字体调大一点';

  @override
  String get aiHomeRecent => '接着上次';

  @override
  String get aiHomeMachines => '机器';

  @override
  String get aiHomeOrAsk => '或者直接问我';

  @override
  String aiHomeMoreMachines(int count) {
    return '+$count';
  }

  @override
  String get relativeTimeJustNow => '刚刚';

  @override
  String aiHomeSuggestDisk(String machine) {
    return '查一下 $machine 的磁盘';
  }

  @override
  String aiHomeSuggestLoad(String machine) {
    return '看下 $machine 的负载';
  }

  @override
  String aiHomeSuggestLogs(String machine) {
    return '看下 $machine 的日志';
  }

  @override
  String get serversScanJobs => '扫描后台任务';

  @override
  String jobsRunningBadge(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个运行中',
    );
    return '$_temp0';
  }

  @override
  String get importPasteTitle => '粘贴导入';

  @override
  String get importPasteHint => '粘贴 ssh config 片段或一行 ssh 命令';

  @override
  String get importPasteAction => '识别';

  @override
  String get importParsedTitle => '已识别';

  @override
  String get importNotRecognized => '没认出服务器信息';

  @override
  String get importFormatExamples =>
      '支持这些格式：\nssh -p 2222 root@example.com\nHost web\n  HostName 10.0.0.5';

  @override
  String get importTryAi => '用 AI 试试';

  @override
  String get importAiFailed => 'AI 也没认出来，请手动填写';

  @override
  String get importStrippedKey => '粘贴内容里的私钥已被忽略，不会发送给任何服务';

  @override
  String get importStrippedPassword => '粘贴内容里的密码行已被忽略';

  @override
  String get importSawInclude => '其中的 Include 引用的配置文件没有被读取';

  @override
  String get importNeedsManualKey => '这台机器用密钥登录，请手动选择一个密钥';

  @override
  String get importPickHost => '识别到多台机器，选一台导入';

  @override
  String get importPickServerForTunnel => '这条转发要绑定到哪台服务器？';

  @override
  String get importApplied => '已填入表单，确认后保存';

  @override
  String get appControlSection => 'app 控制';

  @override
  String appChangeBarLabel(int count) {
    return '本轮改了 $count 项 app 设置';
  }

  @override
  String get appChangeUndo => '撤销';

  @override
  String get appChangeIrreversible => '含不可撤销的改动';

  @override
  String appChangeCardTitle(int count) {
    return 'AI 改了 $count 项 app 设置';
  }

  @override
  String appChangeMore(int count) {
    return '还有 $count 项…';
  }

  @override
  String get appChangeUndone => '已撤销';

  @override
  String get appChangeRestoredNote => '这轮的 app 改动来自更早的会话，已无法撤销';

  @override
  String get appChangeOn => '开';

  @override
  String get appChangeOff => '关';

  @override
  String get appChangeKindServer => '服务器';

  @override
  String get appChangeKindTunnel => '端口转发';

  @override
  String get appChangeKindKey => '按键';

  @override
  String get appChangeKindSession => '会话';

  @override
  String get appChangeKindLayout => '分屏布局';

  @override
  String get appChangeFieldFontFamily => '终端字体';

  @override
  String get appChangeFieldLineHeight => '行高';

  @override
  String get jobBoardTitle => '后台任务';

  @override
  String get jobBoardNoServers => '还没有服务器';

  @override
  String get jobBoardNoJobs => '没有后台任务';

  @override
  String get jobBoardScanFailed => '扫描失败';

  @override
  String get jobBoardRetry => '重试';

  @override
  String jobBoardSkippedEntries(int count) {
    return '$count 个条目无法识别';
  }

  @override
  String get jobBoardRunning => '运行中';

  @override
  String jobBoardExitCode(String code) {
    return '退出码 $code';
  }

  @override
  String get jobBoardLogTimeUnknown => '日志时间未知';

  @override
  String jobBoardLogUpdatedAgo(String ago) {
    return '日志更新于 $ago';
  }

  @override
  String jobBoardLineCount(int count) {
    return '$count 行';
  }

  @override
  String jobBoardReadLogFailed(String error) {
    return '读日志失败：$error';
  }

  @override
  String get jobBoardReadingLog => '读取中…';

  @override
  String get jobBoardKillTooltip => '终止';

  @override
  String get jobBoardCopyJobIdTooltip => '复制 job id';

  @override
  String get jobBoardHandOffTooltip => '让模型接手';

  @override
  String get jobBoardNeedTabTooltip => '需要先连接这台服务器';

  @override
  String get jobBoardCopiedJobId => '已复制 job id';

  @override
  String get jobBoardKillSent => '已发送终止信号';

  @override
  String get jobBoardConfirmKillTitle => '终止这个任务？';

  @override
  String jobBoardConfirmKillContent(String job, String server) {
    return '$server 上的 $job。\n会向整个进程组发 SIGTERM，不可撤销。';
  }

  @override
  String jobBoardHandOffPrompt(String id) {
    return '后台任务 `$id` 还在跑。用 check_job 看它的进展，然后继续处理。';
  }

  @override
  String get timeJustNow => '刚刚';

  @override
  String timeMinutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String timeHoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String timeDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String get timeToday => '今天';

  @override
  String get timeYesterday => '昨天';

  @override
  String timeMonthsAgo(int count) {
    return '$count 个月前';
  }

  @override
  String knownHostFirstSeen(String date, String time) {
    return '首次 $date · 最近 $time';
  }

  @override
  String get fingerprintCopied => '指纹已复制';

  @override
  String get selectionColorFollowTheme => '跟随主题';

  @override
  String get selectionColorBlue => '蓝';

  @override
  String get selectionColorPurple => '紫';

  @override
  String get selectionColorOrange => '橙';

  @override
  String get selectionColorGray => '灰';

  @override
  String get floatingNotConnected => '未连接';

  @override
  String get floatingDisconnected => '已断开';

  @override
  String get floatingGhostMode => '幽灵模式';

  @override
  String get floatingExitGhostMode => '退出幽灵模式';

  @override
  String get fileSaved => '已保存';

  @override
  String fileSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String get fileTooLargeReadonly => '文件过大，仅显示前 512 KB，已禁用保存以防止数据丢失';

  @override
  String get imageDecodeFailed => '无法解码图片';

  @override
  String get browseAction => '浏览';

  @override
  String keyImportFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get keyPassphraseEmptyHint => '留空表示无密码';

  @override
  String get transferFileTitle => '传输文件 (QUIC)';

  @override
  String get transferRemotePathHint => '远端路径（如 ~/upload/file.bin）';

  @override
  String get transferUpload => '上传';

  @override
  String get transferDownload => '下载';

  @override
  String get transferWaiting => '等待中…';

  @override
  String transferFailedWithReason(String error) {
    return '失败：$error';
  }

  @override
  String get transferUnknownError => '未知';

  @override
  String get retry => '重试';

  @override
  String get loading => '加载中…';

  @override
  String settingsConnectionAdvancedSubtitle(
    String compression,
    String keepAlive,
  ) {
    return '压缩 $compression · 保活 $keepAlive';
  }

  @override
  String settingsSecuritySubtitle(String state) {
    return '危险保护 $state';
  }

  @override
  String settingsPrivacySubtitle(String crash, String analytics) {
    return '崩溃上报 $crash · 统计 $analytics';
  }

  @override
  String get refreshLosesSessionTitle => '刷新会丢失会话';

  @override
  String get refreshLosesSessionBody =>
      '当前服务器以 Once 模式运行。刷新会启动新 shell — 原 scrollback、运行中的命令、SHELL 进程都会丢失。\n\n在服务器设置打开 Daemon 模式后，刷新会真正\"恢复\"原会话。';

  @override
  String get dontShowAgain => '不再提示';

  @override
  String get continueRefresh => '继续刷新';

  @override
  String get highRiskCommandTitle => '高风险命令';

  @override
  String get highRiskCommandBody => '此命令可能破坏数据或系统，确认执行？';

  @override
  String get aiExplain => 'AI 解释';

  @override
  String get execute => '执行';

  @override
  String quicConnectFailedHint(String error) {
    return 'QUIC 连接失败：$error\n若需要 SSH 后备，请在 Server 设置中将 Transport 改为 SSH。';
  }

  @override
  String get tmuxNotFoundClosed => '[tmux 未找到，已自动关闭]';

  @override
  String get backAction => '返回';

  @override
  String get sftpRecentPaths => '最近';

  @override
  String get sftpPinnedPaths => '已收藏';

  @override
  String get sftpNoRecentPaths => '暂无历史记录';

  @override
  String get sftpNoPinnedPaths => '暂无收藏 —— 长按一条记录可置顶';

  @override
  String get sftpPathSuggestions => '建议';

  @override
  String get sftpPinPath => '置顶';

  @override
  String get sftpUnpinPath => '取消置顶';

  @override
  String get sftpRemovePath => '从历史中删除';

  @override
  String get agentPermReadOnly => '只读';

  @override
  String get agentPermReadOnlyDesc => 'AI 能看，不能改';

  @override
  String get agentPermAsk => '先问我';

  @override
  String get agentPermAskDesc => '读命令直接跑；改文件攒起来让你一次批准';

  @override
  String get agentPermBypass => '全放行';

  @override
  String get agentPermBypassDesc => '什么都直接做，不问（凭据文件例外）';

  @override
  String get agentPermTitle => 'AI 权限';

  @override
  String agentPermFollowGlobal(String mode) {
    return '跟随全局（$mode）';
  }

  @override
  String get agentPermServerTitle => '此服务器的 AI 权限';

  @override
  String get agentApprovalOnce => '就这一次';

  @override
  String get agentApprovalAlways => '总是允许';

  @override
  String get agentApprovalRulePrefix => '以后都允许';

  @override
  String get agentApprovalReject => '拒绝';

  @override
  String get promptLanguageName => '简体中文';

  @override
  String get aqtPortsLabel => 'UDP 端口';

  @override
  String get aqtPortsHint => '留空使用 61001-61999。可填单个端口或范围，需在服务器防火墙/安全组里放行对应的 UDP 端口。';

  @override
  String get aqtPortsInvalid => '请输入 1024–65535 之间的端口或范围，例如 61001-61999';

  @override
  String get aqtPortRestartTitle => '重启 FlyTerm Server？';

  @override
  String aqtPortRestartBody(String current, String ports, int sessions) {
    return '服务端正在 UDP $current 上运行，不在设置的 $ports 范围内。重启后会改用新端口，但会中断这台服务器上的 $sessions 个 AQT 会话（包括其他设备上的）。';
  }

  @override
  String aqtPortRestartBodyUnknown(String current, String ports) {
    return '服务端正在 UDP $current 上运行，不在设置的 $ports 范围内。重启后会改用新端口，但会中断这台服务器上所有 AQT 会话（包括其他设备上的）。';
  }

  @override
  String get aqtPortRestartConfirm => '重启';

  @override
  String get aqtPortRestartKeep => '继续用当前端口';

  @override
  String aqtFellBackToSsh(String ports) {
    return 'UDP 不可用，已改为经由 SSH 通道连接。放行 UDP $ports 可获得更低延迟。';
  }

  @override
  String get aqtViaSshLabel => '始终走 SSH 通道';

  @override
  String get aqtViaSshDesc => '跳过 UDP 直连，适合只开放 22 端口的服务器或封了 UDP 的网络；延迟略高。';

  @override
  String get aqtRouteViaSshTooltip => 'QUIC · 经由 SSH 通道';

  @override
  String get aqtRelayUnsupported => '服务端版本过旧，不支持 SSH 通道，请升级。';

  @override
  String aqtRelayStartFailed(String error) {
    return '无法建立 SSH 通道：$error';
  }
}

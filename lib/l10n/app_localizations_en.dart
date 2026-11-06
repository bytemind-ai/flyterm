// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'FlyTerm';

  @override
  String get newConnection => 'New Connection';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get save => 'Save';

  @override
  String get add => 'Add';

  @override
  String get edit => 'Edit';

  @override
  String get sftpViewSource => 'View source';

  @override
  String get sftpViewPreview => 'View rendered';

  @override
  String get sftpMarkdownTruncated => 'File is large — showing the first part.';

  @override
  String get required => 'Required';

  @override
  String get confirm => 'OK';

  @override
  String get importAction => 'Import';

  @override
  String get noServers => 'No servers';

  @override
  String get addServer => 'Add Server';

  @override
  String get viaJumpHost => 'Via jump host';

  @override
  String get newSession => 'New Session';

  @override
  String get sftpFileBrowser => 'SFTP File Browser';

  @override
  String get newTunnel => 'New Tunnel';

  @override
  String get deleteServerTitle => 'Delete Server?';

  @override
  String confirmDeleteServer(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String sftpConnectFailed(String error) {
    return 'SFTP connection failed: $error';
  }

  @override
  String get editServer => 'Edit Server';

  @override
  String get newServer => 'New Server';

  @override
  String get labelName => 'Name';

  @override
  String get labelHost => 'Host';

  @override
  String get labelHostHelper =>
      'IPv4, IPv6, or hostname (brackets around IPv6 are optional)';

  @override
  String get labelPort => 'Port';

  @override
  String get addressFamilyLabel => 'Address family';

  @override
  String get addressFamilyAuto => 'Auto (prefer IPv6)';

  @override
  String get addressFamilyIpv4 => 'Force IPv4';

  @override
  String get addressFamilyIpv6 => 'Force IPv6';

  @override
  String get invalidPort => 'Invalid port';

  @override
  String get labelUsername => 'Username';

  @override
  String get labelStartupCommand => 'Command after connect (optional)';

  @override
  String get hintStartupCommand => 'e.g. tmux, cd /var/log';

  @override
  String get authMethod => 'Authentication';

  @override
  String get authPassword => 'Password';

  @override
  String get authSshKey => 'SSH Key';

  @override
  String get labelPassword => 'Password';

  @override
  String get selectKey => 'Select Key';

  @override
  String get keyRequired => 'Please select a key';

  @override
  String get addSshKey => 'Add new key';

  @override
  String get hostKeyTofuTitle => 'First connection — verify host key';

  @override
  String get hostKeyTofuBody =>
      'FlyTerm has not seen this server before. Confirm the fingerprint matches the one your server administrator gave you.';

  @override
  String get hostKeyMismatchTitle => 'Host key changed!';

  @override
  String get hostKeyMismatchBody =>
      'The host\'s key is different from what was stored. This can happen if the server was reinstalled — but it can also be a man-in-the-middle attack. Verify with the administrator before continuing.';

  @override
  String get hostKeyHost => 'Host';

  @override
  String get hostKeyType => 'Key type';

  @override
  String get hostKeyFingerprint => 'Fingerprint (MD5)';

  @override
  String get hostKeyExpected => 'Expected fingerprint';

  @override
  String get hostKeyActual => 'Received fingerprint';

  @override
  String get hostKeyAccept => 'Trust and connect';

  @override
  String get hostKeyAcceptAnyway => 'Connect anyway (replace stored key)';

  @override
  String get hostKeyReject => 'Cancel';

  @override
  String get knownHostsTitle => 'Known Hosts';

  @override
  String get knownHostsEntry => 'Known Hosts';

  @override
  String get knownHostsEntrySubtitle => 'Trusted server fingerprints';

  @override
  String get knownHostsEmpty =>
      'No trusted hosts yet. The first time you connect to a new server you will be asked to confirm its fingerprint.';

  @override
  String get knownHostDelete => 'Delete';

  @override
  String get knownHostDeleteTitle => 'Forget this host?';

  @override
  String get sshCompressionTitle => 'SSH compression';

  @override
  String get sshCompressionDesc =>
      'Use zlib for SSH traffic — large bandwidth savings on slow / metered links. Disable for fast LAN where CPU cost outweighs the gain.';

  @override
  String get backgroundKeepAliveTitle => 'Background keep-alive';

  @override
  String get backgroundKeepAliveDesc =>
      'Keep terminal sessions connected while the app is in the background. The cost is a permanent entry in the notification shade — Android requires foreground services to show one and it cannot be hidden. With this off, sessions drop when you leave the app and server-pushed task notifications won\'t arrive.';

  @override
  String get notificationPermissionTitle => 'Notification permission';

  @override
  String get notificationPermissionGranted => 'Notifications are allowed';

  @override
  String get notificationPermissionDenied =>
      'Notifications are blocked for FlyTerm — task and approval alerts cannot be shown';

  @override
  String get notificationPermissionChannelDisabled =>
      'The “Task Notifications” channel is turned off — alerts cannot be shown';

  @override
  String get notificationPermissionUnknown =>
      'Can\'t determine notification permission on this device';

  @override
  String get notificationPermissionOpenSettings => 'Open system settings';

  @override
  String get notificationPermissionRequest => 'Allow notifications';

  @override
  String get notifySessionGone => 'That session is no longer open';

  @override
  String knownHostDeleteBody(String host) {
    return 'FlyTerm will ask to confirm the fingerprint again on the next connection to $host.';
  }

  @override
  String get tmuxAutoRecover => 'tmux Auto-Recovery';

  @override
  String get tmuxAutoRecoverDesc =>
      'Restore terminal session on reconnect; requires tmux on server';

  @override
  String get transport => 'Transport';

  @override
  String get transportRecommended => 'recommended';

  @override
  String get useTmux => 'Use tmux (process persistence)';

  @override
  String get useTmuxDesc =>
      'Only needed if PTY must survive the remote server restarting';

  @override
  String get useDaemon => 'Daemon mode (long-running on remote)';

  @override
  String get useDaemonDesc =>
      'Enables cross-SSH-session continuation; explicit error on start failure (strict)';

  @override
  String get useMosh => 'Use Mosh';

  @override
  String get moshDesc =>
      'UDP connection with roaming; requires mosh-server on server';

  @override
  String get moshNotSupportedWithJump =>
      'Mosh does not support jump hosts — change transport or disable jump host';

  @override
  String get moshPortRange => 'Mosh Port Range';

  @override
  String get moshPortRangeFormat => 'Format: start:end';

  @override
  String get moshPortMustBeInt => 'Ports must be integers';

  @override
  String get moshStartBeforeEnd => 'Start port must be less than end port';

  @override
  String get useJumpHost => 'Use Jump Host';

  @override
  String get useJumpHostDesc => 'Connect through another server';

  @override
  String get selectJumpServer => 'Select Jump Server';

  @override
  String get jumpServerRequired => 'Please select a jump server';

  @override
  String get addJumpServer => 'Add Jump Server';

  @override
  String get sectionConnection => 'Connection';

  @override
  String get sectionAccount => 'Account';

  @override
  String get sectionAppearance => 'Appearance';

  @override
  String get sectionInput => 'Input';

  @override
  String get sectionSecurity => 'Security';

  @override
  String get sectionAbout => 'About';

  @override
  String get appearanceSettingsTitle => 'Appearance';

  @override
  String get connectionAdvancedTitle => 'Advanced Connection';

  @override
  String get securitySettingsTitle => 'Security';

  @override
  String get aboutTitle => 'About';

  @override
  String keybarCount(int count) {
    return '$count items';
  }

  @override
  String get enabled => 'Enabled';

  @override
  String get disabled => 'Disabled';

  @override
  String get sectionAI => 'AI';

  @override
  String get sectionData => 'Data & Privacy';

  @override
  String get settings => 'Settings';

  @override
  String get sshKeys => 'SSH Keys';

  @override
  String get sshKeysSubtitle => 'Manage SSH key pairs';

  @override
  String get aiProviders => 'AI Providers';

  @override
  String get aiProvidersSubtitle => 'Configure AI API keys';

  @override
  String get tunnels => 'Tunnels';

  @override
  String tunnelCountBadge(int count) {
    return '$count tunnels';
  }

  @override
  String get aiErrorHint => 'AI Error Analysis';

  @override
  String get aiErrorHintDesc => 'Suggest AI analysis on errors';

  @override
  String get terminalFontSize => 'Terminal Font Size';

  @override
  String get terminalCursorStyle => 'Cursor Style';

  @override
  String get terminalCursorStyleDefault => 'Default';

  @override
  String get terminalCursorStyleVerticalBar => 'Vertical bar';

  @override
  String get terminalCursorStyleBlock => 'Block';

  @override
  String get terminalCursorStyleUnderline => 'Underline';

  @override
  String get dangerousCommandGuard => 'Dangerous Command Guard';

  @override
  String get dangerousCommandGuardDesc =>
      'Prompt for confirmation when typing high-risk commands like rm -rf or dd';

  @override
  String get commandCompletionTitle => 'Command completion';

  @override
  String get commandCompletionSubtitle =>
      'Suggest commands from history and the remote shell. Runs locally — no AI provider needed.';

  @override
  String get noKeys => 'No keys';

  @override
  String get copyPublicKey => 'Copy Public Key';

  @override
  String get addKey => 'Add Key';

  @override
  String get publicKeyCopied => 'Public key copied to clipboard';

  @override
  String get deleteKeyTitle => 'Delete Key?';

  @override
  String confirmDeleteKey(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get generateEd25519 => 'Generate Ed25519 Key';

  @override
  String get generateRsa4096 => 'Generate RSA 4096 Key';

  @override
  String get importFromPem => 'Import from PEM';

  @override
  String get keyName => 'Key Name';

  @override
  String get keyNameHint => 'e.g. my-macbook';

  @override
  String get pastePem => 'Paste private key (PEM format)';

  @override
  String get noProviders => 'No AI providers';

  @override
  String get setDefault => 'Set as default';

  @override
  String get addProvider => 'Add Provider';

  @override
  String get deleteProviderTitle => 'Delete Provider?';

  @override
  String confirmDeleteProvider(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get editProvider => 'Edit Provider';

  @override
  String get displayName => 'Display name';

  @override
  String get providerType => 'Provider type';

  @override
  String get model => 'Model';

  @override
  String get baseUrl => 'Base URL (optional)';

  @override
  String get apiKey => 'API Key';

  @override
  String get apiKeyEditHint => 'API Key (leave blank to keep existing)';

  @override
  String get extrasJson => 'Extra Parameters (JSON, optional)';

  @override
  String get invalidJson => 'Enter a valid JSON object';

  @override
  String get setAsDefault => 'Set as default provider';

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
  String get providerModelVolatileHint =>
      'Model IDs change. If the API reports an unknown model, check the provider\'s console for the current name.';

  @override
  String get noTunnels => 'No tunnels';

  @override
  String get tapPlusToAdd => 'Tap + to create one';

  @override
  String get reconnect => 'Reconnect';

  @override
  String get deleteTunnelTitle => 'Delete Tunnel?';

  @override
  String confirmDeleteTunnel(String name) {
    return 'Delete \"$name\" and its saved config?';
  }

  @override
  String get disableAutoConnect => 'Disable Auto-Connect';

  @override
  String get enableAutoConnect => 'Enable Auto-Connect';

  @override
  String get startTunnel => 'Start';

  @override
  String get stopTunnel => 'Stop';

  @override
  String get deleteConfig => 'Delete Config';

  @override
  String get tunnelStatusActive => 'Active';

  @override
  String get tunnelStatusConnecting => 'Connecting…';

  @override
  String tunnelStatusReconnecting(int count, int max) {
    return 'Reconnecting ($count/$max)…';
  }

  @override
  String get tunnelStatusFailed => 'Failed';

  @override
  String get tunnelStatusError => 'Error';

  @override
  String get tunnelStatusStopped => 'Stopped';

  @override
  String get selectServer => 'Select server';

  @override
  String get tunnelDirLocal => 'Local';

  @override
  String get tunnelDirRemote => 'Remote';

  @override
  String get tunnelDescLocal =>
      'Phone port → Server port (access remote services)';

  @override
  String get tunnelDescRemote =>
      'Server port → Phone port (expose local services)';

  @override
  String get tunnelDescSocks5 =>
      'Start SOCKS5 proxy on phone port (traffic via SSH)';

  @override
  String get labelLocalPort => 'Local Port (phone)';

  @override
  String get invalidTunnelPort => 'Enter a valid port (1–65535)';

  @override
  String get labelRemoteHost => 'Remote Host';

  @override
  String get labelRemotePort => 'Remote Port';

  @override
  String get labelTunnelLabel => 'Label (optional)';

  @override
  String get hintTunnelLabel => 'e.g. MySQL 3306';

  @override
  String get autoStartTunnel => 'Auto-Connect on Start';

  @override
  String get autoStartTunnelDesc => 'Auto-reconnect this tunnel on app launch';

  @override
  String get submitOnce => 'One-time';

  @override
  String get submitSaveAndStart => 'Save & Start';

  @override
  String tunnelFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get pleaseSelectServer => 'Please select a server';

  @override
  String get errorDetected => 'Error detected, AI can help analyze';

  @override
  String get aiAnalyze => 'AI Analysis';

  @override
  String get aiAnalyzeError => 'Help me analyze this error in the terminal';

  @override
  String get aiAnalyzeErrorChip => 'Analyze error';

  @override
  String moshFallback(String message) {
    return 'Mosh fell back to SSH: $message';
  }

  @override
  String get reconnectInProgress => 'Reconnecting...';

  @override
  String get refreshing => 'Refreshing...';

  @override
  String get reconnectSuccess => 'Reconnected';

  @override
  String reconnectFailedWithError(String error) {
    return 'Reconnect failed: $error';
  }

  @override
  String get reconnectErrTimeout => 'Connection timed out';

  @override
  String get reconnectErrRefused => 'Connection refused';

  @override
  String get reconnectErrReset => 'Connection reset';

  @override
  String get reconnectErrUnreachable => 'Network unreachable';

  @override
  String get reconnectErrDns => 'DNS lookup failed';

  @override
  String get reconnectErrAuth => 'Authentication failed';

  @override
  String get reconnectErrPermission => 'Permission denied';

  @override
  String get reconnectErrSocket => 'Network error';

  @override
  String reconnectRetryCountdown(
    int seconds,
    int round,
    int attempt,
    int total,
  ) {
    return 'Retrying in ${seconds}s (round $round $attempt/$total)...';
  }

  @override
  String get reconnectNetworkUnstableRetry =>
      'Network unstable, retrying in 30s';

  @override
  String reconnectCascadeWarning(String protocol, int count, int minutes) {
    return '$protocol: reconnected $count times within $minutes minutes. Network may be unstable.';
  }

  @override
  String reconnectLoopDetected(String protocol) {
    return '$protocol: reconnect loop detected. Auto reconnect stopped. Refresh manually.';
  }

  @override
  String get reconnectMoshHandshake => 'Mosh handshaking...';

  @override
  String get reconnectMoshConnected => 'Mosh SSP connected';

  @override
  String get reconnectMoshFallback => 'Mosh fallback to SSH';

  @override
  String reconnectMoshFallbackWithReason(String reason) {
    return 'Mosh fallback to SSH: $reason';
  }

  @override
  String get reconnectMoshDisconnectedRestoring =>
      'Mosh disconnected, restoring session...';

  @override
  String get reconnectMoshSessionRestored => 'Mosh session restored';

  @override
  String get reconnectMoshRestoreFailedRehandshake =>
      'Mosh session restore failed, handshaking again...';

  @override
  String get tmuxNotFoundDisabled => 'tmux not found, disabled automatically';

  @override
  String get enterPassword => 'Enter Password';

  @override
  String get split => 'Split';

  @override
  String get tabMove => 'Move';

  @override
  String get splitVertical => 'Top-Bottom Split';

  @override
  String get splitHorizontal => 'Left-Right Split';

  @override
  String get layoutPickerTitle => 'Split';

  @override
  String get layoutSingle => 'Single';

  @override
  String layoutWithCurrent(String state) {
    return 'Split · $state';
  }

  @override
  String get closeSplit => 'Close Split';

  @override
  String get floatTerminal => 'Float Terminal';

  @override
  String get closeFloat => 'Close Float';

  @override
  String get saveFavoriteDialogTitle => 'Save Command';

  @override
  String get favoriteCommandNameLabel => 'Command Name';

  @override
  String get commandSaved => 'Command saved';

  @override
  String get notConnected => 'Not connected';

  @override
  String get back => 'Back';

  @override
  String connectingTo(String host) {
    return 'Connecting to $host…';
  }

  @override
  String get voiceUnavailable => 'Voice input is currently unavailable';

  @override
  String get voicePermissionTitle => 'Enable Voice Input';

  @override
  String get voiceMicrophonePermissionContent =>
      'Voice input needs microphone permission. Allow FlyTerm to use the microphone in system settings.';

  @override
  String get voiceSpeechPermissionContent =>
      'On iPhone/iPad, voice input also needs Speech Recognition permission. Allow FlyTerm to use Speech Recognition in system settings.';

  @override
  String get voiceRecognizerUnavailableContent =>
      'Microphone permission was checked, but the system speech recognition service is unavailable or disabled. Enable system voice input / voice assistant, or install Google app / a system speech service and try again. If that still doesn\'t work, most keyboards have their own microphone key — it uses the keyboard\'s own recognition, independent of this app.';

  @override
  String get voiceNoSpeechContent =>
      'No speech was detected. Make sure the system microphone toggle is on, this device has a working microphone, and no other app is using it.';

  @override
  String get voiceBusyContent => 'Speech recognition is busy. Try again later.';

  @override
  String get voiceNetworkContent =>
      'Speech recognition needs network access. Check your connection and try again.';

  @override
  String get voiceUnknownContent =>
      'Voice input is temporarily unavailable. Check microphone permission and the system speech recognition service, then try again.';

  @override
  String get voiceOpenSettings => 'Open Settings';

  @override
  String get voiceRetry => 'Check Again';

  @override
  String get voiceLater => 'Later';

  @override
  String get voiceErrorTitle => 'Voice Input Failed';

  @override
  String get voiceErrorHint =>
      'You can select and copy the text below to report this issue:';

  @override
  String get voiceCopyDiagnostics => 'Copy Diagnostics';

  @override
  String get voiceDiagnosticsCopied => 'Copied';

  @override
  String sftpSaved(String name) {
    return 'Saved: $name';
  }

  @override
  String sftpSymlinkTarget(String target) {
    return '→ $target';
  }

  @override
  String get sftpSymlinkDangling => 'Link target does not exist';

  @override
  String get sftpErrPermissionDenied =>
      'Permission denied. Check the file\'s permissions.';

  @override
  String get sftpErrNotFound =>
      'Path does not exist. It may have been moved or deleted.';

  @override
  String get sftpErrDiskFull => 'Not enough space on the remote host.';

  @override
  String get sftpErrDisconnected => 'Connection lost. Reconnect and try again.';

  @override
  String get sftpErrAlreadyExists => 'A file with this name already exists.';

  @override
  String get sftpErrRawDetail => 'Details';

  @override
  String downloadSavedToPublic(String path) {
    return 'Saved to $path';
  }

  @override
  String get open => 'Open';

  @override
  String sftpDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get sftpBatchSelect => 'Batch Select';

  @override
  String get sftpDownloadFolder => 'Download Folder';

  @override
  String get sftpDownload => 'Download';

  @override
  String get sftpOpenWithSystem => 'Open with another app';

  @override
  String sftpConfirmLargeOpen(String name, String size) {
    return '$name is $size. Download it and open with another app?';
  }

  @override
  String sftpOpeningFile(String name) {
    return 'Downloading $name…';
  }

  @override
  String get rename => 'Rename';

  @override
  String get permissions => 'Permissions';

  @override
  String get sftpNewName => 'New Name';

  @override
  String sftpConfirmDeleteEntry(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get sftpNewFolderTitle => 'New Folder';

  @override
  String get sftpFolderName => 'Folder Name';

  @override
  String get sftpNewFileTitle => 'New File';

  @override
  String get sftpFileName => 'File Name';

  @override
  String get sftpJumpToPath => 'Jump to Path';

  @override
  String get create => 'Create';

  @override
  String get jump => 'Jump';

  @override
  String get apply => 'Apply';

  @override
  String sftpPermissionsTitle(String name) {
    return 'Permissions — $name';
  }

  @override
  String get sftpOwner => 'Owner';

  @override
  String get sftpGroup => 'Group';

  @override
  String get sftpOther => 'Other';

  @override
  String get sftpRead => 'Read';

  @override
  String get sftpWrite => 'Write';

  @override
  String get sftpExecute => 'Exec';

  @override
  String sftpSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get sftpSelectAll => 'Select All';

  @override
  String sftpSelectedItems(int count) {
    return '$count items selected';
  }

  @override
  String sftpScanningFiles(int count) {
    return 'Scanning... $count files found';
  }

  @override
  String sftpUploading(String filename) {
    return 'Uploading $filename';
  }

  @override
  String get sftpEmptyDirectory => 'Empty Directory';

  @override
  String sftpRenameFailed(String error) {
    return 'Rename failed: $error';
  }

  @override
  String sftpDeleteFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String sftpCreateFailed(String error) {
    return 'Create failed: $error';
  }

  @override
  String sftpChmodFailed(String error) {
    return 'chmod failed: $error';
  }

  @override
  String sftpDownloadsCompleted(int count) {
    return '$count download(s) complete';
  }

  @override
  String sftpConfirmDeleteSelected(int count) {
    return 'Delete $count selected items? This cannot be undone.';
  }

  @override
  String get sftpCreateFolderAction => 'New Directory';

  @override
  String get sftpCreateFileAction => 'New File';

  @override
  String get sftpUploadFileAction => 'Upload File';

  @override
  String get sftpUploadFolderAction => 'Upload folder';

  @override
  String sftpConflictTitle(int count) {
    return '$count file(s) already exist';
  }

  @override
  String get sftpConflictBody =>
      'Uploading will overwrite them. This cannot be undone.';

  @override
  String get sftpConflictOverwriteAll => 'Overwrite all';

  @override
  String get sftpConflictSkipAll => 'Skip existing';

  @override
  String sftpConflictSkipped(int count) {
    return 'Skipped $count existing file(s)';
  }

  @override
  String get aiAssistant => 'AI Assistant';

  @override
  String get aiMicUnavailableTitle => 'Voice Input Unavailable';

  @override
  String get aiMicUnavailableContent =>
      'Microphone permission not granted or device does not support speech recognition.\n\nGo to phone Settings → Apps → FlyTerm → Permissions, enable microphone, then reopen the app.';

  @override
  String get aiNoProvider =>
      'No AI provider configured. Go to Settings → AI Providers to add one.';

  @override
  String get aiEmptyHint =>
      'Describe the operation you want to perform, AI will generate a command for one-tap execution.\n\nExample: Find the process using the most memory';

  @override
  String get aiGoConfig => 'Configure →';

  @override
  String get aiListeningHint => 'Listening…';

  @override
  String get aiInputHint => 'Describe operation or ask a question…';

  @override
  String get aiClearHistory => 'Clear conversation';

  @override
  String get aiNewSession => 'New session';

  @override
  String get aiMoreActions => 'More actions';

  @override
  String get aiSessionHistory => 'History';

  @override
  String get aiHistoryEmpty => 'No archived sessions yet';

  @override
  String get aiHistorySearchHint => 'Search titles';

  @override
  String get aiHistoryNoMatch => 'No sessions match';

  @override
  String aiHistoryQuotaHint(int keep) {
    return 'Most recent $keep per server; starred are kept beyond that.';
  }

  @override
  String aiHistoryEvents(int count) {
    return '$count entries';
  }

  @override
  String get aiHistoryUntitled => '(untitled)';

  @override
  String get aiHistoryDeleteTitle => 'Delete this session?';

  @override
  String get aiHistoryDelete => 'Delete';

  @override
  String get aiCopyAction => 'Copy';

  @override
  String get aiMessageCopied => 'Copied';

  @override
  String get aiRetryAction => 'Retry';

  @override
  String get aiEditAction => 'Edit';

  @override
  String get aiExplainAction => 'Explain';

  @override
  String get aiSaveAction => 'Save';

  @override
  String get aiRunAction => 'Run';

  @override
  String get aiCommandFailed => 'Command failed';

  @override
  String aiOutputLines(int count) {
    return '$count lines';
  }

  @override
  String get aiGotIt => 'Got it';

  @override
  String get favoritesTitle => 'Favorites';

  @override
  String get addFavoriteTooltip => 'Add Favorite';

  @override
  String get noFavorites => 'No saved commands\nTap + to add';

  @override
  String get editFavoriteTitle => 'Edit Favorite Command';

  @override
  String get addFavoriteTitle => 'Add Favorite Command';

  @override
  String get favoriteName => 'Name';

  @override
  String get favoriteNameHint => 'e.g. Update System';

  @override
  String get favoriteCommand => 'Command';

  @override
  String get favoriteCommandHint => 'Supports template variables';

  @override
  String get favoriteRun => 'Run';

  @override
  String get favoriteAiEnabled => 'Let the assistant run this';

  @override
  String get favoriteAiEnabledHint =>
      'The assistant will see this command\'s name and template';

  @override
  String favoriteAiBudget(int count, int tokens) {
    return '$count available to the assistant, about $tokens tokens per request';
  }

  @override
  String favoriteAiOverflow(int count) {
    return '$count are over the limit and will not be offered';
  }

  @override
  String get sftpDownloadDir => 'Download Directory';

  @override
  String get sftpDownloadDirDownloads =>
      'Downloads (public, visible in Files app)';

  @override
  String get sftpDownloadDirDocuments => 'Documents';

  @override
  String get sftpDownloadDirCustom => 'Custom Path';

  @override
  String get sftpCustomPathHint => 'e.g. /storage/emulated/0/MyFolder';

  @override
  String get searchServers => 'Search servers…';

  @override
  String get noSearchResults => 'No matching servers';

  @override
  String get serverGroup => 'Group (optional)';

  @override
  String get close => 'Close';

  @override
  String get terminalTheme => 'Terminal Theme';

  @override
  String get terminalThemeDefault => 'Default Dark';

  @override
  String get terminalThemeDracula => 'Dracula';

  @override
  String get terminalThemeSolarizedDark => 'Solarized Dark';

  @override
  String get terminalThemeMonokai => 'Monokai';

  @override
  String get terminalThemeSolarizedLight => 'Solarized Light';

  @override
  String get terminalThemeNord => 'Nord';

  @override
  String get terminalThemeGruvboxDark => 'Gruvbox Dark';

  @override
  String get terminalThemeOneDark => 'One Dark';

  @override
  String get terminalThemeTokyoNight => 'Tokyo Night';

  @override
  String get cursorBlink => 'Blinking Cursor';

  @override
  String get cursorBlinkSubtitle =>
      'Blink the cursor when the terminal has focus';

  @override
  String get selectionColor => 'Selection Color';

  @override
  String get selectionColorSubtitle => 'Highlight color for selected text';

  @override
  String get keybarCustomize => 'KeyBar Customization';

  @override
  String get keybarCustomizeSubtitle => 'Reorder, edit, or add keys';

  @override
  String get fetSettingsTitle => 'SFTP Toggle Button';

  @override
  String get fetSettingsSubtitle =>
      'Floating button to switch terminal / SFTP view';

  @override
  String get fetSettingsShow => 'Show toggle button';

  @override
  String get fetSettingsShowSubtitle =>
      'Floating button on the right side of the terminal';

  @override
  String get fetSettingsAutoHide => 'Auto-hide to edge';

  @override
  String get fetSettingsAutoHideSubtitle =>
      'Collapses to a thin bar after 7 s of inactivity';

  @override
  String get fetSettingsOpacity => 'Opacity';

  @override
  String get fetSettingsResetPosition => 'Reset position';

  @override
  String get fetSettingsResetPositionSubtitle =>
      'Return button to centre of screen';

  @override
  String get fetSettingsResetDone => 'Toggle button position reset';

  @override
  String get sftpSwitchToSftp => 'Switch to SFTP';

  @override
  String get sftpSwitchToTerminal => 'Back to Terminal';

  @override
  String get sftpOnboardingHint =>
      'Tap to switch SFTP/terminal, drag to reposition, fling right to hide';

  @override
  String get keybarLongPressEdit => 'Edit';

  @override
  String get keybarLongPressDelete => 'Delete';

  @override
  String get keybarEmptyHint =>
      'Long-press a key or open Settings → KeyBar to add keys';

  @override
  String get keybarEditorTitle => 'KeyBar Customization';

  @override
  String get keybarEditorAddTooltip => 'Add new key';

  @override
  String get keybarEditorRestoreDefaults => 'Restore defaults';

  @override
  String get keybarEditorConfirmRestoreTitle => 'Restore default KeyBar?';

  @override
  String get keybarEditorConfirmRestoreBody =>
      'All custom keys will be removed.';

  @override
  String get keybarEditorConfirmRestoreOk => 'Restore';

  @override
  String get keybarEditorConfirmRestoreCancel => 'Cancel';

  @override
  String get keybarEditItemTitle => 'Edit Key';

  @override
  String get keybarEditItemNew => 'New Key';

  @override
  String get keybarEditItemLabel => 'Label';

  @override
  String get keybarEditItemSequence => 'Sequence';

  @override
  String get keybarEditItemInsertSpecial => 'Insert special key';

  @override
  String get keybarEditItemRepeatable => 'Long-press auto-repeat';

  @override
  String get keybarEditItemSave => 'Save';

  @override
  String get keybarEditItemValidationLabel => 'Label cannot be empty';

  @override
  String get keybarEditItemValidationSequence => 'Sequence cannot be empty';

  @override
  String get keybarSpecialPickerTitle => 'Insert Special Key';

  @override
  String get keybarSpecialCategoryControl => 'Control';

  @override
  String get keybarSpecialCategoryModifiers => 'Modifiers';

  @override
  String get keybarSpecialCategoryArrows => 'Arrows';

  @override
  String get keybarSpecialCategoryNav => 'Navigation';

  @override
  String get keybarSpecialCategoryModifierCombos => 'Modifier Combos';

  @override
  String get keybarSpecialCategoryFunction => 'Function Keys';

  @override
  String get keybarSpecialCategoryCtrl => 'Ctrl Combos';

  @override
  String get keybarEditItemSequenceHint => 'Type text…';

  @override
  String get keybarEditItemSticky => 'Sticky modifier (CTRL-style)';

  @override
  String get keybarEditItemStickyHint =>
      'Toggles a transient flag instead of sending bytes; the next keypress is sent with Ctrl applied.';

  @override
  String get keybarCtrlNotApplicable => 'CTRL doesn\'t apply to this key';

  @override
  String get keybarShiftNotApplicable => 'SHIFT doesn\'t apply to this key';

  @override
  String get keybarEditorSectionKeyboardMode => 'Keyboard Show';

  @override
  String get keybarEditorSectionLeftKeys => 'Terminal Keys';

  @override
  String get keybarEditorSectionRightButtons => 'Function Buttons';

  @override
  String get keybarRightButtonKeyboard => 'Keyboard';

  @override
  String get keybarRightButtonFavorites => 'Favorites';

  @override
  String get keybarRightButtonMicrophone => 'Microphone';

  @override
  String get keybarRightButtonAi => 'AI';

  @override
  String get keybarRightButtonAttachFile => 'Attach';

  @override
  String get attachFileNoConnection =>
      'Connection unavailable — reconnect and try again';

  @override
  String get attachFileNameTaken =>
      'Too many files with that name — clean up first';

  @override
  String attachFileFailed(String error) {
    return 'Upload failed: $error';
  }

  @override
  String attachFileRenamed(String name) {
    return 'Name had special characters — renamed to $name';
  }

  @override
  String get agentForwarding => 'SSH Agent Forwarding';

  @override
  String get agentForwardingDesc =>
      'Allow remote host to use local keys for next-hop auth';

  @override
  String get importConfigPreviewSkills => 'AI skills';

  @override
  String get exportConfigSubject => 'FlyTerm config backup';

  @override
  String exportConfigDone(String path) {
    return 'Exported: $path';
  }

  @override
  String exportConfigFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String importConfigFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String importConfigDone(int count) {
    return 'Imported $count items';
  }

  @override
  String get exportConfigEmpty => '(empty config)';

  @override
  String get exportConfigIncludeAi => 'Include AI provider config';

  @override
  String get exportConfigIncludeAiDesc =>
      'Turn off to exclude provider config (API keys are never backed up)';

  @override
  String get exportConfigIncludeKnowledge => 'Include AI knowledge & notes';

  @override
  String get exportConfigIncludeKnowledgeDesc =>
      'Skill library and per-machine agent notes. May be large';

  @override
  String get importConfigKeepAppearance => 'Keep my current appearance';

  @override
  String get importConfigKeepAppearanceDesc =>
      'Do not overwrite theme, font, or KeyBar layout';

  @override
  String get importConfigPreviewSshKeysNotIncluded =>
      'SSH private keys are not in the backup — re-import them after this to connect with those keys';

  @override
  String exportConfigCountServers(int count) {
    return '$count servers';
  }

  @override
  String exportConfigCountKeys(int count) {
    return '$count keys';
  }

  @override
  String exportConfigCountFavCmds(int count) {
    return '$count favorites';
  }

  @override
  String exportConfigCountAi(int count) {
    return '$count AI configs';
  }

  @override
  String exportConfigCountTunnels(int count) {
    return '$count tunnels';
  }

  @override
  String exportConfigCountKnownHosts(int count) {
    return '$count known hosts';
  }

  @override
  String exportConfigCountNotes(int count) {
    return '$count machine notes';
  }

  @override
  String exportConfigCountSkills(int count) {
    return '$count AI skills';
  }

  @override
  String get exportConfig => 'Export Config';

  @override
  String get exportConfigSubtitle => 'Save servers & keys to a JSON file';

  @override
  String get importConfig => 'Import Config';

  @override
  String get importConfigSubtitle => 'Restore from a previously exported JSON';

  @override
  String get exportConfigSendToDevice => 'Send to another device';

  @override
  String get exportConfigSaveLocal => 'Save to downloads';

  @override
  String get exportConfigHasAiKeys =>
      '⚠ AI API keys are NOT exported — re-enter them after importing';

  @override
  String get importConfigPreviewKnownHosts => 'Known Hosts';

  @override
  String get importConfigPreviewKeybarWarning =>
      '⚠ The on-screen key bar will be overwritten';

  @override
  String get importConfigPreviewAiKeysNotIncluded =>
      '⚠ AI API keys are not included — re-enter them after importing';

  @override
  String get exportConfigNeverBackedUp => 'Never backed up';

  @override
  String exportConfigLastBackup(String timeAgo) {
    return 'Last backup: $timeAgo';
  }

  @override
  String get importConfigPreviewTitle => 'Import Preview';

  @override
  String get importConfigPreviewServers => 'Servers';

  @override
  String get importConfigPreviewKeys => 'SSH Keys';

  @override
  String get importConfigPreviewFavCmds => 'Favorites';

  @override
  String get importConfigPreviewAiProviders => 'AI Configs';

  @override
  String get importConfigPreviewTunnels => 'Tunnels';

  @override
  String importConfigPreviewNew(int count) {
    return '$count (all new)';
  }

  @override
  String importConfigPreviewWithSkip(int newCount, int skipCount) {
    return '$newCount new, $skipCount duplicate(s) skipped';
  }

  @override
  String get importConfigPreviewSettingsWarning =>
      '⚠ Terminal settings (theme, font size) will be overwritten';

  @override
  String get importConfigConfirm => 'Import';

  @override
  String importConfigSuccessWithSkip(int newCount, int skipCount) {
    return 'Imported $newCount items, $skipCount duplicate(s) skipped';
  }

  @override
  String get sessionSummary => 'Session Summary';

  @override
  String get sessionSummaryPrompt =>
      'Please summarize what was done in this terminal session: key commands run, what succeeded or failed, and the current state.';

  @override
  String get sftpSearchHint => 'Search files…';

  @override
  String get sftpSortByName => 'Sort by name';

  @override
  String get sftpSortBySize => 'Sort by size';

  @override
  String get sftpSortByTime => 'Sort by time';

  @override
  String get sftpSortAscending => 'Ascending';

  @override
  String get sftpSortDescending => 'Descending';

  @override
  String get sftpSortToggleToDesc => 'Switch to descending';

  @override
  String get sftpSortToggleToAsc => 'Switch to ascending';

  @override
  String get sftpSortDirectionLabel => 'Order';

  @override
  String get sftpSortTooltip => 'Sort';

  @override
  String sftpResuming(String filename) {
    return 'Resuming $filename';
  }

  @override
  String get tabRefresh => 'Refresh';

  @override
  String get version => 'Version';

  @override
  String versionSubtitleDebugActive(String version) {
    return '$version · Debug panel active (tap repeatedly to toggle)';
  }

  @override
  String get debugOverlayEnabled => 'Debug panel enabled';

  @override
  String get debugOverlayDisabled => 'Debug panel disabled';

  @override
  String debugOverlayTapsRemaining(int count) {
    return 'Tap $count more to toggle debug panel';
  }

  @override
  String get keyboardTrigger => 'Keyboard Trigger';

  @override
  String get keyboardTriggerSingleTap => 'Single Tap';

  @override
  String get keyboardTriggerSingleTapDesc =>
      'Tap the terminal area to open keyboard';

  @override
  String get keyboardTriggerDoubleTap => 'Double Tap';

  @override
  String get keyboardTriggerDoubleTapDesc =>
      'Double-tap the terminal area to open keyboard';

  @override
  String get keyboardTriggerIconButton => 'Icon Button';

  @override
  String get keyboardTriggerIconButtonDesc =>
      'Tap toolbar keyboard icon to open keyboard';

  @override
  String get selectionCopy => 'Copy';

  @override
  String selectionCopied(int count) {
    return 'Copied $count characters';
  }

  @override
  String get selectionExpired => 'Selection is no longer valid — select again';

  @override
  String get selectionSelect => 'Select';

  @override
  String get selectionPaste => 'Paste';

  @override
  String get pasteClipboardEmpty => 'Clipboard is empty';

  @override
  String get pasteNotConnected => 'Not connected — cannot paste';

  @override
  String pasteTooLarge(String size) {
    return 'Clipboard content too large ($size) — paste cancelled';
  }

  @override
  String get fontSection => 'Terminal Font';

  @override
  String get fontSize => 'Size';

  @override
  String get codeFont => 'Code Font';

  @override
  String get codeFontDesc => 'Letters, digits, and symbols';

  @override
  String get fontFamilySystem => 'System default';

  @override
  String get lineHeight => 'Line Spacing';

  @override
  String get lineHeightDesc =>
      'Space between lines (larger = more breathing room)';

  @override
  String get serverTypeSshMosh => 'SSH / Mosh';

  @override
  String get serverTypeRemote => 'Remote';

  @override
  String get serverTypeLocal => 'Local';

  @override
  String get localShellUnsupported =>
      'Local terminal is not available on this platform — connect to a remote server instead.';

  @override
  String get ungrouped => 'Other';

  @override
  String get consentTitle => 'Welcome to FlyTerm';

  @override
  String get consentIntro => 'Before using the App, please read and agree to:';

  @override
  String get consentPrivacyLink => 'Privacy Policy';

  @override
  String get consentTosLink => 'Terms of Service';

  @override
  String get consentCrashOptIn =>
      'Send crash reports to help fix bugs (toggle in Settings)';

  @override
  String get consentAcceptButton => 'Agree and Continue';

  @override
  String get consentDeclineButton => 'Decline and Exit';

  @override
  String get privacyPolicyTitle => 'Privacy Policy';

  @override
  String get termsOfServiceTitle => 'Terms of Service';

  @override
  String get privacyPreferences => 'Privacy Preferences';

  @override
  String get privacyCrashReportingToggle => 'Crash Reporting';

  @override
  String get privacyCrashReportingDesc =>
      'Upload crash stacks to help fix bugs (scrubbed, no host info)';

  @override
  String get privacyAnalyticsToggle => 'Usage Analytics';

  @override
  String get privacyAnalyticsDesc =>
      'Upload key business events for product improvement';

  @override
  String get privacyViewPolicy => 'View Privacy Policy';

  @override
  String get privacyViewToS => 'View Terms of Service';

  @override
  String get privacyRevokeButton => 'Revoke Consent and Exit App';

  @override
  String get privacyRevokeConfirmTitle => 'Revoke Consent?';

  @override
  String get privacyRevokeConfirmDesc =>
      'Revoking will exit the app; next launch requires re-consent.';

  @override
  String get privacyRevokeConfirmYes => 'Revoke and Exit';

  @override
  String get privacyRevokeConfirmNo => 'Cancel';

  @override
  String get consentSubtitle =>
      'A modern mobile terminal that respects your privacy.';

  @override
  String get consentHighlightKeysTitle => 'Your keys stay on device';

  @override
  String get consentHighlightKeysDesc =>
      'Encrypted in Keychain / Keystore, never uploaded';

  @override
  String get consentHighlightCrashTitle => 'Anonymous crash reports';

  @override
  String get consentHighlightCrashDesc => 'Scrubbed — no host or account info';

  @override
  String get consentHighlightControlTitle => 'Full control anytime';

  @override
  String get consentHighlightControlDesc =>
      'Toggle off crash and analytics in Settings';

  @override
  String get consentAgreeBoilerplate => 'By continuing you agree to our';

  @override
  String get consentAgreeBoilerplateAnd => 'and';

  @override
  String get consentDeclineHint => 'Don\'t agree?';

  @override
  String get consentDeclineExit => 'Exit';

  @override
  String get privacySectionDocuments => 'Documents';

  @override
  String get privacySectionDangerZone => 'Danger Zone';

  @override
  String get privacyRevokeCardDesc =>
      'Revoking exits the app; next launch requires re-consent';

  @override
  String get paywallTitle => 'FlyTerm Pro';

  @override
  String get paywallSubtitle =>
      'One-time purchase, unlock all Pro features forever';

  @override
  String get paywallFeatureQuic => 'QUIC protocol — low latency + roaming';

  @override
  String get paywallFeatureAi => 'AI assist — voice input & error analysis';

  @override
  String get paywallFeatureTunnel => 'Port forwarding / SFTP / Mosh';

  @override
  String get paywallFeatureFutureUpdates => 'All future Pro updates included';

  @override
  String paywallPurchaseButton(String price) {
    return 'Purchase $price';
  }

  @override
  String get paywallRestoreButton => 'Already purchased? Restore';

  @override
  String get paywallContinueLater => 'Maybe later';

  @override
  String get paywallLoadingPrice => 'Loading price…';

  @override
  String get paywallUnavailable => 'Store unavailable, please try later';

  @override
  String get paywallPurchasePending => 'Confirming payment…';

  @override
  String paywallPurchaseError(String error) {
    return 'Purchase failed: $error';
  }

  @override
  String get paywallRestoreNoneFound => 'No purchase found for this account';

  @override
  String get paywallRestoreSuccess => 'Pro unlocked';

  @override
  String get proStatusPro => 'FlyTerm Pro · Active';

  @override
  String get proStatusFree => 'Free';

  @override
  String proStatusPurchasedAt(String date) {
    return 'Purchased on $date';
  }

  @override
  String get proStatusUpgrade => 'Upgrade to Pro';

  @override
  String get proStatusRestore => 'Restore Purchase';

  @override
  String get settingsOpenSourceLicenses => 'Open Source Licenses';

  @override
  String get settingsOpenSourceLicensesSubtitle =>
      'Third-party libraries and their licenses';

  @override
  String get updatePromptTitleOptional => 'Update Available';

  @override
  String get updatePromptTitleMandatory => 'Required Update';

  @override
  String updatePromptBody(Object latest, Object current) {
    return 'Version $latest is available (current: $current).';
  }

  @override
  String get updatePromptReleaseNotes => 'RELEASE NOTES';

  @override
  String get updatePromptUpdate => 'Update';

  @override
  String get updatePromptLater => 'Later';

  @override
  String get agentToolRunning => 'Running';

  @override
  String get agentToolDone => 'Done';

  @override
  String get agentToolFailed => 'Failed';

  @override
  String get agentToolRejected => 'Rejected';

  @override
  String get agentToolAwaiting => 'Awaiting approval';

  @override
  String get agentToolExpand => 'Show output';

  @override
  String get agentToolCollapse => 'Hide';

  @override
  String agentExitCode(int code) {
    return 'exit $code';
  }

  @override
  String get agentApprovalTitle => 'Needs your approval';

  @override
  String get agentAllowOnce => 'Allow once';

  @override
  String get agentSilenceInSession => 'Don\'t ask again this turn';

  @override
  String agentDenyWarning(String provider) {
    return 'This command touches credential files. Allowing it sends their contents to $provider.';
  }

  @override
  String get agentReasonMetachar =>
      'Command contains shell metacharacters — must be confirmed individually';

  @override
  String get agentReasonNoRule => 'No matching allow rule';

  @override
  String get agentReasonFileWrite =>
      'Writes to a file — always needs confirmation';

  @override
  String get agentInstructionsTitle => 'AI assistant notes';

  @override
  String get agentInstructionsEntry => 'Custom instructions';

  @override
  String get agentInstructionsEntrySet => 'Set';

  @override
  String get agentInstructionsEntryEmpty => 'Not set';

  @override
  String get agentInstructionsHint =>
      'Tell the AI how you want it to answer. For example: keep it short; lead with the conclusion; answer in English.\n\nThese notes apply to every server. Anything specific to one machine (uses podman, logs live in /data/logs) belongs in that server\'s notes below, not here.';

  @override
  String get agentInstructionsLocalLabel =>
      'Global notes (shared by all servers, this phone only)';

  @override
  String get agentInstructionsSaved => 'Saved';

  @override
  String agentInstructionsRemaining(int n) {
    return '$n bytes left';
  }

  @override
  String agentInstructionsTooLong(int max) {
    return 'Over the $max byte limit; the excess will not be sent to the AI';
  }

  @override
  String get agentSkillsEntry => 'Skills';

  @override
  String get agentSkillsEntryEmpty => 'None yet';

  @override
  String agentSkillsEntryCount(int count) {
    return '$count saved';
  }

  @override
  String get agentSkillsTitle => 'Skills';

  @override
  String get agentSkillsHint =>
      'Procedures and tool notes the assistant can pull in when relevant. Only the one-line description of each rides along in every request.';

  @override
  String agentSkillsBudget(int count, int tokens) {
    return '$count skills, about $tokens tokens per request';
  }

  @override
  String agentSkillsOverflow(int count) {
    return '$count skills are past the index limit — the model needs to search for them';
  }

  @override
  String get agentSkillsEmpty =>
      'No skills yet. Ask the assistant to save one after it solves something, or import from a server or file.';

  @override
  String get agentSkillsImportFromServer => 'Import from this server';

  @override
  String get agentSkillsImportFromFile => 'Import from a file';

  @override
  String get agentSkillsImportFromFolder => 'Import a skill folder';

  @override
  String get agentSkillsImportFromArchive => 'Import a .zip package';

  @override
  String skillImportAssetCount(int n) {
    return '$n attached file(s)';
  }

  @override
  String get agentSkillsCreateManually => 'Create manually';

  @override
  String get agentSkillsImportTitle => 'Import skills';

  @override
  String get agentSkillsImportNone =>
      'No skills found in ~/.flyterm/skills on this server.';

  @override
  String agentSkillsImportSkipped(int count) {
    return '$count file(s) could not be parsed and were skipped';
  }

  @override
  String get agentSkillsImportConfirm => 'Import selected';

  @override
  String get agentSkillsImportNeedsDescription => 'Add a one-line description';

  @override
  String agentSkillsConflictTitle(String name) {
    return 'A skill named \"$name\" already exists';
  }

  @override
  String get agentSkillsConflictOverwrite => 'Overwrite';

  @override
  String get agentSkillsConflictKeepBoth => 'Keep both';

  @override
  String get agentSkillsConflictSkip => 'Skip';

  @override
  String get agentSkillsSourceAi => 'Written by assistant';

  @override
  String get agentSkillsSourceRemote => 'From server';

  @override
  String get agentSkillsSourceFile => 'From file';

  @override
  String get agentSkillsSourceManual => 'Created manually';

  @override
  String get agentKnowledgeCaptureTitle => 'Offer to save what was learned';

  @override
  String get agentKnowledgeCaptureDesc =>
      'Turns a finished session into a card — save it as a skill or into this machine\'s notes';

  @override
  String get agentSkillDetailTitle => 'Skill';

  @override
  String get agentSkillCreateTitle => 'New skill';

  @override
  String get agentSkillNameLabel => 'Name';

  @override
  String get agentSkillDescriptionLabel =>
      'Description (shown in every request)';

  @override
  String get agentSkillBodyLabel => 'Body';

  @override
  String get agentSkillAssetsLabel =>
      'Attached files (installed on the server by install_skill_assets)';

  @override
  String get agentSkillAssetExecutable =>
      'Executable — marked +x when installed';

  @override
  String get agentSkillAssetData => 'Data file';

  @override
  String get skillAssetAdd => 'Add file';

  @override
  String get skillAssetEdit => 'Edit file';

  @override
  String get skillAssetEmptyHint =>
      'No attached files. Add a script or template if the steps would be identical every time.';

  @override
  String get skillAssetPathLabel => 'Path inside the skill folder';

  @override
  String get skillAssetPathHelper =>
      'Relative, e.g. scripts/check.sh — no leading / and no ..';

  @override
  String get skillAssetPathInvalid =>
      'Must be a relative path with no `..` or backslashes';

  @override
  String get skillAssetExecutableToggle => 'Executable';

  @override
  String get skillAssetExecutableHint =>
      'Marked +x on the server when installed';

  @override
  String get skillAssetContentLabel => 'File contents';

  @override
  String skillAssetTotalTooBig(int bytes, int limit) {
    return 'These files total $bytes bytes; the limit is $limit.';
  }

  @override
  String get agentSkillDelete => 'Delete skill';

  @override
  String get agentSkillDeleteConfirm =>
      'Delete this skill? This cannot be undone.';

  @override
  String get agentSkillSaved => 'Saved';

  @override
  String agentSkillLoadedInPanel(String name) {
    return 'Used skill: $name';
  }

  @override
  String agentSkillSaveCardTitle(String name) {
    return 'Save skill \"$name\"?';
  }

  @override
  String agentSkillUpdateCardTitle(String name) {
    return 'Update skill \"$name\"?';
  }

  @override
  String get agentSkillNeverUsed => 'Never used';

  @override
  String agentSkillUsedDaysAgo(int days) {
    return 'Unused for $days days';
  }

  @override
  String get agentSkillUsedToday => 'Used today';

  @override
  String agentSkillHits(int n) {
    return 'Used $n times';
  }

  @override
  String get agentSkillNotLoaded => 'Not indexed · needs a search';

  @override
  String get agentSkillNotLoadedHint =>
      'Skills past the index limit don\'t appear directly in the system prompt — the model has to call search_skills first to find them, costing an extra tool round-trip. To make one visible at a glance, free up an index slot (disable or delete ones you don\'t need) instead of deleting these.';

  @override
  String get agentBuiltinSkillsSection => 'Built-in';

  @override
  String get agentBuiltinSkillsHint =>
      'Ship with the app. You can turn one off, but not delete or edit it.';

  @override
  String get agentBuiltinSkillBadge => 'Built-in';

  @override
  String get agentBuiltinSkillTitleTroubleshoot => 'Troubleshoot';

  @override
  String get agentBuiltinSkillDescTroubleshoot =>
      'When something is broken: find the cause before changing anything, verify independently.';

  @override
  String get agentBuiltinSkillTitlePlanChange => 'Plan a change';

  @override
  String get agentBuiltinSkillDescPlanChange =>
      'For multi-step work: clarify the requirement, get the plan approved, change one step at a time.';

  @override
  String get agentBuiltinSkillTitleSkillCreator => 'Write a skill';

  @override
  String get agentBuiltinSkillDescSkillCreator =>
      'When writing a skill: phrase the description as a trigger, write the body as steps, attach scripts instead of inlining them.';

  @override
  String get agentAddToPlan => 'Add to plan';

  @override
  String get agentAddToPlanHint =>
      'Queue it up and approve it together with the other changes later';

  @override
  String get agentProposalTitle => 'Apply these changes?';

  @override
  String agentProposalCount(int n) {
    return '$n pending';
  }

  @override
  String get agentProposalApprove => 'Apply all';

  @override
  String get agentProposalDiscard => 'Discard';

  @override
  String get agentProposalNote =>
      'These run one after another. If one fails it stops there and the rest stay queued for you to decide.';

  @override
  String get agentKnowledgeTitle => 'Save what was learned here?';

  @override
  String get agentKnowledgeTargetSkill => 'Skill';

  @override
  String get agentKnowledgeTargetNotes => 'This machine\'s notes';

  @override
  String get agentKnowledgeSave => 'Save';

  @override
  String agentKnowledgeUpdate(String name) {
    return 'Update $name';
  }

  @override
  String get agentKnowledgeDismiss => 'Dismiss';

  @override
  String get agentKnowledgeSaved => 'Saved';

  @override
  String get agentKnowledgeExpand => 'Show full text';

  @override
  String get agentKnowledgeCollapse => 'Collapse';

  @override
  String agentKnowledgeNotesFull(int bytes) {
    return 'This machine\'s notes are full — trim $bytes more bytes';
  }

  @override
  String get agentKnowledgeSwitchHint =>
      'Tap the label to change where it goes';

  @override
  String get agentAdvancedRules => 'Advanced: auto-run list';

  @override
  String get agentUndo => 'Undo';

  @override
  String get agentUndone => 'Undone';

  @override
  String get agentUndoBackupMissing => 'Backup is gone; cannot undo';

  @override
  String get agentToolSuperseded =>
      'Speculative result discarded; this command was re-run';

  @override
  String get agentDiffEmpty => '(empty)';

  @override
  String agentDiffAtLine(String path, int line) {
    return '$path · line $line';
  }

  @override
  String get agentDiffExpand => 'Show full text';

  @override
  String get agentDiffCollapse => 'Hide';

  @override
  String get agentRejectReasonHint => '(optional) tell the AI why';

  @override
  String get agentStop => 'Stop';

  @override
  String get agentThinking => 'Thinking…';

  @override
  String agentRateLimited(int seconds) {
    return 'Rate limited — retrying in ${seconds}s';
  }

  @override
  String get agentRunning => 'Running…';

  @override
  String agentThinkingFor(int seconds) {
    return 'Thinking ${seconds}s';
  }

  @override
  String agentRunningFor(int seconds) {
    return 'Running ${seconds}s';
  }

  @override
  String agentExecutingMany(int count, int seconds) {
    return 'Running $count commands ${seconds}s';
  }

  @override
  String get agentAwaitingYou => 'Waiting for you';

  @override
  String get agentAwaitingAnswer => 'Waiting for your answer';

  @override
  String agentRunningCalls(int count) {
    return '$count calls so far';
  }

  @override
  String get agentAskOther => 'Type your own answer…';

  @override
  String get agentAskUnanswered => 'not answered';

  @override
  String get mentionServerColonHint => 'Type : to browse files on this host';

  @override
  String mentionUnknownServer(String name) {
    return 'No such host: $name';
  }

  @override
  String agentTurnSummary(String duration, int calls, String tokens) {
    return '$duration · $calls calls · $tokens token';
  }

  @override
  String get agentTurnSummaryTooltip =>
      'Includes time the app spent in the background';

  @override
  String agentStoppedMaxTurns(int n) {
    return 'Reached the $n-turn limit. Continue?';
  }

  @override
  String get agentStoppedTokenBudget => 'Context is near the limit. Continue?';

  @override
  String get agentStoppedCancelled =>
      'Stopped. Commands already sent were not undone.';

  @override
  String get agentStoppedInvalidArgs =>
      'The model kept sending invalid tool arguments. Aborted.';

  @override
  String get agentContinue => 'Continue';

  @override
  String get agentRetry => 'Retry';

  @override
  String get agentInputHint =>
      'Describe the problem · @ to reference a host · / for skills';

  @override
  String get attachPick => 'Add image or file';

  @override
  String get attachRemove => 'Remove';

  @override
  String get attachUnsupportedVision =>
      'This model does not support image input';

  @override
  String get attachTryAnyway => 'Try anyway';

  @override
  String get attachRejectBinary => 'Only images and text files are supported';

  @override
  String get attachRejectEmpty => 'That file is empty';

  @override
  String attachTooLarge(String size) {
    return 'Image too large ($size) — crop it and try again';
  }

  @override
  String attachTextTruncated(String size) {
    return '(truncated, original size $size)';
  }

  @override
  String get attachMissing => 'Image no longer available';

  @override
  String attachSkippedOnSend(int count) {
    return '$count attachment(s) unavailable, not sent this turn';
  }

  @override
  String get attachSaveFailed => 'Could not save the attachment';

  @override
  String get attachUnreadable =>
      'Could not read that file. Files in cloud storage need to be downloaded to this device first.';

  @override
  String attachContextOverflow(int tokens) {
    return 'Context exceeds the model limit; images account for about $tokens tokens. Start a new session or remove images.';
  }

  @override
  String get mentionFilesUnavailable => 'File browsing unavailable';

  @override
  String get mentionNeedAbsolutePath =>
      'Use an absolute path (starting with /)';

  @override
  String mentionDirLoadFailed(String error) {
    return 'Could not read directory: $error';
  }

  @override
  String mentionMoreEntries(int count) {
    return '$count more — keep typing to narrow';
  }

  @override
  String get agentPendingWithdrawHint => 'Queued — tap to withdraw';

  @override
  String agentUsage(String input, String output) {
    return 'in $input · out $output';
  }

  @override
  String agentUsageCumulative(String session, String total) {
    return '$session · total $total';
  }

  @override
  String agentUsageCached(String input, String cached, String output) {
    return 'in $input (cached $cached) · out $output';
  }

  @override
  String get agentNoCredentials =>
      'No saved credentials for this server — agent mode unavailable';

  @override
  String get agentGoToServerSettings => 'Open settings';

  @override
  String get agentNoToolSupport => 'This model does not support tool calling';

  @override
  String get agentSettingsTitle => 'AI Agent';

  @override
  String get agentModeBypassWarning =>
      'The AI will run any command on this server without asking, and can also change FlyTerm\'s own settings. Commands touching credential files, and operations that cannot be undone, still prompt.';

  @override
  String get agentRulesTitle => 'Auto-allowed commands';

  @override
  String get agentRulesBuiltinGroup => 'Defaults';

  @override
  String get agentRulesUserGroup => 'Approved by you';

  @override
  String get agentRulesEmpty => 'You haven\'t approved any rules yet';

  @override
  String get agentRulesFirstReview =>
      'The AI runs these without asking. Take a look — you can turn off any of them.';

  @override
  String get agentRulesGotIt => 'Got it';

  @override
  String get agentRulesGoReview => 'Review the allowlist';

  @override
  String get agentMemorySection => 'Assistant memory';

  @override
  String get agentAllowlistEntry => 'Auto-run list';

  @override
  String agentAllowlistSubtitleEnabled(int enabled, int total) {
    return '$enabled of $total categories allowed';
  }

  @override
  String get agentToolTierGroup => 'Tool tier';

  @override
  String get agentToolTierAuto => 'Auto';

  @override
  String get agentToolTierLean => 'Lean';

  @override
  String get agentToolTierFull => 'Full';

  @override
  String get agentToolTierAutoDesc =>
      'Auto: full tools for cloud models, lean (2 tools) for local models like Ollama';

  @override
  String get agentToolTierLeanDesc =>
      'Lean: only bash and read_file — best for small/local models';

  @override
  String get agentToolTierFullDesc =>
      'Full: also write_file, edit_file and set_plan — best for capable cloud models';

  @override
  String get agentBannerAskTitle => 'Currently: it will ask me first';

  @override
  String get agentBannerBypassTitle => 'Currently: it won\'t ask you';

  @override
  String get agentBannerPlanTitle => 'Now: plan first';

  @override
  String get agentCapabilityAutoLabel => 'Runs automatically';

  @override
  String get agentCapabilityAutoValue =>
      'View logs, check processes, read files, inspect containers';

  @override
  String get agentCapabilityAskLabel => 'Needs your confirmation';

  @override
  String get agentCapabilityAskValue =>
      'Editing files, restarting services, deleting things, any command with a pipe';

  @override
  String get agentRuleGroupServiceTitle => 'Service status & logs';

  @override
  String get agentRuleGroupServiceSubtitle =>
      'Whether a service is running, and its logs';

  @override
  String get agentRuleGroupSystemTitle => 'System & processes';

  @override
  String get agentRuleGroupSystemSubtitle =>
      'What\'s running, how much disk/memory is left';

  @override
  String get agentRuleGroupNetworkTitle => 'Network listeners';

  @override
  String get agentRuleGroupNetworkSubtitle =>
      'Which ports are listening, what\'s connected';

  @override
  String get agentRuleGroupFilesTitle => 'File contents';

  @override
  String get agentRuleGroupFilesSubtitle => 'Sends file contents to the AI';

  @override
  String get agentRuleGroupFilesWarning =>
      'Private keys, .env, .kube/config and similar files still prompt for approval separately, even with this group on.';

  @override
  String get agentRuleGroupDockerTitle => 'Docker containers';

  @override
  String get agentRuleGroupDockerSubtitle => 'Container status and logs';

  @override
  String get agentRuleGroupK8sTitle => 'Kubernetes';

  @override
  String get agentRuleGroupK8sSubtitle => 'Cluster resources and logs';

  @override
  String get agentRuleGroupOtherTitle => 'Other';

  @override
  String get agentPanelBypassActiveTooltip =>
      '\"Allow everything\" is on — the agent won\'t ask before running commands';

  @override
  String get agentInstructionsExamplesLabel => 'Try one of these:';

  @override
  String get agentInstructionsExample1 => 'Keep answers short, no padding';

  @override
  String get agentInstructionsExample2 => 'Lead with the conclusion';

  @override
  String get agentInstructionsExample3 => 'Answer in English';

  @override
  String get agentServerNotesEntry => 'This machine\'s notes';

  @override
  String agentServerNotesLines(int n) {
    return '$n lines';
  }

  @override
  String get agentServerNotesNone => 'Not created';

  @override
  String get agentServerNotesTitle => 'This machine\'s notes';

  @override
  String get agentServerNotesHint =>
      'Conventions and quirks of this box — \"uses podman, not docker\", \"logs live on /data\". Sent to the model on every turn, so keep it short.';

  @override
  String get agentServerNotesEmpty => 'No notes yet';

  @override
  String agentServerNotesBytes(int used, int max) {
    return '$used / $max bytes';
  }

  @override
  String get agentServerNotesSave => 'Save';

  @override
  String agentServerNotesTooLong(int n) {
    return '$n bytes over the limit. Trim it down.';
  }

  @override
  String get agentServerNotesOverviewEntry => 'Machine notes';

  @override
  String agentServerNotesOverviewSubtitle(int n) {
    return '$n machines';
  }

  @override
  String get agentServerNotesOverviewEmpty =>
      'No machine notes yet. They build up as you work, or you can write them by hand from a server\'s settings.';

  @override
  String agentServerNotesUpdatedAt(String time) {
    return 'Last updated: $time';
  }

  @override
  String get agentServerNotesDelete => 'Delete these notes';

  @override
  String agentServerNotesForMachine(String name) {
    return 'Machine notes: $name';
  }

  @override
  String agentToolRunningFor(int seconds) {
    return 'running ${seconds}s';
  }

  @override
  String agentToolTook(String duration) {
    return 'took $duration';
  }

  @override
  String agentJobRunning(String elapsed) {
    return 'running for $elapsed';
  }

  @override
  String agentJobFinished(int code) {
    return 'finished · exit $code';
  }

  @override
  String get agentJobKilling => 'stopping…';

  @override
  String agentJobSinceStart(String elapsed) {
    return '$elapsed since start';
  }

  @override
  String get agentJobCheckedJustNow => 'just checked';

  @override
  String agentJobCheckedMinutes(int n) {
    return 'checked ${n}m ago';
  }

  @override
  String agentJobCheckedHours(int n) {
    return 'checked ${n}h ago';
  }

  @override
  String agentJobCheckedDays(int n) {
    return 'checked ${n}d ago';
  }

  @override
  String agentJobsBarCount(int count) {
    return '$count background jobs';
  }

  @override
  String get agentJobStop => 'Stop';

  @override
  String get transferDownloading => 'downloading';

  @override
  String get transferUploading => 'uploading';

  @override
  String transferRelayDownloading(String from) {
    return 'fetching from $from';
  }

  @override
  String transferRelayUploading(String to) {
    return 'sending to $to';
  }

  @override
  String get transferDone => 'Done';

  @override
  String get transferCancelled => 'Cancelled';

  @override
  String get transferFailed => 'failed';

  @override
  String get transferInterrupted => 'interrupted';

  @override
  String get transferCancel => 'Cancel';

  @override
  String get transferOpen => 'Open';

  @override
  String get transferLetAiRead => 'Let AI read it';

  @override
  String get transferShare => 'Share';

  @override
  String get transferCredentialWarning =>
      'Credential file — its contents will not be sent to the AI';

  @override
  String transferBackupKept(String path) {
    return 'Previous file kept at $path';
  }

  @override
  String agentCompacted(int count) {
    return 'compacted $count earlier messages';
  }

  @override
  String agentTruncated(int count) {
    return '$count earlier entries omitted';
  }

  @override
  String agentToolOutputLines(int count) {
    return '$count lines';
  }

  @override
  String agentPlanUpdatedCollapsed(int count) {
    return 'Plan updated ($count steps)';
  }

  @override
  String get agentKnowledgeResolved => 'Knowledge proposal · resolved';

  @override
  String get agentExportMetrics => 'Export timing metrics';

  @override
  String get batchApprovalTitle => 'Needs your approval';

  @override
  String batchApprovalCount(int count) {
    return '$count calls';
  }

  @override
  String get batchApprovalCurrentSession => 'current session';

  @override
  String get batchApprovalApproveAll => 'Approve all';

  @override
  String get batchApprovalDiscard => 'Cancel';

  @override
  String get agentInterruptedTitle => 'Last session was interrupted';

  @override
  String agentInterruptedRunning(String calls) {
    return 'Running at the time:\n$calls';
  }

  @override
  String get aiSwitchModel => 'Switch model';

  @override
  String get aiModelNoToolSupport => 'No tool-calling support';

  @override
  String get aiModelNoApiKey => 'No API key configured';

  @override
  String get aiModelLeanTools => 'Reduced tool set — no file transfer';

  @override
  String get aiExportSession => 'Export session';

  @override
  String get aiExportPreviewTitle => 'Export preview';

  @override
  String aiExportRedacted(int count) {
    return '$count secret(s) redacted';
  }

  @override
  String get aiExportShare => 'Share';

  @override
  String get aiExportEmpty => 'Nothing to export in this session yet';

  @override
  String agentSupersededCollapsed(int count) {
    return 'Resent — $count item(s) collapsed';
  }

  @override
  String get agentInterruptedResume => 'Continue';

  @override
  String get navAI => 'AI';

  @override
  String get navServers => 'Servers';

  @override
  String get navSettings => 'Settings';

  @override
  String get aiGlobalEmptyTitle => 'How can I help?';

  @override
  String get aiGlobalSuggest1 => 'Explain this error';

  @override
  String get aiGlobalSuggest2 => 'Write a shell command';

  @override
  String get aiGlobalSuggest3 => 'Explain a config file';

  @override
  String get aiGlobalClearHistory => 'Clear history';

  @override
  String get aiRunOnServer => 'Run on server…';

  @override
  String get aiGlobalAgentEmptyTitle => 'What can I do for you?';

  @override
  String get aiGlobalAgentSuggest1 => 'Which machine is running out of disk';

  @override
  String get aiGlobalAgentSuggest2 => 'Check load on all machines';

  @override
  String get aiGlobalAgentSuggest3 => 'Look for nginx errors';

  @override
  String get aiGlobalAgentSuggest4 => 'Make the terminal font bigger';

  @override
  String get aiHomeRecent => 'Pick up where you left off';

  @override
  String get aiHomeMachines => 'Machines';

  @override
  String get aiHomeOrAsk => 'Or just ask';

  @override
  String aiHomeMoreMachines(int count) {
    return '+$count';
  }

  @override
  String get relativeTimeJustNow => 'just now';

  @override
  String aiHomeSuggestDisk(String machine) {
    return 'Check disk on $machine';
  }

  @override
  String aiHomeSuggestLoad(String machine) {
    return 'Check load on $machine';
  }

  @override
  String aiHomeSuggestLogs(String machine) {
    return 'Check logs on $machine';
  }

  @override
  String get serversScanJobs => 'Scan for background jobs';

  @override
  String jobsRunningBadge(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count jobs running',
      one: '1 job running',
    );
    return '$_temp0';
  }

  @override
  String get importPasteTitle => 'Paste to import';

  @override
  String get importPasteHint =>
      'Paste an ssh config block or a single ssh command';

  @override
  String get importPasteAction => 'Detect';

  @override
  String get importParsedTitle => 'Detected';

  @override
  String get importNotRecognized => 'No server details found';

  @override
  String get importFormatExamples =>
      'Supported formats:\nssh -p 2222 root@example.com\nHost web\n  HostName 10.0.0.5';

  @override
  String get importTryAi => 'Try with AI';

  @override
  String get importAiFailed =>
      'AI could not parse it either — please fill it in manually';

  @override
  String get importStrippedKey =>
      'A private key in the pasted text was ignored and never sent anywhere';

  @override
  String get importStrippedPassword =>
      'A password line in the pasted text was ignored';

  @override
  String get importSawInclude => 'Files referenced by Include were not read';

  @override
  String get importNeedsManualKey =>
      'This host uses key authentication — pick a key manually';

  @override
  String get importPickHost => 'Several hosts found — pick one to import';

  @override
  String get importPickServerForTunnel =>
      'Which server should this forward belong to?';

  @override
  String get importApplied => 'Filled into the form — review and save';

  @override
  String get appControlSection => 'App control';

  @override
  String appChangeBarLabel(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count app settings changed',
      one: '1 app setting changed',
    );
    return '$_temp0';
  }

  @override
  String get appChangeUndo => 'Undo';

  @override
  String get appChangeIrreversible => 'Includes changes that cannot be undone';

  @override
  String appChangeCardTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'AI changed $count app settings',
      one: 'AI changed 1 app setting',
    );
    return '$_temp0';
  }

  @override
  String appChangeMore(int count) {
    return '$count more…';
  }

  @override
  String get appChangeUndone => 'Undone';

  @override
  String get appChangeRestoredNote =>
      'These app changes came from an earlier session and can no longer be undone';

  @override
  String get appChangeOn => 'On';

  @override
  String get appChangeOff => 'Off';

  @override
  String get appChangeKindServer => 'Server';

  @override
  String get appChangeKindTunnel => 'Port forward';

  @override
  String get appChangeKindKey => 'Key';

  @override
  String get appChangeKindSession => 'Session';

  @override
  String get appChangeKindLayout => 'Split layout';

  @override
  String get appChangeFieldFontFamily => 'Terminal font';

  @override
  String get appChangeFieldLineHeight => 'Line height';

  @override
  String get jobBoardTitle => 'Background Jobs';

  @override
  String get jobBoardNoServers => 'No servers yet';

  @override
  String get jobBoardNoJobs => 'No background jobs';

  @override
  String get jobBoardScanFailed => 'Scan failed';

  @override
  String get jobBoardRetry => 'Retry';

  @override
  String jobBoardSkippedEntries(int count) {
    return '$count entries not recognized';
  }

  @override
  String get jobBoardRunning => 'running';

  @override
  String jobBoardExitCode(String code) {
    return 'exit code $code';
  }

  @override
  String get jobBoardLogTimeUnknown => 'log time unknown';

  @override
  String jobBoardLogUpdatedAgo(String ago) {
    return 'log updated $ago';
  }

  @override
  String jobBoardLineCount(int count) {
    return '$count lines';
  }

  @override
  String jobBoardReadLogFailed(String error) {
    return 'Failed to read log: $error';
  }

  @override
  String get jobBoardReadingLog => 'Reading…';

  @override
  String get jobBoardKillTooltip => 'Terminate';

  @override
  String get jobBoardCopyJobIdTooltip => 'Copy job id';

  @override
  String get jobBoardHandOffTooltip => 'Let AI take over';

  @override
  String get jobBoardNeedTabTooltip => 'Connect to this server first';

  @override
  String get jobBoardCopiedJobId => 'Job id copied';

  @override
  String get jobBoardKillSent => 'Termination signal sent';

  @override
  String get jobBoardConfirmKillTitle => 'Terminate this job?';

  @override
  String jobBoardConfirmKillContent(String job, String server) {
    return '$job on $server.\nSIGTERM will be sent to the whole process group; this cannot be undone.';
  }

  @override
  String jobBoardHandOffPrompt(String id) {
    return 'Background job `$id` is still running. Use check_job to see its progress, then continue.';
  }

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String timeHoursAgo(int count) {
    return '$count h ago';
  }

  @override
  String timeDaysAgo(int count) {
    return '$count d ago';
  }

  @override
  String get timeToday => 'today';

  @override
  String get timeYesterday => 'yesterday';

  @override
  String timeMonthsAgo(int count) {
    return '$count mo ago';
  }

  @override
  String knownHostFirstSeen(String date, String time) {
    return 'First seen $date · last $time';
  }

  @override
  String get fingerprintCopied => 'Fingerprint copied';

  @override
  String get selectionColorFollowTheme => 'Follow theme';

  @override
  String get selectionColorBlue => 'Blue';

  @override
  String get selectionColorPurple => 'Purple';

  @override
  String get selectionColorOrange => 'Orange';

  @override
  String get selectionColorGray => 'Gray';

  @override
  String get floatingNotConnected => 'Not connected';

  @override
  String get floatingDisconnected => 'disconnected';

  @override
  String get floatingGhostMode => 'Ghost mode';

  @override
  String get floatingExitGhostMode => 'Exit ghost mode';

  @override
  String get fileSaved => 'Saved';

  @override
  String fileSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get fileTooLargeReadonly =>
      'File too large; showing first 512 KB with saving disabled to prevent data loss';

  @override
  String get imageDecodeFailed => 'Failed to decode image';

  @override
  String get browseAction => 'Browse';

  @override
  String keyImportFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get keyPassphraseEmptyHint => 'Leave empty for no passphrase';

  @override
  String get transferFileTitle => 'Transfer file (QUIC)';

  @override
  String get transferRemotePathHint => 'Remote path (e.g. ~/upload/file.bin)';

  @override
  String get transferUpload => 'Upload';

  @override
  String get transferDownload => 'Download';

  @override
  String get transferWaiting => 'Waiting...';

  @override
  String transferFailedWithReason(String error) {
    return 'Failed: $error';
  }

  @override
  String get transferUnknownError => 'unknown';

  @override
  String get retry => 'Retry';

  @override
  String get loading => 'Loading…';

  @override
  String settingsConnectionAdvancedSubtitle(
    String compression,
    String keepAlive,
  ) {
    return 'Compression $compression · keep-alive $keepAlive';
  }

  @override
  String settingsSecuritySubtitle(String state) {
    return 'Dangerous command guard $state';
  }

  @override
  String settingsPrivacySubtitle(String crash, String analytics) {
    return 'Crash reports $crash · analytics $analytics';
  }

  @override
  String get refreshLosesSessionTitle => 'Refreshing loses the session';

  @override
  String get refreshLosesSessionBody =>
      'This server runs in Once mode. Refreshing starts a new shell — the original scrollback, running commands, and SHELL process will all be lost.\n\nIf you enable Daemon mode in the server settings, refreshing will truly \"restore\" the original session.';

  @override
  String get dontShowAgain => 'Don\'t show again';

  @override
  String get continueRefresh => 'Refresh anyway';

  @override
  String get highRiskCommandTitle => 'High-risk command';

  @override
  String get highRiskCommandBody =>
      'This command may damage data or the system. Run it anyway?';

  @override
  String get aiExplain => 'AI explain';

  @override
  String get execute => 'Run';

  @override
  String quicConnectFailedHint(String error) {
    return 'QUIC connect failed: $error\nFor an SSH fallback, change Transport to SSH in the server settings.';
  }

  @override
  String get tmuxNotFoundClosed =>
      '[tmux not found, session closed automatically]';

  @override
  String get backAction => 'Back';

  @override
  String get sftpRecentPaths => 'Recent';

  @override
  String get sftpPinnedPaths => 'Bookmarks';

  @override
  String get sftpNoRecentPaths => 'No history yet';

  @override
  String get sftpNoPinnedPaths =>
      'No bookmarks yet — long-press an entry to pin it';

  @override
  String get sftpPathSuggestions => 'Suggestions';

  @override
  String get sftpPinPath => 'Pin';

  @override
  String get sftpUnpinPath => 'Unpin';

  @override
  String get sftpRemovePath => 'Remove from history';

  @override
  String get agentPermReadOnly => 'Read-only';

  @override
  String get agentPermReadOnlyDesc => 'AI can look but not change anything';

  @override
  String get agentPermAsk => 'Ask me';

  @override
  String get agentPermAskDesc =>
      'Read commands just run; file changes queue up for one approval';

  @override
  String get agentPermBypass => 'Allow all';

  @override
  String get agentPermBypassDesc =>
      'Does anything without asking (credential files excepted)';

  @override
  String get agentPermTitle => 'AI permissions';

  @override
  String agentPermFollowGlobal(String mode) {
    return 'Follow global ($mode)';
  }

  @override
  String get agentPermServerTitle => 'AI permissions for this server';

  @override
  String get agentApprovalOnce => 'Just this once';

  @override
  String get agentApprovalAlways => 'Always allow';

  @override
  String get agentApprovalRulePrefix => 'Always allow';

  @override
  String get agentApprovalReject => 'Reject';

  @override
  String get promptLanguageName => 'English';
}

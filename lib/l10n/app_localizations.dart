import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'FlyTerm'**
  String get appTitle;

  /// No description provided for @newConnection.
  ///
  /// In en, this message translates to:
  /// **'New Connection'**
  String get newConnection;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @sftpViewSource.
  ///
  /// In en, this message translates to:
  /// **'View source'**
  String get sftpViewSource;

  /// No description provided for @sftpViewPreview.
  ///
  /// In en, this message translates to:
  /// **'View rendered'**
  String get sftpViewPreview;

  /// No description provided for @sftpMarkdownTruncated.
  ///
  /// In en, this message translates to:
  /// **'File is large — showing the first part.'**
  String get sftpMarkdownTruncated;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get confirm;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @noServers.
  ///
  /// In en, this message translates to:
  /// **'No servers'**
  String get noServers;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add Server'**
  String get addServer;

  /// No description provided for @viaJumpHost.
  ///
  /// In en, this message translates to:
  /// **'Via jump host'**
  String get viaJumpHost;

  /// No description provided for @newSession.
  ///
  /// In en, this message translates to:
  /// **'New Session'**
  String get newSession;

  /// No description provided for @sftpFileBrowser.
  ///
  /// In en, this message translates to:
  /// **'SFTP File Browser'**
  String get sftpFileBrowser;

  /// No description provided for @newTunnel.
  ///
  /// In en, this message translates to:
  /// **'New Tunnel'**
  String get newTunnel;

  /// No description provided for @deleteServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Server?'**
  String get deleteServerTitle;

  /// No description provided for @confirmDeleteServer.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String confirmDeleteServer(String name);

  /// No description provided for @sftpConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'SFTP connection failed: {error}'**
  String sftpConnectFailed(String error);

  /// No description provided for @editServer.
  ///
  /// In en, this message translates to:
  /// **'Edit Server'**
  String get editServer;

  /// No description provided for @newServer.
  ///
  /// In en, this message translates to:
  /// **'New Server'**
  String get newServer;

  /// No description provided for @labelName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get labelName;

  /// No description provided for @labelHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get labelHost;

  /// No description provided for @labelHostHelper.
  ///
  /// In en, this message translates to:
  /// **'IPv4, IPv6, or hostname (brackets around IPv6 are optional)'**
  String get labelHostHelper;

  /// No description provided for @labelPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get labelPort;

  /// No description provided for @addressFamilyLabel.
  ///
  /// In en, this message translates to:
  /// **'Address family'**
  String get addressFamilyLabel;

  /// No description provided for @addressFamilyAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto (prefer IPv6)'**
  String get addressFamilyAuto;

  /// No description provided for @addressFamilyIpv4.
  ///
  /// In en, this message translates to:
  /// **'Force IPv4'**
  String get addressFamilyIpv4;

  /// No description provided for @addressFamilyIpv6.
  ///
  /// In en, this message translates to:
  /// **'Force IPv6'**
  String get addressFamilyIpv6;

  /// No description provided for @invalidPort.
  ///
  /// In en, this message translates to:
  /// **'Invalid port'**
  String get invalidPort;

  /// No description provided for @labelUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get labelUsername;

  /// No description provided for @labelStartupCommand.
  ///
  /// In en, this message translates to:
  /// **'Command after connect (optional)'**
  String get labelStartupCommand;

  /// No description provided for @hintStartupCommand.
  ///
  /// In en, this message translates to:
  /// **'e.g. tmux, cd /var/log'**
  String get hintStartupCommand;

  /// No description provided for @authMethod.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get authMethod;

  /// No description provided for @authPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPassword;

  /// No description provided for @authSshKey.
  ///
  /// In en, this message translates to:
  /// **'SSH Key'**
  String get authSshKey;

  /// No description provided for @labelPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get labelPassword;

  /// No description provided for @selectKey.
  ///
  /// In en, this message translates to:
  /// **'Select Key'**
  String get selectKey;

  /// No description provided for @keyRequired.
  ///
  /// In en, this message translates to:
  /// **'Please select a key'**
  String get keyRequired;

  /// No description provided for @addSshKey.
  ///
  /// In en, this message translates to:
  /// **'Add new key'**
  String get addSshKey;

  /// No description provided for @hostKeyTofuTitle.
  ///
  /// In en, this message translates to:
  /// **'First connection — verify host key'**
  String get hostKeyTofuTitle;

  /// No description provided for @hostKeyTofuBody.
  ///
  /// In en, this message translates to:
  /// **'FlyTerm has not seen this server before. Confirm the fingerprint matches the one your server administrator gave you.'**
  String get hostKeyTofuBody;

  /// No description provided for @hostKeyMismatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Host key changed!'**
  String get hostKeyMismatchTitle;

  /// No description provided for @hostKeyMismatchBody.
  ///
  /// In en, this message translates to:
  /// **'The host\'s key is different from what was stored. This can happen if the server was reinstalled — but it can also be a man-in-the-middle attack. Verify with the administrator before continuing.'**
  String get hostKeyMismatchBody;

  /// No description provided for @hostKeyHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get hostKeyHost;

  /// No description provided for @hostKeyType.
  ///
  /// In en, this message translates to:
  /// **'Key type'**
  String get hostKeyType;

  /// No description provided for @hostKeyFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint (MD5)'**
  String get hostKeyFingerprint;

  /// No description provided for @hostKeyExpected.
  ///
  /// In en, this message translates to:
  /// **'Expected fingerprint'**
  String get hostKeyExpected;

  /// No description provided for @hostKeyActual.
  ///
  /// In en, this message translates to:
  /// **'Received fingerprint'**
  String get hostKeyActual;

  /// No description provided for @hostKeyAccept.
  ///
  /// In en, this message translates to:
  /// **'Trust and connect'**
  String get hostKeyAccept;

  /// No description provided for @hostKeyAcceptAnyway.
  ///
  /// In en, this message translates to:
  /// **'Connect anyway (replace stored key)'**
  String get hostKeyAcceptAnyway;

  /// No description provided for @hostKeyReject.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get hostKeyReject;

  /// No description provided for @knownHostsTitle.
  ///
  /// In en, this message translates to:
  /// **'Known Hosts'**
  String get knownHostsTitle;

  /// No description provided for @knownHostsEntry.
  ///
  /// In en, this message translates to:
  /// **'Known Hosts'**
  String get knownHostsEntry;

  /// No description provided for @knownHostsEntrySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Trusted server fingerprints'**
  String get knownHostsEntrySubtitle;

  /// No description provided for @knownHostsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No trusted hosts yet. The first time you connect to a new server you will be asked to confirm its fingerprint.'**
  String get knownHostsEmpty;

  /// No description provided for @knownHostDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get knownHostDelete;

  /// No description provided for @knownHostDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Forget this host?'**
  String get knownHostDeleteTitle;

  /// No description provided for @sshCompressionTitle.
  ///
  /// In en, this message translates to:
  /// **'SSH compression'**
  String get sshCompressionTitle;

  /// No description provided for @sshCompressionDesc.
  ///
  /// In en, this message translates to:
  /// **'Use zlib for SSH traffic — large bandwidth savings on slow / metered links. Disable for fast LAN where CPU cost outweighs the gain.'**
  String get sshCompressionDesc;

  /// No description provided for @backgroundKeepAliveTitle.
  ///
  /// In en, this message translates to:
  /// **'Background keep-alive'**
  String get backgroundKeepAliveTitle;

  /// No description provided for @backgroundKeepAliveDesc.
  ///
  /// In en, this message translates to:
  /// **'Keep terminal sessions connected while the app is in the background. The cost is a permanent entry in the notification shade — Android requires foreground services to show one and it cannot be hidden. With this off, sessions drop when you leave the app and server-pushed task notifications won\'t arrive.'**
  String get backgroundKeepAliveDesc;

  /// No description provided for @notificationPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Notification permission'**
  String get notificationPermissionTitle;

  /// No description provided for @notificationPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Notifications are allowed'**
  String get notificationPermissionGranted;

  /// No description provided for @notificationPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Notifications are blocked for FlyTerm — task and approval alerts cannot be shown'**
  String get notificationPermissionDenied;

  /// No description provided for @notificationPermissionChannelDisabled.
  ///
  /// In en, this message translates to:
  /// **'The “Task Notifications” channel is turned off — alerts cannot be shown'**
  String get notificationPermissionChannelDisabled;

  /// No description provided for @notificationPermissionUnknown.
  ///
  /// In en, this message translates to:
  /// **'Can\'t determine notification permission on this device'**
  String get notificationPermissionUnknown;

  /// No description provided for @notificationPermissionOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open system settings'**
  String get notificationPermissionOpenSettings;

  /// No description provided for @notificationPermissionRequest.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications'**
  String get notificationPermissionRequest;

  /// No description provided for @notifySessionGone.
  ///
  /// In en, this message translates to:
  /// **'That session is no longer open'**
  String get notifySessionGone;

  /// No description provided for @knownHostDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'FlyTerm will ask to confirm the fingerprint again on the next connection to {host}.'**
  String knownHostDeleteBody(String host);

  /// No description provided for @tmuxAutoRecover.
  ///
  /// In en, this message translates to:
  /// **'tmux Auto-Recovery'**
  String get tmuxAutoRecover;

  /// No description provided for @tmuxAutoRecoverDesc.
  ///
  /// In en, this message translates to:
  /// **'Restore terminal session on reconnect; requires tmux on server'**
  String get tmuxAutoRecoverDesc;

  /// No description provided for @transport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get transport;

  /// No description provided for @transportRecommended.
  ///
  /// In en, this message translates to:
  /// **'recommended'**
  String get transportRecommended;

  /// No description provided for @useTmux.
  ///
  /// In en, this message translates to:
  /// **'Use tmux (process persistence)'**
  String get useTmux;

  /// No description provided for @useTmuxDesc.
  ///
  /// In en, this message translates to:
  /// **'Only needed if PTY must survive the remote server restarting'**
  String get useTmuxDesc;

  /// No description provided for @useDaemon.
  ///
  /// In en, this message translates to:
  /// **'Daemon mode (long-running on remote)'**
  String get useDaemon;

  /// No description provided for @useDaemonDesc.
  ///
  /// In en, this message translates to:
  /// **'Enables cross-SSH-session continuation; explicit error on start failure (strict)'**
  String get useDaemonDesc;

  /// No description provided for @useMosh.
  ///
  /// In en, this message translates to:
  /// **'Use Mosh'**
  String get useMosh;

  /// No description provided for @moshDesc.
  ///
  /// In en, this message translates to:
  /// **'UDP connection with roaming; requires mosh-server on server'**
  String get moshDesc;

  /// No description provided for @moshNotSupportedWithJump.
  ///
  /// In en, this message translates to:
  /// **'Mosh does not support jump hosts — change transport or disable jump host'**
  String get moshNotSupportedWithJump;

  /// No description provided for @moshPortRange.
  ///
  /// In en, this message translates to:
  /// **'Mosh Port Range'**
  String get moshPortRange;

  /// No description provided for @moshPortRangeFormat.
  ///
  /// In en, this message translates to:
  /// **'Format: start:end'**
  String get moshPortRangeFormat;

  /// No description provided for @moshPortMustBeInt.
  ///
  /// In en, this message translates to:
  /// **'Ports must be integers'**
  String get moshPortMustBeInt;

  /// No description provided for @moshStartBeforeEnd.
  ///
  /// In en, this message translates to:
  /// **'Start port must be less than end port'**
  String get moshStartBeforeEnd;

  /// No description provided for @useJumpHost.
  ///
  /// In en, this message translates to:
  /// **'Use Jump Host'**
  String get useJumpHost;

  /// No description provided for @useJumpHostDesc.
  ///
  /// In en, this message translates to:
  /// **'Connect through another server'**
  String get useJumpHostDesc;

  /// No description provided for @selectJumpServer.
  ///
  /// In en, this message translates to:
  /// **'Select Jump Server'**
  String get selectJumpServer;

  /// No description provided for @jumpServerRequired.
  ///
  /// In en, this message translates to:
  /// **'Please select a jump server'**
  String get jumpServerRequired;

  /// No description provided for @addJumpServer.
  ///
  /// In en, this message translates to:
  /// **'Add Jump Server'**
  String get addJumpServer;

  /// No description provided for @sectionConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get sectionConnection;

  /// No description provided for @sectionAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get sectionAccount;

  /// No description provided for @sectionAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get sectionAppearance;

  /// No description provided for @sectionInput.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get sectionInput;

  /// No description provided for @sectionSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get sectionSecurity;

  /// No description provided for @sectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get sectionAbout;

  /// No description provided for @appearanceSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceSettingsTitle;

  /// No description provided for @connectionAdvancedTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced Connection'**
  String get connectionAdvancedTitle;

  /// No description provided for @securitySettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get securitySettingsTitle;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// No description provided for @keybarCount.
  ///
  /// In en, this message translates to:
  /// **'{count} items'**
  String keybarCount(int count);

  /// No description provided for @enabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get disabled;

  /// No description provided for @sectionAI.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get sectionAI;

  /// No description provided for @sectionData.
  ///
  /// In en, this message translates to:
  /// **'Data & Privacy'**
  String get sectionData;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @sshKeys.
  ///
  /// In en, this message translates to:
  /// **'SSH Keys'**
  String get sshKeys;

  /// No description provided for @sshKeysSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage SSH key pairs'**
  String get sshKeysSubtitle;

  /// No description provided for @aiProviders.
  ///
  /// In en, this message translates to:
  /// **'AI Providers'**
  String get aiProviders;

  /// No description provided for @aiProvidersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure AI API keys'**
  String get aiProvidersSubtitle;

  /// No description provided for @tunnels.
  ///
  /// In en, this message translates to:
  /// **'Tunnels'**
  String get tunnels;

  /// No description provided for @tunnelCountBadge.
  ///
  /// In en, this message translates to:
  /// **'{count} tunnels'**
  String tunnelCountBadge(int count);

  /// No description provided for @aiErrorHint.
  ///
  /// In en, this message translates to:
  /// **'AI Error Analysis'**
  String get aiErrorHint;

  /// No description provided for @aiErrorHintDesc.
  ///
  /// In en, this message translates to:
  /// **'Suggest AI analysis on errors'**
  String get aiErrorHintDesc;

  /// No description provided for @terminalFontSize.
  ///
  /// In en, this message translates to:
  /// **'Terminal Font Size'**
  String get terminalFontSize;

  /// No description provided for @terminalCursorStyle.
  ///
  /// In en, this message translates to:
  /// **'Cursor Style'**
  String get terminalCursorStyle;

  /// No description provided for @terminalCursorStyleDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get terminalCursorStyleDefault;

  /// No description provided for @terminalCursorStyleVerticalBar.
  ///
  /// In en, this message translates to:
  /// **'Vertical bar'**
  String get terminalCursorStyleVerticalBar;

  /// No description provided for @terminalCursorStyleBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get terminalCursorStyleBlock;

  /// No description provided for @terminalCursorStyleUnderline.
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get terminalCursorStyleUnderline;

  /// No description provided for @dangerousCommandGuard.
  ///
  /// In en, this message translates to:
  /// **'Dangerous Command Guard'**
  String get dangerousCommandGuard;

  /// No description provided for @dangerousCommandGuardDesc.
  ///
  /// In en, this message translates to:
  /// **'Prompt for confirmation when typing high-risk commands like rm -rf or dd'**
  String get dangerousCommandGuardDesc;

  /// No description provided for @commandCompletionTitle.
  ///
  /// In en, this message translates to:
  /// **'Command completion'**
  String get commandCompletionTitle;

  /// No description provided for @commandCompletionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Suggest commands from history and the remote shell. Runs locally — no AI provider needed.'**
  String get commandCompletionSubtitle;

  /// No description provided for @noKeys.
  ///
  /// In en, this message translates to:
  /// **'No keys'**
  String get noKeys;

  /// No description provided for @copyPublicKey.
  ///
  /// In en, this message translates to:
  /// **'Copy Public Key'**
  String get copyPublicKey;

  /// No description provided for @addKey.
  ///
  /// In en, this message translates to:
  /// **'Add Key'**
  String get addKey;

  /// No description provided for @publicKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Public key copied to clipboard'**
  String get publicKeyCopied;

  /// No description provided for @deleteKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Key?'**
  String get deleteKeyTitle;

  /// No description provided for @confirmDeleteKey.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String confirmDeleteKey(String name);

  /// No description provided for @generateEd25519.
  ///
  /// In en, this message translates to:
  /// **'Generate Ed25519 Key'**
  String get generateEd25519;

  /// No description provided for @generateRsa4096.
  ///
  /// In en, this message translates to:
  /// **'Generate RSA 4096 Key'**
  String get generateRsa4096;

  /// No description provided for @importFromPem.
  ///
  /// In en, this message translates to:
  /// **'Import from PEM'**
  String get importFromPem;

  /// No description provided for @keyName.
  ///
  /// In en, this message translates to:
  /// **'Key Name'**
  String get keyName;

  /// No description provided for @keyNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. my-macbook'**
  String get keyNameHint;

  /// No description provided for @pastePem.
  ///
  /// In en, this message translates to:
  /// **'Paste private key (PEM format)'**
  String get pastePem;

  /// No description provided for @noProviders.
  ///
  /// In en, this message translates to:
  /// **'No AI providers'**
  String get noProviders;

  /// No description provided for @setDefault.
  ///
  /// In en, this message translates to:
  /// **'Set as default'**
  String get setDefault;

  /// No description provided for @addProvider.
  ///
  /// In en, this message translates to:
  /// **'Add Provider'**
  String get addProvider;

  /// No description provided for @deleteProviderTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Provider?'**
  String get deleteProviderTitle;

  /// No description provided for @confirmDeleteProvider.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String confirmDeleteProvider(String name);

  /// No description provided for @editProvider.
  ///
  /// In en, this message translates to:
  /// **'Edit Provider'**
  String get editProvider;

  /// No description provided for @displayName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get displayName;

  /// No description provided for @providerType.
  ///
  /// In en, this message translates to:
  /// **'Provider type'**
  String get providerType;

  /// No description provided for @model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get model;

  /// No description provided for @baseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL (optional)'**
  String get baseUrl;

  /// No description provided for @apiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// No description provided for @apiKeyEditHint.
  ///
  /// In en, this message translates to:
  /// **'API Key (leave blank to keep existing)'**
  String get apiKeyEditHint;

  /// No description provided for @extrasJson.
  ///
  /// In en, this message translates to:
  /// **'Extra Parameters (JSON, optional)'**
  String get extrasJson;

  /// No description provided for @invalidJson.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid JSON object'**
  String get invalidJson;

  /// No description provided for @setAsDefault.
  ///
  /// In en, this message translates to:
  /// **'Set as default provider'**
  String get setAsDefault;

  /// No description provided for @providerSectionIdentity.
  ///
  /// In en, this message translates to:
  /// **'IDENTITY'**
  String get providerSectionIdentity;

  /// No description provided for @providerSectionEndpoint.
  ///
  /// In en, this message translates to:
  /// **'ENDPOINT'**
  String get providerSectionEndpoint;

  /// No description provided for @providerSectionAuth.
  ///
  /// In en, this message translates to:
  /// **'AUTH'**
  String get providerSectionAuth;

  /// No description provided for @providerSectionAdvanced.
  ///
  /// In en, this message translates to:
  /// **'ADVANCED'**
  String get providerSectionAdvanced;

  /// No description provided for @providerSectionPresets.
  ///
  /// In en, this message translates to:
  /// **'PRESETS'**
  String get providerSectionPresets;

  /// No description provided for @providerModelVolatileHint.
  ///
  /// In en, this message translates to:
  /// **'Model IDs change. If the API reports an unknown model, check the provider\'s console for the current name.'**
  String get providerModelVolatileHint;

  /// No description provided for @noTunnels.
  ///
  /// In en, this message translates to:
  /// **'No tunnels'**
  String get noTunnels;

  /// No description provided for @tapPlusToAdd.
  ///
  /// In en, this message translates to:
  /// **'Tap + to create one'**
  String get tapPlusToAdd;

  /// No description provided for @reconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get reconnect;

  /// No description provided for @deleteTunnelTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Tunnel?'**
  String get deleteTunnelTitle;

  /// No description provided for @confirmDeleteTunnel.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\" and its saved config?'**
  String confirmDeleteTunnel(String name);

  /// No description provided for @disableAutoConnect.
  ///
  /// In en, this message translates to:
  /// **'Disable Auto-Connect'**
  String get disableAutoConnect;

  /// No description provided for @enableAutoConnect.
  ///
  /// In en, this message translates to:
  /// **'Enable Auto-Connect'**
  String get enableAutoConnect;

  /// No description provided for @startTunnel.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get startTunnel;

  /// No description provided for @stopTunnel.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopTunnel;

  /// No description provided for @deleteConfig.
  ///
  /// In en, this message translates to:
  /// **'Delete Config'**
  String get deleteConfig;

  /// No description provided for @tunnelStatusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get tunnelStatusActive;

  /// No description provided for @tunnelStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get tunnelStatusConnecting;

  /// No description provided for @tunnelStatusReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting ({count}/{max})…'**
  String tunnelStatusReconnecting(int count, int max);

  /// No description provided for @tunnelStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get tunnelStatusFailed;

  /// No description provided for @tunnelStatusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get tunnelStatusError;

  /// No description provided for @tunnelStatusStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get tunnelStatusStopped;

  /// No description provided for @selectServer.
  ///
  /// In en, this message translates to:
  /// **'Select server'**
  String get selectServer;

  /// No description provided for @tunnelDirLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get tunnelDirLocal;

  /// No description provided for @tunnelDirRemote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get tunnelDirRemote;

  /// No description provided for @tunnelDescLocal.
  ///
  /// In en, this message translates to:
  /// **'Phone port → Server port (access remote services)'**
  String get tunnelDescLocal;

  /// No description provided for @tunnelDescRemote.
  ///
  /// In en, this message translates to:
  /// **'Server port → Phone port (expose local services)'**
  String get tunnelDescRemote;

  /// No description provided for @tunnelDescSocks5.
  ///
  /// In en, this message translates to:
  /// **'Start SOCKS5 proxy on phone port (traffic via SSH)'**
  String get tunnelDescSocks5;

  /// No description provided for @labelLocalPort.
  ///
  /// In en, this message translates to:
  /// **'Local Port (phone)'**
  String get labelLocalPort;

  /// No description provided for @invalidTunnelPort.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid port (1–65535)'**
  String get invalidTunnelPort;

  /// No description provided for @labelRemoteHost.
  ///
  /// In en, this message translates to:
  /// **'Remote Host'**
  String get labelRemoteHost;

  /// No description provided for @labelRemotePort.
  ///
  /// In en, this message translates to:
  /// **'Remote Port'**
  String get labelRemotePort;

  /// No description provided for @labelTunnelLabel.
  ///
  /// In en, this message translates to:
  /// **'Label (optional)'**
  String get labelTunnelLabel;

  /// No description provided for @hintTunnelLabel.
  ///
  /// In en, this message translates to:
  /// **'e.g. MySQL 3306'**
  String get hintTunnelLabel;

  /// No description provided for @autoStartTunnel.
  ///
  /// In en, this message translates to:
  /// **'Auto-Connect on Start'**
  String get autoStartTunnel;

  /// No description provided for @autoStartTunnelDesc.
  ///
  /// In en, this message translates to:
  /// **'Auto-reconnect this tunnel on app launch'**
  String get autoStartTunnelDesc;

  /// No description provided for @submitOnce.
  ///
  /// In en, this message translates to:
  /// **'One-time'**
  String get submitOnce;

  /// No description provided for @submitSaveAndStart.
  ///
  /// In en, this message translates to:
  /// **'Save & Start'**
  String get submitSaveAndStart;

  /// No description provided for @tunnelFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String tunnelFailed(String error);

  /// No description provided for @pleaseSelectServer.
  ///
  /// In en, this message translates to:
  /// **'Please select a server'**
  String get pleaseSelectServer;

  /// No description provided for @errorDetected.
  ///
  /// In en, this message translates to:
  /// **'Error detected, AI can help analyze'**
  String get errorDetected;

  /// No description provided for @aiAnalyze.
  ///
  /// In en, this message translates to:
  /// **'AI Analysis'**
  String get aiAnalyze;

  /// No description provided for @aiAnalyzeError.
  ///
  /// In en, this message translates to:
  /// **'Help me analyze this error in the terminal'**
  String get aiAnalyzeError;

  /// No description provided for @aiAnalyzeErrorChip.
  ///
  /// In en, this message translates to:
  /// **'Analyze error'**
  String get aiAnalyzeErrorChip;

  /// No description provided for @moshFallback.
  ///
  /// In en, this message translates to:
  /// **'Mosh fell back to SSH: {message}'**
  String moshFallback(String message);

  /// No description provided for @reconnectInProgress.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting...'**
  String get reconnectInProgress;

  /// No description provided for @refreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing...'**
  String get refreshing;

  /// No description provided for @reconnectSuccess.
  ///
  /// In en, this message translates to:
  /// **'Reconnected'**
  String get reconnectSuccess;

  /// No description provided for @reconnectFailedWithError.
  ///
  /// In en, this message translates to:
  /// **'Reconnect failed: {error}'**
  String reconnectFailedWithError(String error);

  /// No description provided for @reconnectErrTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connection timed out'**
  String get reconnectErrTimeout;

  /// No description provided for @reconnectErrRefused.
  ///
  /// In en, this message translates to:
  /// **'Connection refused'**
  String get reconnectErrRefused;

  /// No description provided for @reconnectErrReset.
  ///
  /// In en, this message translates to:
  /// **'Connection reset'**
  String get reconnectErrReset;

  /// No description provided for @reconnectErrUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Network unreachable'**
  String get reconnectErrUnreachable;

  /// No description provided for @reconnectErrDns.
  ///
  /// In en, this message translates to:
  /// **'DNS lookup failed'**
  String get reconnectErrDns;

  /// No description provided for @reconnectErrAuth.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed'**
  String get reconnectErrAuth;

  /// No description provided for @reconnectErrPermission.
  ///
  /// In en, this message translates to:
  /// **'Permission denied'**
  String get reconnectErrPermission;

  /// No description provided for @reconnectErrSocket.
  ///
  /// In en, this message translates to:
  /// **'Network error'**
  String get reconnectErrSocket;

  /// No description provided for @reconnectRetryCountdown.
  ///
  /// In en, this message translates to:
  /// **'Retrying in {seconds}s (round {round} {attempt}/{total})...'**
  String reconnectRetryCountdown(
    int seconds,
    int round,
    int attempt,
    int total,
  );

  /// No description provided for @reconnectNetworkUnstableRetry.
  ///
  /// In en, this message translates to:
  /// **'Network unstable, retrying in 30s'**
  String get reconnectNetworkUnstableRetry;

  /// No description provided for @reconnectCascadeWarning.
  ///
  /// In en, this message translates to:
  /// **'{protocol}: reconnected {count} times within {minutes} minutes. Network may be unstable.'**
  String reconnectCascadeWarning(String protocol, int count, int minutes);

  /// No description provided for @reconnectLoopDetected.
  ///
  /// In en, this message translates to:
  /// **'{protocol}: reconnect loop detected. Auto reconnect stopped. Refresh manually.'**
  String reconnectLoopDetected(String protocol);

  /// No description provided for @reconnectMoshHandshake.
  ///
  /// In en, this message translates to:
  /// **'Mosh handshaking...'**
  String get reconnectMoshHandshake;

  /// No description provided for @reconnectMoshConnected.
  ///
  /// In en, this message translates to:
  /// **'Mosh SSP connected'**
  String get reconnectMoshConnected;

  /// No description provided for @reconnectMoshFallback.
  ///
  /// In en, this message translates to:
  /// **'Mosh fallback to SSH'**
  String get reconnectMoshFallback;

  /// No description provided for @reconnectMoshFallbackWithReason.
  ///
  /// In en, this message translates to:
  /// **'Mosh fallback to SSH: {reason}'**
  String reconnectMoshFallbackWithReason(String reason);

  /// No description provided for @reconnectMoshDisconnectedRestoring.
  ///
  /// In en, this message translates to:
  /// **'Mosh disconnected, restoring session...'**
  String get reconnectMoshDisconnectedRestoring;

  /// No description provided for @reconnectMoshSessionRestored.
  ///
  /// In en, this message translates to:
  /// **'Mosh session restored'**
  String get reconnectMoshSessionRestored;

  /// No description provided for @reconnectMoshRestoreFailedRehandshake.
  ///
  /// In en, this message translates to:
  /// **'Mosh session restore failed, handshaking again...'**
  String get reconnectMoshRestoreFailedRehandshake;

  /// No description provided for @tmuxNotFoundDisabled.
  ///
  /// In en, this message translates to:
  /// **'tmux not found, disabled automatically'**
  String get tmuxNotFoundDisabled;

  /// No description provided for @enterPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter Password'**
  String get enterPassword;

  /// No description provided for @split.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get split;

  /// No description provided for @tabMove.
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get tabMove;

  /// No description provided for @splitVertical.
  ///
  /// In en, this message translates to:
  /// **'Top-Bottom Split'**
  String get splitVertical;

  /// No description provided for @splitHorizontal.
  ///
  /// In en, this message translates to:
  /// **'Left-Right Split'**
  String get splitHorizontal;

  /// No description provided for @layoutPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get layoutPickerTitle;

  /// No description provided for @layoutSingle.
  ///
  /// In en, this message translates to:
  /// **'Single'**
  String get layoutSingle;

  /// No description provided for @layoutWithCurrent.
  ///
  /// In en, this message translates to:
  /// **'Split · {state}'**
  String layoutWithCurrent(String state);

  /// No description provided for @closeSplit.
  ///
  /// In en, this message translates to:
  /// **'Close Split'**
  String get closeSplit;

  /// No description provided for @floatTerminal.
  ///
  /// In en, this message translates to:
  /// **'Float Terminal'**
  String get floatTerminal;

  /// No description provided for @closeFloat.
  ///
  /// In en, this message translates to:
  /// **'Close Float'**
  String get closeFloat;

  /// No description provided for @saveFavoriteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Save Command'**
  String get saveFavoriteDialogTitle;

  /// No description provided for @favoriteCommandNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Command Name'**
  String get favoriteCommandNameLabel;

  /// No description provided for @commandSaved.
  ///
  /// In en, this message translates to:
  /// **'Command saved'**
  String get commandSaved;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @connectingTo.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {host}…'**
  String connectingTo(String host);

  /// No description provided for @voiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Voice input is currently unavailable'**
  String get voiceUnavailable;

  /// No description provided for @voicePermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Voice Input'**
  String get voicePermissionTitle;

  /// No description provided for @voiceMicrophonePermissionContent.
  ///
  /// In en, this message translates to:
  /// **'Voice input needs microphone permission. Allow FlyTerm to use the microphone in system settings.'**
  String get voiceMicrophonePermissionContent;

  /// No description provided for @voiceSpeechPermissionContent.
  ///
  /// In en, this message translates to:
  /// **'On iPhone/iPad, voice input also needs Speech Recognition permission. Allow FlyTerm to use Speech Recognition in system settings.'**
  String get voiceSpeechPermissionContent;

  /// No description provided for @voiceRecognizerUnavailableContent.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission was checked, but the system speech recognition service is unavailable or disabled. Enable system voice input / voice assistant, or install Google app / a system speech service and try again. If that still doesn\'t work, most keyboards have their own microphone key — it uses the keyboard\'s own recognition, independent of this app.'**
  String get voiceRecognizerUnavailableContent;

  /// No description provided for @voiceNoSpeechContent.
  ///
  /// In en, this message translates to:
  /// **'No speech was detected. Make sure the system microphone toggle is on, this device has a working microphone, and no other app is using it.'**
  String get voiceNoSpeechContent;

  /// No description provided for @voiceBusyContent.
  ///
  /// In en, this message translates to:
  /// **'Speech recognition is busy. Try again later.'**
  String get voiceBusyContent;

  /// No description provided for @voiceNetworkContent.
  ///
  /// In en, this message translates to:
  /// **'Speech recognition needs network access. Check your connection and try again.'**
  String get voiceNetworkContent;

  /// No description provided for @voiceUnknownContent.
  ///
  /// In en, this message translates to:
  /// **'Voice input is temporarily unavailable. Check microphone permission and the system speech recognition service, then try again.'**
  String get voiceUnknownContent;

  /// No description provided for @voiceOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get voiceOpenSettings;

  /// No description provided for @voiceRetry.
  ///
  /// In en, this message translates to:
  /// **'Check Again'**
  String get voiceRetry;

  /// No description provided for @voiceLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get voiceLater;

  /// No description provided for @voiceErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice Input Failed'**
  String get voiceErrorTitle;

  /// No description provided for @voiceErrorHint.
  ///
  /// In en, this message translates to:
  /// **'You can select and copy the text below to report this issue:'**
  String get voiceErrorHint;

  /// No description provided for @voiceCopyDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Copy Diagnostics'**
  String get voiceCopyDiagnostics;

  /// No description provided for @voiceDiagnosticsCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get voiceDiagnosticsCopied;

  /// No description provided for @sftpSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved: {name}'**
  String sftpSaved(String name);

  /// No description provided for @sftpSymlinkTarget.
  ///
  /// In en, this message translates to:
  /// **'→ {target}'**
  String sftpSymlinkTarget(String target);

  /// No description provided for @sftpSymlinkDangling.
  ///
  /// In en, this message translates to:
  /// **'Link target does not exist'**
  String get sftpSymlinkDangling;

  /// No description provided for @sftpErrPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Permission denied. Check the file\'s permissions.'**
  String get sftpErrPermissionDenied;

  /// No description provided for @sftpErrNotFound.
  ///
  /// In en, this message translates to:
  /// **'Path does not exist. It may have been moved or deleted.'**
  String get sftpErrNotFound;

  /// No description provided for @sftpErrDiskFull.
  ///
  /// In en, this message translates to:
  /// **'Not enough space on the remote host.'**
  String get sftpErrDiskFull;

  /// No description provided for @sftpErrDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Connection lost. Reconnect and try again.'**
  String get sftpErrDisconnected;

  /// No description provided for @sftpErrAlreadyExists.
  ///
  /// In en, this message translates to:
  /// **'A file with this name already exists.'**
  String get sftpErrAlreadyExists;

  /// No description provided for @sftpErrRawDetail.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get sftpErrRawDetail;

  /// No description provided for @downloadSavedToPublic.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String downloadSavedToPublic(String path);

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @sftpDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String sftpDownloadFailed(String error);

  /// No description provided for @sftpBatchSelect.
  ///
  /// In en, this message translates to:
  /// **'Batch Select'**
  String get sftpBatchSelect;

  /// No description provided for @sftpDownloadFolder.
  ///
  /// In en, this message translates to:
  /// **'Download Folder'**
  String get sftpDownloadFolder;

  /// No description provided for @sftpDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get sftpDownload;

  /// No description provided for @sftpOpenWithSystem.
  ///
  /// In en, this message translates to:
  /// **'Open with another app'**
  String get sftpOpenWithSystem;

  /// No description provided for @sftpConfirmLargeOpen.
  ///
  /// In en, this message translates to:
  /// **'{name} is {size}. Download it and open with another app?'**
  String sftpConfirmLargeOpen(String name, String size);

  /// No description provided for @sftpOpeningFile.
  ///
  /// In en, this message translates to:
  /// **'Downloading {name}…'**
  String sftpOpeningFile(String name);

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @permissions.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get permissions;

  /// No description provided for @sftpNewName.
  ///
  /// In en, this message translates to:
  /// **'New Name'**
  String get sftpNewName;

  /// No description provided for @sftpConfirmDeleteEntry.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String sftpConfirmDeleteEntry(String name);

  /// No description provided for @sftpNewFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get sftpNewFolderTitle;

  /// No description provided for @sftpFolderName.
  ///
  /// In en, this message translates to:
  /// **'Folder Name'**
  String get sftpFolderName;

  /// No description provided for @sftpNewFileTitle.
  ///
  /// In en, this message translates to:
  /// **'New File'**
  String get sftpNewFileTitle;

  /// No description provided for @sftpFileName.
  ///
  /// In en, this message translates to:
  /// **'File Name'**
  String get sftpFileName;

  /// No description provided for @sftpJumpToPath.
  ///
  /// In en, this message translates to:
  /// **'Jump to Path'**
  String get sftpJumpToPath;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @jump.
  ///
  /// In en, this message translates to:
  /// **'Jump'**
  String get jump;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @sftpPermissionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Permissions — {name}'**
  String sftpPermissionsTitle(String name);

  /// No description provided for @sftpOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get sftpOwner;

  /// No description provided for @sftpGroup.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get sftpGroup;

  /// No description provided for @sftpOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get sftpOther;

  /// No description provided for @sftpRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get sftpRead;

  /// No description provided for @sftpWrite.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get sftpWrite;

  /// No description provided for @sftpExecute.
  ///
  /// In en, this message translates to:
  /// **'Exec'**
  String get sftpExecute;

  /// No description provided for @sftpSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String sftpSelectedCount(int count);

  /// No description provided for @sftpSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get sftpSelectAll;

  /// No description provided for @sftpSelectedItems.
  ///
  /// In en, this message translates to:
  /// **'{count} items selected'**
  String sftpSelectedItems(int count);

  /// No description provided for @sftpScanningFiles.
  ///
  /// In en, this message translates to:
  /// **'Scanning... {count} files found'**
  String sftpScanningFiles(int count);

  /// No description provided for @sftpUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading {filename}'**
  String sftpUploading(String filename);

  /// No description provided for @sftpEmptyDirectory.
  ///
  /// In en, this message translates to:
  /// **'Empty Directory'**
  String get sftpEmptyDirectory;

  /// No description provided for @sftpRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed: {error}'**
  String sftpRenameFailed(String error);

  /// No description provided for @sftpDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String sftpDeleteFailed(String error);

  /// No description provided for @sftpCreateFailed.
  ///
  /// In en, this message translates to:
  /// **'Create failed: {error}'**
  String sftpCreateFailed(String error);

  /// No description provided for @sftpChmodFailed.
  ///
  /// In en, this message translates to:
  /// **'chmod failed: {error}'**
  String sftpChmodFailed(String error);

  /// No description provided for @sftpDownloadsCompleted.
  ///
  /// In en, this message translates to:
  /// **'{count} download(s) complete'**
  String sftpDownloadsCompleted(int count);

  /// No description provided for @sftpConfirmDeleteSelected.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} selected items? This cannot be undone.'**
  String sftpConfirmDeleteSelected(int count);

  /// No description provided for @sftpCreateFolderAction.
  ///
  /// In en, this message translates to:
  /// **'New Directory'**
  String get sftpCreateFolderAction;

  /// No description provided for @sftpCreateFileAction.
  ///
  /// In en, this message translates to:
  /// **'New File'**
  String get sftpCreateFileAction;

  /// No description provided for @sftpUploadFileAction.
  ///
  /// In en, this message translates to:
  /// **'Upload File'**
  String get sftpUploadFileAction;

  /// No description provided for @sftpUploadFolderAction.
  ///
  /// In en, this message translates to:
  /// **'Upload folder'**
  String get sftpUploadFolderAction;

  /// No description provided for @sftpConflictTitle.
  ///
  /// In en, this message translates to:
  /// **'{count} file(s) already exist'**
  String sftpConflictTitle(int count);

  /// No description provided for @sftpConflictBody.
  ///
  /// In en, this message translates to:
  /// **'Uploading will overwrite them. This cannot be undone.'**
  String get sftpConflictBody;

  /// No description provided for @sftpConflictOverwriteAll.
  ///
  /// In en, this message translates to:
  /// **'Overwrite all'**
  String get sftpConflictOverwriteAll;

  /// No description provided for @sftpConflictSkipAll.
  ///
  /// In en, this message translates to:
  /// **'Skip existing'**
  String get sftpConflictSkipAll;

  /// No description provided for @sftpConflictSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped {count} existing file(s)'**
  String sftpConflictSkipped(int count);

  /// No description provided for @aiAssistant.
  ///
  /// In en, this message translates to:
  /// **'AI Assistant'**
  String get aiAssistant;

  /// No description provided for @aiMicUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice Input Unavailable'**
  String get aiMicUnavailableTitle;

  /// No description provided for @aiMicUnavailableContent.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission not granted or device does not support speech recognition.\n\nGo to phone Settings → Apps → FlyTerm → Permissions, enable microphone, then reopen the app.'**
  String get aiMicUnavailableContent;

  /// No description provided for @aiNoProvider.
  ///
  /// In en, this message translates to:
  /// **'No AI provider configured. Go to Settings → AI Providers to add one.'**
  String get aiNoProvider;

  /// No description provided for @aiEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Describe the operation you want to perform, AI will generate a command for one-tap execution.\n\nExample: Find the process using the most memory'**
  String get aiEmptyHint;

  /// No description provided for @aiGoConfig.
  ///
  /// In en, this message translates to:
  /// **'Configure →'**
  String get aiGoConfig;

  /// No description provided for @aiListeningHint.
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get aiListeningHint;

  /// No description provided for @aiInputHint.
  ///
  /// In en, this message translates to:
  /// **'Describe operation or ask a question…'**
  String get aiInputHint;

  /// No description provided for @aiClearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear conversation'**
  String get aiClearHistory;

  /// No description provided for @aiNewSession.
  ///
  /// In en, this message translates to:
  /// **'New session'**
  String get aiNewSession;

  /// No description provided for @aiMoreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get aiMoreActions;

  /// No description provided for @aiSessionHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get aiSessionHistory;

  /// No description provided for @aiHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No archived sessions yet'**
  String get aiHistoryEmpty;

  /// No description provided for @aiHistorySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search titles'**
  String get aiHistorySearchHint;

  /// No description provided for @aiHistoryNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No sessions match'**
  String get aiHistoryNoMatch;

  /// Explains that older unstarred sessions are pruned, so sessions vanishing is a known rule rather than a bug.
  ///
  /// In en, this message translates to:
  /// **'Most recent {keep} per server; starred are kept beyond that.'**
  String aiHistoryQuotaHint(int keep);

  /// No description provided for @aiHistoryEvents.
  ///
  /// In en, this message translates to:
  /// **'{count} entries'**
  String aiHistoryEvents(int count);

  /// No description provided for @aiHistoryUntitled.
  ///
  /// In en, this message translates to:
  /// **'(untitled)'**
  String get aiHistoryUntitled;

  /// No description provided for @aiHistoryDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this session?'**
  String get aiHistoryDeleteTitle;

  /// No description provided for @aiHistoryDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get aiHistoryDelete;

  /// No description provided for @aiCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get aiCopyAction;

  /// No description provided for @aiMessageCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get aiMessageCopied;

  /// No description provided for @aiRetryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get aiRetryAction;

  /// No description provided for @aiEditAction.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get aiEditAction;

  /// No description provided for @aiExplainAction.
  ///
  /// In en, this message translates to:
  /// **'Explain'**
  String get aiExplainAction;

  /// No description provided for @aiSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get aiSaveAction;

  /// No description provided for @aiRunAction.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get aiRunAction;

  /// No description provided for @aiCommandFailed.
  ///
  /// In en, this message translates to:
  /// **'Command failed'**
  String get aiCommandFailed;

  /// No description provided for @aiOutputLines.
  ///
  /// In en, this message translates to:
  /// **'{count} lines'**
  String aiOutputLines(int count);

  /// No description provided for @aiGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get aiGotIt;

  /// No description provided for @favoritesTitle.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favoritesTitle;

  /// No description provided for @addFavoriteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add Favorite'**
  String get addFavoriteTooltip;

  /// No description provided for @noFavorites.
  ///
  /// In en, this message translates to:
  /// **'No saved commands\nTap + to add'**
  String get noFavorites;

  /// No description provided for @editFavoriteTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Favorite Command'**
  String get editFavoriteTitle;

  /// No description provided for @addFavoriteTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Favorite Command'**
  String get addFavoriteTitle;

  /// No description provided for @favoriteName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get favoriteName;

  /// No description provided for @favoriteNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Update System'**
  String get favoriteNameHint;

  /// No description provided for @favoriteCommand.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get favoriteCommand;

  /// No description provided for @favoriteCommandHint.
  ///
  /// In en, this message translates to:
  /// **'Supports template variables'**
  String get favoriteCommandHint;

  /// No description provided for @favoriteRun.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get favoriteRun;

  /// No description provided for @favoriteAiEnabled.
  ///
  /// In en, this message translates to:
  /// **'Let the assistant run this'**
  String get favoriteAiEnabled;

  /// No description provided for @favoriteAiEnabledHint.
  ///
  /// In en, this message translates to:
  /// **'The assistant will see this command\'s name and template'**
  String get favoriteAiEnabledHint;

  /// No description provided for @favoriteAiBudget.
  ///
  /// In en, this message translates to:
  /// **'{count} available to the assistant, about {tokens} tokens per request'**
  String favoriteAiBudget(int count, int tokens);

  /// No description provided for @favoriteAiOverflow.
  ///
  /// In en, this message translates to:
  /// **'{count} are over the limit and will not be offered'**
  String favoriteAiOverflow(int count);

  /// No description provided for @sftpDownloadDir.
  ///
  /// In en, this message translates to:
  /// **'Download Directory'**
  String get sftpDownloadDir;

  /// No description provided for @sftpDownloadDirDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads (public, visible in Files app)'**
  String get sftpDownloadDirDownloads;

  /// No description provided for @sftpDownloadDirDocuments.
  ///
  /// In en, this message translates to:
  /// **'Documents'**
  String get sftpDownloadDirDocuments;

  /// No description provided for @sftpDownloadDirCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom Path'**
  String get sftpDownloadDirCustom;

  /// No description provided for @sftpCustomPathHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. /storage/emulated/0/MyFolder'**
  String get sftpCustomPathHint;

  /// No description provided for @searchServers.
  ///
  /// In en, this message translates to:
  /// **'Search servers…'**
  String get searchServers;

  /// No description provided for @noSearchResults.
  ///
  /// In en, this message translates to:
  /// **'No matching servers'**
  String get noSearchResults;

  /// No description provided for @serverGroup.
  ///
  /// In en, this message translates to:
  /// **'Group (optional)'**
  String get serverGroup;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @terminalTheme.
  ///
  /// In en, this message translates to:
  /// **'Terminal Theme'**
  String get terminalTheme;

  /// No description provided for @terminalThemeDefault.
  ///
  /// In en, this message translates to:
  /// **'Default Dark'**
  String get terminalThemeDefault;

  /// No description provided for @terminalThemeDracula.
  ///
  /// In en, this message translates to:
  /// **'Dracula'**
  String get terminalThemeDracula;

  /// No description provided for @terminalThemeSolarizedDark.
  ///
  /// In en, this message translates to:
  /// **'Solarized Dark'**
  String get terminalThemeSolarizedDark;

  /// No description provided for @terminalThemeMonokai.
  ///
  /// In en, this message translates to:
  /// **'Monokai'**
  String get terminalThemeMonokai;

  /// No description provided for @terminalThemeSolarizedLight.
  ///
  /// In en, this message translates to:
  /// **'Solarized Light'**
  String get terminalThemeSolarizedLight;

  /// No description provided for @terminalThemeNord.
  ///
  /// In en, this message translates to:
  /// **'Nord'**
  String get terminalThemeNord;

  /// No description provided for @terminalThemeGruvboxDark.
  ///
  /// In en, this message translates to:
  /// **'Gruvbox Dark'**
  String get terminalThemeGruvboxDark;

  /// No description provided for @terminalThemeOneDark.
  ///
  /// In en, this message translates to:
  /// **'One Dark'**
  String get terminalThemeOneDark;

  /// No description provided for @terminalThemeTokyoNight.
  ///
  /// In en, this message translates to:
  /// **'Tokyo Night'**
  String get terminalThemeTokyoNight;

  /// No description provided for @cursorBlink.
  ///
  /// In en, this message translates to:
  /// **'Blinking Cursor'**
  String get cursorBlink;

  /// No description provided for @cursorBlinkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Blink the cursor when the terminal has focus'**
  String get cursorBlinkSubtitle;

  /// No description provided for @selectionColor.
  ///
  /// In en, this message translates to:
  /// **'Selection Color'**
  String get selectionColor;

  /// No description provided for @selectionColorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Highlight color for selected text'**
  String get selectionColorSubtitle;

  /// No description provided for @keybarCustomize.
  ///
  /// In en, this message translates to:
  /// **'KeyBar Customization'**
  String get keybarCustomize;

  /// No description provided for @keybarCustomizeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Reorder, edit, or add keys'**
  String get keybarCustomizeSubtitle;

  /// No description provided for @fetSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'SFTP Toggle Button'**
  String get fetSettingsTitle;

  /// No description provided for @fetSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Floating button to switch terminal / SFTP view'**
  String get fetSettingsSubtitle;

  /// No description provided for @fetSettingsShow.
  ///
  /// In en, this message translates to:
  /// **'Show toggle button'**
  String get fetSettingsShow;

  /// No description provided for @fetSettingsShowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Floating button on the right side of the terminal'**
  String get fetSettingsShowSubtitle;

  /// No description provided for @fetSettingsAutoHide.
  ///
  /// In en, this message translates to:
  /// **'Auto-hide to edge'**
  String get fetSettingsAutoHide;

  /// No description provided for @fetSettingsAutoHideSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Collapses to a thin bar after 7 s of inactivity'**
  String get fetSettingsAutoHideSubtitle;

  /// No description provided for @fetSettingsOpacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get fetSettingsOpacity;

  /// No description provided for @fetSettingsResetPosition.
  ///
  /// In en, this message translates to:
  /// **'Reset position'**
  String get fetSettingsResetPosition;

  /// No description provided for @fetSettingsResetPositionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Return button to centre of screen'**
  String get fetSettingsResetPositionSubtitle;

  /// No description provided for @fetSettingsResetDone.
  ///
  /// In en, this message translates to:
  /// **'Toggle button position reset'**
  String get fetSettingsResetDone;

  /// No description provided for @sftpSwitchToSftp.
  ///
  /// In en, this message translates to:
  /// **'Switch to SFTP'**
  String get sftpSwitchToSftp;

  /// No description provided for @sftpSwitchToTerminal.
  ///
  /// In en, this message translates to:
  /// **'Back to Terminal'**
  String get sftpSwitchToTerminal;

  /// No description provided for @sftpOnboardingHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to switch SFTP/terminal, drag to reposition, fling right to hide'**
  String get sftpOnboardingHint;

  /// No description provided for @keybarLongPressEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get keybarLongPressEdit;

  /// No description provided for @keybarLongPressDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get keybarLongPressDelete;

  /// No description provided for @keybarEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Long-press a key or open Settings → KeyBar to add keys'**
  String get keybarEmptyHint;

  /// No description provided for @keybarEditorTitle.
  ///
  /// In en, this message translates to:
  /// **'KeyBar Customization'**
  String get keybarEditorTitle;

  /// No description provided for @keybarEditorAddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add new key'**
  String get keybarEditorAddTooltip;

  /// No description provided for @keybarEditorRestoreDefaults.
  ///
  /// In en, this message translates to:
  /// **'Restore defaults'**
  String get keybarEditorRestoreDefaults;

  /// No description provided for @keybarEditorConfirmRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore default KeyBar?'**
  String get keybarEditorConfirmRestoreTitle;

  /// No description provided for @keybarEditorConfirmRestoreBody.
  ///
  /// In en, this message translates to:
  /// **'All custom keys will be removed.'**
  String get keybarEditorConfirmRestoreBody;

  /// No description provided for @keybarEditorConfirmRestoreOk.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get keybarEditorConfirmRestoreOk;

  /// No description provided for @keybarEditorConfirmRestoreCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get keybarEditorConfirmRestoreCancel;

  /// No description provided for @keybarEditItemTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Key'**
  String get keybarEditItemTitle;

  /// No description provided for @keybarEditItemNew.
  ///
  /// In en, this message translates to:
  /// **'New Key'**
  String get keybarEditItemNew;

  /// No description provided for @keybarEditItemLabel.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get keybarEditItemLabel;

  /// No description provided for @keybarEditItemSequence.
  ///
  /// In en, this message translates to:
  /// **'Sequence'**
  String get keybarEditItemSequence;

  /// No description provided for @keybarEditItemInsertSpecial.
  ///
  /// In en, this message translates to:
  /// **'Insert special key'**
  String get keybarEditItemInsertSpecial;

  /// No description provided for @keybarEditItemRepeatable.
  ///
  /// In en, this message translates to:
  /// **'Long-press auto-repeat'**
  String get keybarEditItemRepeatable;

  /// No description provided for @keybarEditItemSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get keybarEditItemSave;

  /// No description provided for @keybarEditItemValidationLabel.
  ///
  /// In en, this message translates to:
  /// **'Label cannot be empty'**
  String get keybarEditItemValidationLabel;

  /// No description provided for @keybarEditItemValidationSequence.
  ///
  /// In en, this message translates to:
  /// **'Sequence cannot be empty'**
  String get keybarEditItemValidationSequence;

  /// No description provided for @keybarSpecialPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Insert Special Key'**
  String get keybarSpecialPickerTitle;

  /// No description provided for @keybarSpecialCategoryControl.
  ///
  /// In en, this message translates to:
  /// **'Control'**
  String get keybarSpecialCategoryControl;

  /// No description provided for @keybarSpecialCategoryModifiers.
  ///
  /// In en, this message translates to:
  /// **'Modifiers'**
  String get keybarSpecialCategoryModifiers;

  /// No description provided for @keybarSpecialCategoryArrows.
  ///
  /// In en, this message translates to:
  /// **'Arrows'**
  String get keybarSpecialCategoryArrows;

  /// No description provided for @keybarSpecialCategoryNav.
  ///
  /// In en, this message translates to:
  /// **'Navigation'**
  String get keybarSpecialCategoryNav;

  /// No description provided for @keybarSpecialCategoryModifierCombos.
  ///
  /// In en, this message translates to:
  /// **'Modifier Combos'**
  String get keybarSpecialCategoryModifierCombos;

  /// No description provided for @keybarSpecialCategoryFunction.
  ///
  /// In en, this message translates to:
  /// **'Function Keys'**
  String get keybarSpecialCategoryFunction;

  /// No description provided for @keybarSpecialCategoryCtrl.
  ///
  /// In en, this message translates to:
  /// **'Ctrl Combos'**
  String get keybarSpecialCategoryCtrl;

  /// No description provided for @keybarEditItemSequenceHint.
  ///
  /// In en, this message translates to:
  /// **'Type text…'**
  String get keybarEditItemSequenceHint;

  /// No description provided for @keybarEditItemSticky.
  ///
  /// In en, this message translates to:
  /// **'Sticky modifier (CTRL-style)'**
  String get keybarEditItemSticky;

  /// No description provided for @keybarEditItemStickyHint.
  ///
  /// In en, this message translates to:
  /// **'Toggles a transient flag instead of sending bytes; the next keypress is sent with Ctrl applied.'**
  String get keybarEditItemStickyHint;

  /// No description provided for @keybarCtrlNotApplicable.
  ///
  /// In en, this message translates to:
  /// **'CTRL doesn\'t apply to this key'**
  String get keybarCtrlNotApplicable;

  /// No description provided for @keybarShiftNotApplicable.
  ///
  /// In en, this message translates to:
  /// **'SHIFT doesn\'t apply to this key'**
  String get keybarShiftNotApplicable;

  /// No description provided for @keybarEditorSectionKeyboardMode.
  ///
  /// In en, this message translates to:
  /// **'Keyboard Show'**
  String get keybarEditorSectionKeyboardMode;

  /// No description provided for @keybarEditorSectionLeftKeys.
  ///
  /// In en, this message translates to:
  /// **'Terminal Keys'**
  String get keybarEditorSectionLeftKeys;

  /// No description provided for @keybarEditorSectionRightButtons.
  ///
  /// In en, this message translates to:
  /// **'Function Buttons'**
  String get keybarEditorSectionRightButtons;

  /// No description provided for @keybarRightButtonKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get keybarRightButtonKeyboard;

  /// No description provided for @keybarRightButtonFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get keybarRightButtonFavorites;

  /// No description provided for @keybarRightButtonMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get keybarRightButtonMicrophone;

  /// No description provided for @keybarRightButtonAi.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get keybarRightButtonAi;

  /// No description provided for @keybarRightButtonAttachFile.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get keybarRightButtonAttachFile;

  /// No description provided for @attachFileNoConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection unavailable — reconnect and try again'**
  String get attachFileNoConnection;

  /// No description provided for @attachFileNameTaken.
  ///
  /// In en, this message translates to:
  /// **'Too many files with that name — clean up first'**
  String get attachFileNameTaken;

  /// No description provided for @attachFileFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed: {error}'**
  String attachFileFailed(String error);

  /// No description provided for @attachFileRenamed.
  ///
  /// In en, this message translates to:
  /// **'Name had special characters — renamed to {name}'**
  String attachFileRenamed(String name);

  /// No description provided for @agentForwarding.
  ///
  /// In en, this message translates to:
  /// **'SSH Agent Forwarding'**
  String get agentForwarding;

  /// No description provided for @agentForwardingDesc.
  ///
  /// In en, this message translates to:
  /// **'Allow remote host to use local keys for next-hop auth'**
  String get agentForwardingDesc;

  /// No description provided for @importConfigPreviewSkills.
  ///
  /// In en, this message translates to:
  /// **'AI skills'**
  String get importConfigPreviewSkills;

  /// No description provided for @exportConfigSubject.
  ///
  /// In en, this message translates to:
  /// **'FlyTerm config backup'**
  String get exportConfigSubject;

  /// No description provided for @exportConfigDone.
  ///
  /// In en, this message translates to:
  /// **'Exported: {path}'**
  String exportConfigDone(String path);

  /// No description provided for @exportConfigFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportConfigFailed(String error);

  /// No description provided for @importConfigFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String importConfigFailed(String error);

  /// No description provided for @importConfigDone.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} items'**
  String importConfigDone(int count);

  /// No description provided for @exportConfigEmpty.
  ///
  /// In en, this message translates to:
  /// **'(empty config)'**
  String get exportConfigEmpty;

  /// No description provided for @exportConfigIncludeAi.
  ///
  /// In en, this message translates to:
  /// **'Include AI provider config'**
  String get exportConfigIncludeAi;

  /// No description provided for @exportConfigIncludeAiDesc.
  ///
  /// In en, this message translates to:
  /// **'Turn off to exclude provider config (API keys are never backed up)'**
  String get exportConfigIncludeAiDesc;

  /// No description provided for @exportConfigIncludeKnowledge.
  ///
  /// In en, this message translates to:
  /// **'Include AI knowledge & notes'**
  String get exportConfigIncludeKnowledge;

  /// No description provided for @exportConfigIncludeKnowledgeDesc.
  ///
  /// In en, this message translates to:
  /// **'Skill library and per-machine agent notes. May be large'**
  String get exportConfigIncludeKnowledgeDesc;

  /// No description provided for @importConfigKeepAppearance.
  ///
  /// In en, this message translates to:
  /// **'Keep my current appearance'**
  String get importConfigKeepAppearance;

  /// No description provided for @importConfigKeepAppearanceDesc.
  ///
  /// In en, this message translates to:
  /// **'Do not overwrite theme, font, or KeyBar layout'**
  String get importConfigKeepAppearanceDesc;

  /// No description provided for @importConfigPreviewSshKeysNotIncluded.
  ///
  /// In en, this message translates to:
  /// **'SSH private keys are not in the backup — re-import them after this to connect with those keys'**
  String get importConfigPreviewSshKeysNotIncluded;

  /// No description provided for @exportConfigCountServers.
  ///
  /// In en, this message translates to:
  /// **'{count} servers'**
  String exportConfigCountServers(int count);

  /// No description provided for @exportConfigCountKeys.
  ///
  /// In en, this message translates to:
  /// **'{count} keys'**
  String exportConfigCountKeys(int count);

  /// No description provided for @exportConfigCountFavCmds.
  ///
  /// In en, this message translates to:
  /// **'{count} favorites'**
  String exportConfigCountFavCmds(int count);

  /// No description provided for @exportConfigCountAi.
  ///
  /// In en, this message translates to:
  /// **'{count} AI configs'**
  String exportConfigCountAi(int count);

  /// No description provided for @exportConfigCountTunnels.
  ///
  /// In en, this message translates to:
  /// **'{count} tunnels'**
  String exportConfigCountTunnels(int count);

  /// No description provided for @exportConfigCountKnownHosts.
  ///
  /// In en, this message translates to:
  /// **'{count} known hosts'**
  String exportConfigCountKnownHosts(int count);

  /// No description provided for @exportConfigCountNotes.
  ///
  /// In en, this message translates to:
  /// **'{count} machine notes'**
  String exportConfigCountNotes(int count);

  /// No description provided for @exportConfigCountSkills.
  ///
  /// In en, this message translates to:
  /// **'{count} AI skills'**
  String exportConfigCountSkills(int count);

  /// No description provided for @exportConfig.
  ///
  /// In en, this message translates to:
  /// **'Export Config'**
  String get exportConfig;

  /// No description provided for @exportConfigSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Save servers & keys to a JSON file'**
  String get exportConfigSubtitle;

  /// No description provided for @importConfig.
  ///
  /// In en, this message translates to:
  /// **'Import Config'**
  String get importConfig;

  /// No description provided for @importConfigSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Restore from a previously exported JSON'**
  String get importConfigSubtitle;

  /// No description provided for @exportConfigSendToDevice.
  ///
  /// In en, this message translates to:
  /// **'Send to another device'**
  String get exportConfigSendToDevice;

  /// No description provided for @exportConfigSaveLocal.
  ///
  /// In en, this message translates to:
  /// **'Save to downloads'**
  String get exportConfigSaveLocal;

  /// No description provided for @exportConfigHasAiKeys.
  ///
  /// In en, this message translates to:
  /// **'⚠ AI API keys are NOT exported — re-enter them after importing'**
  String get exportConfigHasAiKeys;

  /// No description provided for @importConfigPreviewKnownHosts.
  ///
  /// In en, this message translates to:
  /// **'Known Hosts'**
  String get importConfigPreviewKnownHosts;

  /// No description provided for @importConfigPreviewKeybarWarning.
  ///
  /// In en, this message translates to:
  /// **'⚠ The on-screen key bar will be overwritten'**
  String get importConfigPreviewKeybarWarning;

  /// No description provided for @importConfigPreviewAiKeysNotIncluded.
  ///
  /// In en, this message translates to:
  /// **'⚠ AI API keys are not included — re-enter them after importing'**
  String get importConfigPreviewAiKeysNotIncluded;

  /// No description provided for @exportConfigNeverBackedUp.
  ///
  /// In en, this message translates to:
  /// **'Never backed up'**
  String get exportConfigNeverBackedUp;

  /// No description provided for @exportConfigLastBackup.
  ///
  /// In en, this message translates to:
  /// **'Last backup: {timeAgo}'**
  String exportConfigLastBackup(String timeAgo);

  /// No description provided for @importConfigPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Preview'**
  String get importConfigPreviewTitle;

  /// No description provided for @importConfigPreviewServers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get importConfigPreviewServers;

  /// No description provided for @importConfigPreviewKeys.
  ///
  /// In en, this message translates to:
  /// **'SSH Keys'**
  String get importConfigPreviewKeys;

  /// No description provided for @importConfigPreviewFavCmds.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get importConfigPreviewFavCmds;

  /// No description provided for @importConfigPreviewAiProviders.
  ///
  /// In en, this message translates to:
  /// **'AI Configs'**
  String get importConfigPreviewAiProviders;

  /// No description provided for @importConfigPreviewTunnels.
  ///
  /// In en, this message translates to:
  /// **'Tunnels'**
  String get importConfigPreviewTunnels;

  /// No description provided for @importConfigPreviewNew.
  ///
  /// In en, this message translates to:
  /// **'{count} (all new)'**
  String importConfigPreviewNew(int count);

  /// No description provided for @importConfigPreviewWithSkip.
  ///
  /// In en, this message translates to:
  /// **'{newCount} new, {skipCount} duplicate(s) skipped'**
  String importConfigPreviewWithSkip(int newCount, int skipCount);

  /// No description provided for @importConfigPreviewSettingsWarning.
  ///
  /// In en, this message translates to:
  /// **'⚠ Terminal settings (theme, font size) will be overwritten'**
  String get importConfigPreviewSettingsWarning;

  /// No description provided for @importConfigConfirm.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importConfigConfirm;

  /// No description provided for @importConfigSuccessWithSkip.
  ///
  /// In en, this message translates to:
  /// **'Imported {newCount} items, {skipCount} duplicate(s) skipped'**
  String importConfigSuccessWithSkip(int newCount, int skipCount);

  /// No description provided for @sessionSummary.
  ///
  /// In en, this message translates to:
  /// **'Session Summary'**
  String get sessionSummary;

  /// No description provided for @sessionSummaryPrompt.
  ///
  /// In en, this message translates to:
  /// **'Please summarize what was done in this terminal session: key commands run, what succeeded or failed, and the current state.'**
  String get sessionSummaryPrompt;

  /// No description provided for @sftpSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search files…'**
  String get sftpSearchHint;

  /// No description provided for @sftpSortByName.
  ///
  /// In en, this message translates to:
  /// **'Sort by name'**
  String get sftpSortByName;

  /// No description provided for @sftpSortBySize.
  ///
  /// In en, this message translates to:
  /// **'Sort by size'**
  String get sftpSortBySize;

  /// No description provided for @sftpSortByTime.
  ///
  /// In en, this message translates to:
  /// **'Sort by time'**
  String get sftpSortByTime;

  /// No description provided for @sftpSortAscending.
  ///
  /// In en, this message translates to:
  /// **'Ascending'**
  String get sftpSortAscending;

  /// No description provided for @sftpSortDescending.
  ///
  /// In en, this message translates to:
  /// **'Descending'**
  String get sftpSortDescending;

  /// No description provided for @sftpSortToggleToDesc.
  ///
  /// In en, this message translates to:
  /// **'Switch to descending'**
  String get sftpSortToggleToDesc;

  /// No description provided for @sftpSortToggleToAsc.
  ///
  /// In en, this message translates to:
  /// **'Switch to ascending'**
  String get sftpSortToggleToAsc;

  /// No description provided for @sftpSortDirectionLabel.
  ///
  /// In en, this message translates to:
  /// **'Order'**
  String get sftpSortDirectionLabel;

  /// No description provided for @sftpSortTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get sftpSortTooltip;

  /// No description provided for @sftpResuming.
  ///
  /// In en, this message translates to:
  /// **'Resuming {filename}'**
  String sftpResuming(String filename);

  /// No description provided for @tabRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get tabRefresh;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @versionSubtitleDebugActive.
  ///
  /// In en, this message translates to:
  /// **'{version} · Debug panel active (tap repeatedly to toggle)'**
  String versionSubtitleDebugActive(String version);

  /// No description provided for @debugOverlayEnabled.
  ///
  /// In en, this message translates to:
  /// **'Debug panel enabled'**
  String get debugOverlayEnabled;

  /// No description provided for @debugOverlayDisabled.
  ///
  /// In en, this message translates to:
  /// **'Debug panel disabled'**
  String get debugOverlayDisabled;

  /// No description provided for @debugOverlayTapsRemaining.
  ///
  /// In en, this message translates to:
  /// **'Tap {count} more to toggle debug panel'**
  String debugOverlayTapsRemaining(int count);

  /// No description provided for @keyboardTrigger.
  ///
  /// In en, this message translates to:
  /// **'Keyboard Trigger'**
  String get keyboardTrigger;

  /// No description provided for @keyboardTriggerSingleTap.
  ///
  /// In en, this message translates to:
  /// **'Single Tap'**
  String get keyboardTriggerSingleTap;

  /// No description provided for @keyboardTriggerSingleTapDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap the terminal area to open keyboard'**
  String get keyboardTriggerSingleTapDesc;

  /// No description provided for @keyboardTriggerDoubleTap.
  ///
  /// In en, this message translates to:
  /// **'Double Tap'**
  String get keyboardTriggerDoubleTap;

  /// No description provided for @keyboardTriggerDoubleTapDesc.
  ///
  /// In en, this message translates to:
  /// **'Double-tap the terminal area to open keyboard'**
  String get keyboardTriggerDoubleTapDesc;

  /// No description provided for @keyboardTriggerIconButton.
  ///
  /// In en, this message translates to:
  /// **'Icon Button'**
  String get keyboardTriggerIconButton;

  /// No description provided for @keyboardTriggerIconButtonDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap toolbar keyboard icon to open keyboard'**
  String get keyboardTriggerIconButtonDesc;

  /// No description provided for @selectionCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get selectionCopy;

  /// No description provided for @selectionCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied {count} characters'**
  String selectionCopied(int count);

  /// No description provided for @selectionExpired.
  ///
  /// In en, this message translates to:
  /// **'Selection is no longer valid — select again'**
  String get selectionExpired;

  /// No description provided for @selectionSelect.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get selectionSelect;

  /// No description provided for @selectionPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get selectionPaste;

  /// No description provided for @pasteClipboardEmpty.
  ///
  /// In en, this message translates to:
  /// **'Clipboard is empty'**
  String get pasteClipboardEmpty;

  /// No description provided for @pasteNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected — cannot paste'**
  String get pasteNotConnected;

  /// No description provided for @pasteTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Clipboard content too large ({size}) — paste cancelled'**
  String pasteTooLarge(String size);

  /// No description provided for @fontSection.
  ///
  /// In en, this message translates to:
  /// **'Terminal Font'**
  String get fontSection;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get fontSize;

  /// No description provided for @codeFont.
  ///
  /// In en, this message translates to:
  /// **'Code Font'**
  String get codeFont;

  /// No description provided for @codeFontDesc.
  ///
  /// In en, this message translates to:
  /// **'Letters, digits, and symbols'**
  String get codeFontDesc;

  /// No description provided for @fontFamilySystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get fontFamilySystem;

  /// No description provided for @lineHeight.
  ///
  /// In en, this message translates to:
  /// **'Line Spacing'**
  String get lineHeight;

  /// No description provided for @lineHeightDesc.
  ///
  /// In en, this message translates to:
  /// **'Space between lines (larger = more breathing room)'**
  String get lineHeightDesc;

  /// No description provided for @serverTypeSshMosh.
  ///
  /// In en, this message translates to:
  /// **'SSH / Mosh'**
  String get serverTypeSshMosh;

  /// No description provided for @serverTypeRemote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get serverTypeRemote;

  /// No description provided for @serverTypeLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get serverTypeLocal;

  /// No description provided for @localShellUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Local terminal is not available on this platform — connect to a remote server instead.'**
  String get localShellUnsupported;

  /// No description provided for @ungrouped.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get ungrouped;

  /// No description provided for @consentTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to FlyTerm'**
  String get consentTitle;

  /// No description provided for @consentIntro.
  ///
  /// In en, this message translates to:
  /// **'Before using the App, please read and agree to:'**
  String get consentIntro;

  /// No description provided for @consentPrivacyLink.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get consentPrivacyLink;

  /// No description provided for @consentTosLink.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get consentTosLink;

  /// No description provided for @consentCrashOptIn.
  ///
  /// In en, this message translates to:
  /// **'Send crash reports to help fix bugs (toggle in Settings)'**
  String get consentCrashOptIn;

  /// No description provided for @consentAcceptButton.
  ///
  /// In en, this message translates to:
  /// **'Agree and Continue'**
  String get consentAcceptButton;

  /// No description provided for @consentDeclineButton.
  ///
  /// In en, this message translates to:
  /// **'Decline and Exit'**
  String get consentDeclineButton;

  /// No description provided for @privacyPolicyTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicyTitle;

  /// No description provided for @termsOfServiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get termsOfServiceTitle;

  /// No description provided for @privacyPreferences.
  ///
  /// In en, this message translates to:
  /// **'Privacy Preferences'**
  String get privacyPreferences;

  /// No description provided for @privacyCrashReportingToggle.
  ///
  /// In en, this message translates to:
  /// **'Crash Reporting'**
  String get privacyCrashReportingToggle;

  /// No description provided for @privacyCrashReportingDesc.
  ///
  /// In en, this message translates to:
  /// **'Upload crash stacks to help fix bugs (scrubbed, no host info)'**
  String get privacyCrashReportingDesc;

  /// No description provided for @privacyAnalyticsToggle.
  ///
  /// In en, this message translates to:
  /// **'Usage Analytics'**
  String get privacyAnalyticsToggle;

  /// No description provided for @privacyAnalyticsDesc.
  ///
  /// In en, this message translates to:
  /// **'Upload key business events for product improvement'**
  String get privacyAnalyticsDesc;

  /// No description provided for @privacyViewPolicy.
  ///
  /// In en, this message translates to:
  /// **'View Privacy Policy'**
  String get privacyViewPolicy;

  /// No description provided for @privacyViewToS.
  ///
  /// In en, this message translates to:
  /// **'View Terms of Service'**
  String get privacyViewToS;

  /// No description provided for @privacyRevokeButton.
  ///
  /// In en, this message translates to:
  /// **'Revoke Consent and Exit App'**
  String get privacyRevokeButton;

  /// No description provided for @privacyRevokeConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke Consent?'**
  String get privacyRevokeConfirmTitle;

  /// No description provided for @privacyRevokeConfirmDesc.
  ///
  /// In en, this message translates to:
  /// **'Revoking will exit the app; next launch requires re-consent.'**
  String get privacyRevokeConfirmDesc;

  /// No description provided for @privacyRevokeConfirmYes.
  ///
  /// In en, this message translates to:
  /// **'Revoke and Exit'**
  String get privacyRevokeConfirmYes;

  /// No description provided for @privacyRevokeConfirmNo.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get privacyRevokeConfirmNo;

  /// No description provided for @consentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A modern mobile terminal that respects your privacy.'**
  String get consentSubtitle;

  /// No description provided for @consentHighlightKeysTitle.
  ///
  /// In en, this message translates to:
  /// **'Your keys stay on device'**
  String get consentHighlightKeysTitle;

  /// No description provided for @consentHighlightKeysDesc.
  ///
  /// In en, this message translates to:
  /// **'Encrypted in Keychain / Keystore, never uploaded'**
  String get consentHighlightKeysDesc;

  /// No description provided for @consentHighlightCrashTitle.
  ///
  /// In en, this message translates to:
  /// **'Anonymous crash reports'**
  String get consentHighlightCrashTitle;

  /// No description provided for @consentHighlightCrashDesc.
  ///
  /// In en, this message translates to:
  /// **'Scrubbed — no host or account info'**
  String get consentHighlightCrashDesc;

  /// No description provided for @consentHighlightControlTitle.
  ///
  /// In en, this message translates to:
  /// **'Full control anytime'**
  String get consentHighlightControlTitle;

  /// No description provided for @consentHighlightControlDesc.
  ///
  /// In en, this message translates to:
  /// **'Toggle off crash and analytics in Settings'**
  String get consentHighlightControlDesc;

  /// No description provided for @consentAgreeBoilerplate.
  ///
  /// In en, this message translates to:
  /// **'By continuing you agree to our'**
  String get consentAgreeBoilerplate;

  /// No description provided for @consentAgreeBoilerplateAnd.
  ///
  /// In en, this message translates to:
  /// **'and'**
  String get consentAgreeBoilerplateAnd;

  /// No description provided for @consentDeclineHint.
  ///
  /// In en, this message translates to:
  /// **'Don\'t agree?'**
  String get consentDeclineHint;

  /// No description provided for @consentDeclineExit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get consentDeclineExit;

  /// No description provided for @privacySectionDocuments.
  ///
  /// In en, this message translates to:
  /// **'Documents'**
  String get privacySectionDocuments;

  /// No description provided for @privacySectionDangerZone.
  ///
  /// In en, this message translates to:
  /// **'Danger Zone'**
  String get privacySectionDangerZone;

  /// No description provided for @privacyRevokeCardDesc.
  ///
  /// In en, this message translates to:
  /// **'Revoking exits the app; next launch requires re-consent'**
  String get privacyRevokeCardDesc;

  /// No description provided for @paywallTitle.
  ///
  /// In en, this message translates to:
  /// **'FlyTerm Pro'**
  String get paywallTitle;

  /// No description provided for @paywallSubtitle.
  ///
  /// In en, this message translates to:
  /// **'One-time purchase, unlock all Pro features forever'**
  String get paywallSubtitle;

  /// No description provided for @paywallFeatureQuic.
  ///
  /// In en, this message translates to:
  /// **'QUIC protocol — low latency + roaming'**
  String get paywallFeatureQuic;

  /// No description provided for @paywallFeatureAi.
  ///
  /// In en, this message translates to:
  /// **'AI assist — voice input & error analysis'**
  String get paywallFeatureAi;

  /// No description provided for @paywallFeatureTunnel.
  ///
  /// In en, this message translates to:
  /// **'Port forwarding / SFTP / Mosh'**
  String get paywallFeatureTunnel;

  /// No description provided for @paywallFeatureFutureUpdates.
  ///
  /// In en, this message translates to:
  /// **'All future Pro updates included'**
  String get paywallFeatureFutureUpdates;

  /// No description provided for @paywallPurchaseButton.
  ///
  /// In en, this message translates to:
  /// **'Purchase {price}'**
  String paywallPurchaseButton(String price);

  /// No description provided for @paywallRestoreButton.
  ///
  /// In en, this message translates to:
  /// **'Already purchased? Restore'**
  String get paywallRestoreButton;

  /// No description provided for @paywallContinueLater.
  ///
  /// In en, this message translates to:
  /// **'Maybe later'**
  String get paywallContinueLater;

  /// No description provided for @paywallLoadingPrice.
  ///
  /// In en, this message translates to:
  /// **'Loading price…'**
  String get paywallLoadingPrice;

  /// No description provided for @paywallUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Store unavailable, please try later'**
  String get paywallUnavailable;

  /// No description provided for @paywallPurchasePending.
  ///
  /// In en, this message translates to:
  /// **'Confirming payment…'**
  String get paywallPurchasePending;

  /// No description provided for @paywallPurchaseError.
  ///
  /// In en, this message translates to:
  /// **'Purchase failed: {error}'**
  String paywallPurchaseError(String error);

  /// No description provided for @paywallRestoreNoneFound.
  ///
  /// In en, this message translates to:
  /// **'No purchase found for this account'**
  String get paywallRestoreNoneFound;

  /// No description provided for @paywallRestoreSuccess.
  ///
  /// In en, this message translates to:
  /// **'Pro unlocked'**
  String get paywallRestoreSuccess;

  /// No description provided for @proStatusPro.
  ///
  /// In en, this message translates to:
  /// **'FlyTerm Pro · Active'**
  String get proStatusPro;

  /// No description provided for @proStatusFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get proStatusFree;

  /// No description provided for @proStatusPurchasedAt.
  ///
  /// In en, this message translates to:
  /// **'Purchased on {date}'**
  String proStatusPurchasedAt(String date);

  /// No description provided for @proStatusUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Pro'**
  String get proStatusUpgrade;

  /// No description provided for @proStatusRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore Purchase'**
  String get proStatusRestore;

  /// Settings entry to view all OSS license texts
  ///
  /// In en, this message translates to:
  /// **'Open Source Licenses'**
  String get settingsOpenSourceLicenses;

  /// No description provided for @settingsOpenSourceLicensesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Third-party libraries and their licenses'**
  String get settingsOpenSourceLicensesSubtitle;

  /// No description provided for @updatePromptTitleOptional.
  ///
  /// In en, this message translates to:
  /// **'Update Available'**
  String get updatePromptTitleOptional;

  /// No description provided for @updatePromptTitleMandatory.
  ///
  /// In en, this message translates to:
  /// **'Required Update'**
  String get updatePromptTitleMandatory;

  /// No description provided for @updatePromptBody.
  ///
  /// In en, this message translates to:
  /// **'Version {latest} is available (current: {current}).'**
  String updatePromptBody(Object latest, Object current);

  /// No description provided for @updatePromptReleaseNotes.
  ///
  /// In en, this message translates to:
  /// **'RELEASE NOTES'**
  String get updatePromptReleaseNotes;

  /// No description provided for @updatePromptUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updatePromptUpdate;

  /// No description provided for @updatePromptLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updatePromptLater;

  /// No description provided for @agentToolRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get agentToolRunning;

  /// No description provided for @agentToolDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get agentToolDone;

  /// No description provided for @agentToolFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get agentToolFailed;

  /// No description provided for @agentToolRejected.
  ///
  /// In en, this message translates to:
  /// **'Rejected'**
  String get agentToolRejected;

  /// No description provided for @agentToolAwaiting.
  ///
  /// In en, this message translates to:
  /// **'Awaiting approval'**
  String get agentToolAwaiting;

  /// No description provided for @agentToolExpand.
  ///
  /// In en, this message translates to:
  /// **'Show output'**
  String get agentToolExpand;

  /// No description provided for @agentToolCollapse.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get agentToolCollapse;

  /// No description provided for @agentExitCode.
  ///
  /// In en, this message translates to:
  /// **'exit {code}'**
  String agentExitCode(int code);

  /// No description provided for @agentApprovalTitle.
  ///
  /// In en, this message translates to:
  /// **'Needs your approval'**
  String get agentApprovalTitle;

  /// No description provided for @agentAllowOnce.
  ///
  /// In en, this message translates to:
  /// **'Allow once'**
  String get agentAllowOnce;

  /// Button on the credential-deny approval card in bypass mode: allow and stop asking for this exact command for the rest of the session
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask again this turn'**
  String get agentSilenceInSession;

  /// No description provided for @agentDenyWarning.
  ///
  /// In en, this message translates to:
  /// **'This command touches credential files. Allowing it sends their contents to {provider}.'**
  String agentDenyWarning(String provider);

  /// No description provided for @agentReasonMetachar.
  ///
  /// In en, this message translates to:
  /// **'Command contains shell metacharacters — must be confirmed individually'**
  String get agentReasonMetachar;

  /// No description provided for @agentReasonNoRule.
  ///
  /// In en, this message translates to:
  /// **'No matching allow rule'**
  String get agentReasonNoRule;

  /// No description provided for @agentReasonFileWrite.
  ///
  /// In en, this message translates to:
  /// **'Writes to a file — always needs confirmation'**
  String get agentReasonFileWrite;

  /// No description provided for @agentInstructionsTitle.
  ///
  /// In en, this message translates to:
  /// **'AI assistant notes'**
  String get agentInstructionsTitle;

  /// No description provided for @agentInstructionsEntry.
  ///
  /// In en, this message translates to:
  /// **'Custom instructions'**
  String get agentInstructionsEntry;

  /// No description provided for @agentInstructionsEntrySet.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get agentInstructionsEntrySet;

  /// No description provided for @agentInstructionsEntryEmpty.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get agentInstructionsEntryEmpty;

  /// No description provided for @agentInstructionsHint.
  ///
  /// In en, this message translates to:
  /// **'Tell the AI how you want it to answer. For example: keep it short; lead with the conclusion; answer in English.\n\nThese notes apply to every server. Anything specific to one machine (uses podman, logs live in /data/logs) belongs in that server\'s notes below, not here.'**
  String get agentInstructionsHint;

  /// No description provided for @agentInstructionsLocalLabel.
  ///
  /// In en, this message translates to:
  /// **'Global notes (shared by all servers, this phone only)'**
  String get agentInstructionsLocalLabel;

  /// No description provided for @agentInstructionsSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get agentInstructionsSaved;

  /// No description provided for @agentInstructionsRemaining.
  ///
  /// In en, this message translates to:
  /// **'{n} bytes left'**
  String agentInstructionsRemaining(int n);

  /// No description provided for @agentInstructionsTooLong.
  ///
  /// In en, this message translates to:
  /// **'Over the {max} byte limit; the excess will not be sent to the AI'**
  String agentInstructionsTooLong(int max);

  /// No description provided for @agentSkillsEntry.
  ///
  /// In en, this message translates to:
  /// **'Skills'**
  String get agentSkillsEntry;

  /// No description provided for @agentSkillsEntryEmpty.
  ///
  /// In en, this message translates to:
  /// **'None yet'**
  String get agentSkillsEntryEmpty;

  /// No description provided for @agentSkillsEntryCount.
  ///
  /// In en, this message translates to:
  /// **'{count} saved'**
  String agentSkillsEntryCount(int count);

  /// No description provided for @agentSkillsTitle.
  ///
  /// In en, this message translates to:
  /// **'Skills'**
  String get agentSkillsTitle;

  /// No description provided for @agentSkillsHint.
  ///
  /// In en, this message translates to:
  /// **'Procedures and tool notes the assistant can pull in when relevant. Only the one-line description of each rides along in every request.'**
  String get agentSkillsHint;

  /// No description provided for @agentSkillsBudget.
  ///
  /// In en, this message translates to:
  /// **'{count} skills, about {tokens} tokens per request'**
  String agentSkillsBudget(int count, int tokens);

  /// No description provided for @agentSkillsOverflow.
  ///
  /// In en, this message translates to:
  /// **'{count} skills are past the index limit — the model needs to search for them'**
  String agentSkillsOverflow(int count);

  /// No description provided for @agentSkillsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No skills yet. Ask the assistant to save one after it solves something, or import from a server or file.'**
  String get agentSkillsEmpty;

  /// No description provided for @agentSkillsImportFromServer.
  ///
  /// In en, this message translates to:
  /// **'Import from this server'**
  String get agentSkillsImportFromServer;

  /// No description provided for @agentSkillsImportFromFile.
  ///
  /// In en, this message translates to:
  /// **'Import from a file'**
  String get agentSkillsImportFromFile;

  /// No description provided for @agentSkillsImportFromFolder.
  ///
  /// In en, this message translates to:
  /// **'Import a skill folder'**
  String get agentSkillsImportFromFolder;

  /// No description provided for @agentSkillsImportFromArchive.
  ///
  /// In en, this message translates to:
  /// **'Import a .zip package'**
  String get agentSkillsImportFromArchive;

  /// No description provided for @skillImportAssetCount.
  ///
  /// In en, this message translates to:
  /// **'{n} attached file(s)'**
  String skillImportAssetCount(int n);

  /// No description provided for @agentSkillsCreateManually.
  ///
  /// In en, this message translates to:
  /// **'Create manually'**
  String get agentSkillsCreateManually;

  /// No description provided for @agentSkillsImportTitle.
  ///
  /// In en, this message translates to:
  /// **'Import skills'**
  String get agentSkillsImportTitle;

  /// No description provided for @agentSkillsImportNone.
  ///
  /// In en, this message translates to:
  /// **'No skills found in ~/.flyterm/skills on this server.'**
  String get agentSkillsImportNone;

  /// No description provided for @agentSkillsImportSkipped.
  ///
  /// In en, this message translates to:
  /// **'{count} file(s) could not be parsed and were skipped'**
  String agentSkillsImportSkipped(int count);

  /// No description provided for @agentSkillsImportConfirm.
  ///
  /// In en, this message translates to:
  /// **'Import selected'**
  String get agentSkillsImportConfirm;

  /// No description provided for @agentSkillsImportNeedsDescription.
  ///
  /// In en, this message translates to:
  /// **'Add a one-line description'**
  String get agentSkillsImportNeedsDescription;

  /// No description provided for @agentSkillsConflictTitle.
  ///
  /// In en, this message translates to:
  /// **'A skill named \"{name}\" already exists'**
  String agentSkillsConflictTitle(String name);

  /// No description provided for @agentSkillsConflictOverwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get agentSkillsConflictOverwrite;

  /// No description provided for @agentSkillsConflictKeepBoth.
  ///
  /// In en, this message translates to:
  /// **'Keep both'**
  String get agentSkillsConflictKeepBoth;

  /// No description provided for @agentSkillsConflictSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get agentSkillsConflictSkip;

  /// No description provided for @agentSkillsSourceAi.
  ///
  /// In en, this message translates to:
  /// **'Written by assistant'**
  String get agentSkillsSourceAi;

  /// No description provided for @agentSkillsSourceRemote.
  ///
  /// In en, this message translates to:
  /// **'From server'**
  String get agentSkillsSourceRemote;

  /// No description provided for @agentSkillsSourceFile.
  ///
  /// In en, this message translates to:
  /// **'From file'**
  String get agentSkillsSourceFile;

  /// No description provided for @agentSkillsSourceManual.
  ///
  /// In en, this message translates to:
  /// **'Created manually'**
  String get agentSkillsSourceManual;

  /// No description provided for @agentKnowledgeCaptureTitle.
  ///
  /// In en, this message translates to:
  /// **'Offer to save what was learned'**
  String get agentKnowledgeCaptureTitle;

  /// No description provided for @agentKnowledgeCaptureDesc.
  ///
  /// In en, this message translates to:
  /// **'Turns a finished session into a card — save it as a skill or into this machine\'s notes'**
  String get agentKnowledgeCaptureDesc;

  /// No description provided for @agentSkillDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Skill'**
  String get agentSkillDetailTitle;

  /// No description provided for @agentSkillCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'New skill'**
  String get agentSkillCreateTitle;

  /// No description provided for @agentSkillNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get agentSkillNameLabel;

  /// No description provided for @agentSkillDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description (shown in every request)'**
  String get agentSkillDescriptionLabel;

  /// No description provided for @agentSkillBodyLabel.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get agentSkillBodyLabel;

  /// No description provided for @agentSkillAssetsLabel.
  ///
  /// In en, this message translates to:
  /// **'Attached files (installed on the server by install_skill_assets)'**
  String get agentSkillAssetsLabel;

  /// No description provided for @agentSkillAssetExecutable.
  ///
  /// In en, this message translates to:
  /// **'Executable — marked +x when installed'**
  String get agentSkillAssetExecutable;

  /// No description provided for @agentSkillAssetData.
  ///
  /// In en, this message translates to:
  /// **'Data file'**
  String get agentSkillAssetData;

  /// No description provided for @skillAssetAdd.
  ///
  /// In en, this message translates to:
  /// **'Add file'**
  String get skillAssetAdd;

  /// No description provided for @skillAssetEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit file'**
  String get skillAssetEdit;

  /// No description provided for @skillAssetEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'No attached files. Add a script or template if the steps would be identical every time.'**
  String get skillAssetEmptyHint;

  /// No description provided for @skillAssetPathLabel.
  ///
  /// In en, this message translates to:
  /// **'Path inside the skill folder'**
  String get skillAssetPathLabel;

  /// No description provided for @skillAssetPathHelper.
  ///
  /// In en, this message translates to:
  /// **'Relative, e.g. scripts/check.sh — no leading / and no ..'**
  String get skillAssetPathHelper;

  /// No description provided for @skillAssetPathInvalid.
  ///
  /// In en, this message translates to:
  /// **'Must be a relative path with no `..` or backslashes'**
  String get skillAssetPathInvalid;

  /// No description provided for @skillAssetExecutableToggle.
  ///
  /// In en, this message translates to:
  /// **'Executable'**
  String get skillAssetExecutableToggle;

  /// No description provided for @skillAssetExecutableHint.
  ///
  /// In en, this message translates to:
  /// **'Marked +x on the server when installed'**
  String get skillAssetExecutableHint;

  /// No description provided for @skillAssetContentLabel.
  ///
  /// In en, this message translates to:
  /// **'File contents'**
  String get skillAssetContentLabel;

  /// No description provided for @skillAssetTotalTooBig.
  ///
  /// In en, this message translates to:
  /// **'These files total {bytes} bytes; the limit is {limit}.'**
  String skillAssetTotalTooBig(int bytes, int limit);

  /// No description provided for @agentSkillDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete skill'**
  String get agentSkillDelete;

  /// No description provided for @agentSkillDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this skill? This cannot be undone.'**
  String get agentSkillDeleteConfirm;

  /// No description provided for @agentSkillSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get agentSkillSaved;

  /// No description provided for @agentSkillLoadedInPanel.
  ///
  /// In en, this message translates to:
  /// **'Used skill: {name}'**
  String agentSkillLoadedInPanel(String name);

  /// No description provided for @agentSkillSaveCardTitle.
  ///
  /// In en, this message translates to:
  /// **'Save skill \"{name}\"?'**
  String agentSkillSaveCardTitle(String name);

  /// No description provided for @agentSkillUpdateCardTitle.
  ///
  /// In en, this message translates to:
  /// **'Update skill \"{name}\"?'**
  String agentSkillUpdateCardTitle(String name);

  /// No description provided for @agentSkillNeverUsed.
  ///
  /// In en, this message translates to:
  /// **'Never used'**
  String get agentSkillNeverUsed;

  /// No description provided for @agentSkillUsedDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'Unused for {days} days'**
  String agentSkillUsedDaysAgo(int days);

  /// No description provided for @agentSkillUsedToday.
  ///
  /// In en, this message translates to:
  /// **'Used today'**
  String get agentSkillUsedToday;

  /// No description provided for @agentSkillHits.
  ///
  /// In en, this message translates to:
  /// **'Used {n} times'**
  String agentSkillHits(int n);

  /// No description provided for @agentSkillNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Not indexed · needs a search'**
  String get agentSkillNotLoaded;

  /// No description provided for @agentSkillNotLoadedHint.
  ///
  /// In en, this message translates to:
  /// **'Skills past the index limit don\'t appear directly in the system prompt — the model has to call search_skills first to find them, costing an extra tool round-trip. To make one visible at a glance, free up an index slot (disable or delete ones you don\'t need) instead of deleting these.'**
  String get agentSkillNotLoadedHint;

  /// No description provided for @agentBuiltinSkillsSection.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get agentBuiltinSkillsSection;

  /// No description provided for @agentBuiltinSkillsHint.
  ///
  /// In en, this message translates to:
  /// **'Ship with the app. You can turn one off, but not delete or edit it.'**
  String get agentBuiltinSkillsHint;

  /// No description provided for @agentBuiltinSkillBadge.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get agentBuiltinSkillBadge;

  /// No description provided for @agentBuiltinSkillTitleTroubleshoot.
  ///
  /// In en, this message translates to:
  /// **'Troubleshoot'**
  String get agentBuiltinSkillTitleTroubleshoot;

  /// No description provided for @agentBuiltinSkillDescTroubleshoot.
  ///
  /// In en, this message translates to:
  /// **'When something is broken: find the cause before changing anything, verify independently.'**
  String get agentBuiltinSkillDescTroubleshoot;

  /// No description provided for @agentBuiltinSkillTitlePlanChange.
  ///
  /// In en, this message translates to:
  /// **'Plan a change'**
  String get agentBuiltinSkillTitlePlanChange;

  /// No description provided for @agentBuiltinSkillDescPlanChange.
  ///
  /// In en, this message translates to:
  /// **'For multi-step work: clarify the requirement, get the plan approved, change one step at a time.'**
  String get agentBuiltinSkillDescPlanChange;

  /// No description provided for @agentBuiltinSkillTitleSkillCreator.
  ///
  /// In en, this message translates to:
  /// **'Write a skill'**
  String get agentBuiltinSkillTitleSkillCreator;

  /// No description provided for @agentBuiltinSkillDescSkillCreator.
  ///
  /// In en, this message translates to:
  /// **'When writing a skill: phrase the description as a trigger, write the body as steps, attach scripts instead of inlining them.'**
  String get agentBuiltinSkillDescSkillCreator;

  /// No description provided for @agentAddToPlan.
  ///
  /// In en, this message translates to:
  /// **'Add to plan'**
  String get agentAddToPlan;

  /// No description provided for @agentAddToPlanHint.
  ///
  /// In en, this message translates to:
  /// **'Queue it up and approve it together with the other changes later'**
  String get agentAddToPlanHint;

  /// No description provided for @agentProposalTitle.
  ///
  /// In en, this message translates to:
  /// **'Apply these changes?'**
  String get agentProposalTitle;

  /// No description provided for @agentProposalCount.
  ///
  /// In en, this message translates to:
  /// **'{n} pending'**
  String agentProposalCount(int n);

  /// No description provided for @agentProposalApprove.
  ///
  /// In en, this message translates to:
  /// **'Apply all'**
  String get agentProposalApprove;

  /// No description provided for @agentProposalDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get agentProposalDiscard;

  /// No description provided for @agentProposalNote.
  ///
  /// In en, this message translates to:
  /// **'These run one after another. If one fails it stops there and the rest stay queued for you to decide.'**
  String get agentProposalNote;

  /// No description provided for @agentKnowledgeTitle.
  ///
  /// In en, this message translates to:
  /// **'Save what was learned here?'**
  String get agentKnowledgeTitle;

  /// No description provided for @agentKnowledgeTargetSkill.
  ///
  /// In en, this message translates to:
  /// **'Skill'**
  String get agentKnowledgeTargetSkill;

  /// No description provided for @agentKnowledgeTargetNotes.
  ///
  /// In en, this message translates to:
  /// **'This machine\'s notes'**
  String get agentKnowledgeTargetNotes;

  /// No description provided for @agentKnowledgeSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get agentKnowledgeSave;

  /// No description provided for @agentKnowledgeUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update {name}'**
  String agentKnowledgeUpdate(String name);

  /// No description provided for @agentKnowledgeDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get agentKnowledgeDismiss;

  /// No description provided for @agentKnowledgeSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get agentKnowledgeSaved;

  /// No description provided for @agentKnowledgeExpand.
  ///
  /// In en, this message translates to:
  /// **'Show full text'**
  String get agentKnowledgeExpand;

  /// No description provided for @agentKnowledgeCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get agentKnowledgeCollapse;

  /// No description provided for @agentKnowledgeNotesFull.
  ///
  /// In en, this message translates to:
  /// **'This machine\'s notes are full — trim {bytes} more bytes'**
  String agentKnowledgeNotesFull(int bytes);

  /// No description provided for @agentKnowledgeSwitchHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the label to change where it goes'**
  String get agentKnowledgeSwitchHint;

  /// No description provided for @agentAdvancedRules.
  ///
  /// In en, this message translates to:
  /// **'Advanced: auto-run list'**
  String get agentAdvancedRules;

  /// No description provided for @agentUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get agentUndo;

  /// No description provided for @agentUndone.
  ///
  /// In en, this message translates to:
  /// **'Undone'**
  String get agentUndone;

  /// No description provided for @agentUndoBackupMissing.
  ///
  /// In en, this message translates to:
  /// **'Backup is gone; cannot undo'**
  String get agentUndoBackupMissing;

  /// Note shown on a discarded speculative tool card
  ///
  /// In en, this message translates to:
  /// **'Speculative result discarded; this command was re-run'**
  String get agentToolSuperseded;

  /// No description provided for @agentDiffEmpty.
  ///
  /// In en, this message translates to:
  /// **'(empty)'**
  String get agentDiffEmpty;

  /// No description provided for @agentDiffAtLine.
  ///
  /// In en, this message translates to:
  /// **'{path} · line {line}'**
  String agentDiffAtLine(String path, int line);

  /// No description provided for @agentDiffExpand.
  ///
  /// In en, this message translates to:
  /// **'Show full text'**
  String get agentDiffExpand;

  /// No description provided for @agentDiffCollapse.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get agentDiffCollapse;

  /// No description provided for @agentRejectReasonHint.
  ///
  /// In en, this message translates to:
  /// **'(optional) tell the AI why'**
  String get agentRejectReasonHint;

  /// No description provided for @agentStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get agentStop;

  /// No description provided for @agentThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get agentThinking;

  /// No description provided for @agentRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Rate limited — retrying in {seconds}s'**
  String agentRateLimited(int seconds);

  /// No description provided for @agentRunning.
  ///
  /// In en, this message translates to:
  /// **'Running…'**
  String get agentRunning;

  /// No description provided for @agentThinkingFor.
  ///
  /// In en, this message translates to:
  /// **'Thinking {seconds}s'**
  String agentThinkingFor(int seconds);

  /// No description provided for @agentRunningFor.
  ///
  /// In en, this message translates to:
  /// **'Running {seconds}s'**
  String agentRunningFor(int seconds);

  /// No description provided for @agentExecutingMany.
  ///
  /// In en, this message translates to:
  /// **'Running {count} commands {seconds}s'**
  String agentExecutingMany(int count, int seconds);

  /// No description provided for @agentAwaitingYou.
  ///
  /// In en, this message translates to:
  /// **'Waiting for you'**
  String get agentAwaitingYou;

  /// No description provided for @agentAwaitingAnswer.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your answer'**
  String get agentAwaitingAnswer;

  /// Tool calls made so far this run, shown on the running bar. Only shown when > 0
  ///
  /// In en, this message translates to:
  /// **'{count} calls so far'**
  String agentRunningCalls(int count);

  /// No description provided for @agentAskOther.
  ///
  /// In en, this message translates to:
  /// **'Type your own answer…'**
  String get agentAskOther;

  /// No description provided for @agentAskUnanswered.
  ///
  /// In en, this message translates to:
  /// **'not answered'**
  String get agentAskUnanswered;

  /// No description provided for @mentionServerColonHint.
  ///
  /// In en, this message translates to:
  /// **'Type : to browse files on this host'**
  String get mentionServerColonHint;

  /// No description provided for @mentionUnknownServer.
  ///
  /// In en, this message translates to:
  /// **'No such host: {name}'**
  String mentionUnknownServer(String name);

  /// No description provided for @agentTurnSummary.
  ///
  /// In en, this message translates to:
  /// **'{duration} · {calls} calls · {tokens} token'**
  String agentTurnSummary(String duration, int calls, String tokens);

  /// No description provided for @agentTurnSummaryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Includes time the app spent in the background'**
  String get agentTurnSummaryTooltip;

  /// No description provided for @agentStoppedMaxTurns.
  ///
  /// In en, this message translates to:
  /// **'Reached the {n}-turn limit. Continue?'**
  String agentStoppedMaxTurns(int n);

  /// No description provided for @agentStoppedTokenBudget.
  ///
  /// In en, this message translates to:
  /// **'Context is near the limit. Continue?'**
  String get agentStoppedTokenBudget;

  /// No description provided for @agentStoppedCancelled.
  ///
  /// In en, this message translates to:
  /// **'Stopped. Commands already sent were not undone.'**
  String get agentStoppedCancelled;

  /// No description provided for @agentStoppedInvalidArgs.
  ///
  /// In en, this message translates to:
  /// **'The model kept sending invalid tool arguments. Aborted.'**
  String get agentStoppedInvalidArgs;

  /// No description provided for @agentContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get agentContinue;

  /// No description provided for @agentRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get agentRetry;

  /// No description provided for @agentInputHint.
  ///
  /// In en, this message translates to:
  /// **'Describe the problem · @ to reference a host · / for skills'**
  String get agentInputHint;

  /// No description provided for @attachPick.
  ///
  /// In en, this message translates to:
  /// **'Add image or file'**
  String get attachPick;

  /// No description provided for @attachRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get attachRemove;

  /// No description provided for @attachUnsupportedVision.
  ///
  /// In en, this message translates to:
  /// **'This model does not support image input'**
  String get attachUnsupportedVision;

  /// No description provided for @attachTryAnyway.
  ///
  /// In en, this message translates to:
  /// **'Try anyway'**
  String get attachTryAnyway;

  /// No description provided for @attachRejectBinary.
  ///
  /// In en, this message translates to:
  /// **'Only images and text files are supported'**
  String get attachRejectBinary;

  /// No description provided for @attachRejectEmpty.
  ///
  /// In en, this message translates to:
  /// **'That file is empty'**
  String get attachRejectEmpty;

  /// No description provided for @attachTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Image too large ({size}) — crop it and try again'**
  String attachTooLarge(String size);

  /// No description provided for @attachTextTruncated.
  ///
  /// In en, this message translates to:
  /// **'(truncated, original size {size})'**
  String attachTextTruncated(String size);

  /// No description provided for @attachMissing.
  ///
  /// In en, this message translates to:
  /// **'Image no longer available'**
  String get attachMissing;

  /// No description provided for @attachSkippedOnSend.
  ///
  /// In en, this message translates to:
  /// **'{count} attachment(s) unavailable, not sent this turn'**
  String attachSkippedOnSend(int count);

  /// No description provided for @attachSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the attachment'**
  String get attachSaveFailed;

  /// No description provided for @attachUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Could not read that file. Files in cloud storage need to be downloaded to this device first.'**
  String get attachUnreadable;

  /// No description provided for @attachContextOverflow.
  ///
  /// In en, this message translates to:
  /// **'Context exceeds the model limit; images account for about {tokens} tokens. Start a new session or remove images.'**
  String attachContextOverflow(int tokens);

  /// No description provided for @mentionFilesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'File browsing unavailable'**
  String get mentionFilesUnavailable;

  /// No description provided for @mentionNeedAbsolutePath.
  ///
  /// In en, this message translates to:
  /// **'Use an absolute path (starting with /)'**
  String get mentionNeedAbsolutePath;

  /// No description provided for @mentionDirLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read directory: {error}'**
  String mentionDirLoadFailed(String error);

  /// No description provided for @mentionMoreEntries.
  ///
  /// In en, this message translates to:
  /// **'{count} more — keep typing to narrow'**
  String mentionMoreEntries(int count);

  /// No description provided for @agentPendingWithdrawHint.
  ///
  /// In en, this message translates to:
  /// **'Queued — tap to withdraw'**
  String get agentPendingWithdrawHint;

  /// No description provided for @agentUsage.
  ///
  /// In en, this message translates to:
  /// **'in {input} · out {output}'**
  String agentUsage(String input, String output);

  /// Appended to the per-session usage line. 'total' is the cross-session cumulative input+output token count.
  ///
  /// In en, this message translates to:
  /// **'{session} · total {total}'**
  String agentUsageCumulative(String session, String total);

  /// No description provided for @agentUsageCached.
  ///
  /// In en, this message translates to:
  /// **'in {input} (cached {cached}) · out {output}'**
  String agentUsageCached(String input, String cached, String output);

  /// No description provided for @agentNoCredentials.
  ///
  /// In en, this message translates to:
  /// **'No saved credentials for this server — agent mode unavailable'**
  String get agentNoCredentials;

  /// No description provided for @agentGoToServerSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get agentGoToServerSettings;

  /// No description provided for @agentNoToolSupport.
  ///
  /// In en, this message translates to:
  /// **'This model does not support tool calling'**
  String get agentNoToolSupport;

  /// No description provided for @agentSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'AI Agent'**
  String get agentSettingsTitle;

  /// No description provided for @agentModeBypassWarning.
  ///
  /// In en, this message translates to:
  /// **'The AI will run any command on this server without asking, and can also change FlyTerm\'s own settings. Commands touching credential files, and operations that cannot be undone, still prompt.'**
  String get agentModeBypassWarning;

  /// No description provided for @agentRulesTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-allowed commands'**
  String get agentRulesTitle;

  /// No description provided for @agentRulesBuiltinGroup.
  ///
  /// In en, this message translates to:
  /// **'Defaults'**
  String get agentRulesBuiltinGroup;

  /// No description provided for @agentRulesUserGroup.
  ///
  /// In en, this message translates to:
  /// **'Approved by you'**
  String get agentRulesUserGroup;

  /// No description provided for @agentRulesEmpty.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t approved any rules yet'**
  String get agentRulesEmpty;

  /// No description provided for @agentRulesFirstReview.
  ///
  /// In en, this message translates to:
  /// **'The AI runs these without asking. Take a look — you can turn off any of them.'**
  String get agentRulesFirstReview;

  /// No description provided for @agentRulesGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get agentRulesGotIt;

  /// No description provided for @agentRulesGoReview.
  ///
  /// In en, this message translates to:
  /// **'Review the allowlist'**
  String get agentRulesGoReview;

  /// No description provided for @agentMemorySection.
  ///
  /// In en, this message translates to:
  /// **'Assistant memory'**
  String get agentMemorySection;

  /// No description provided for @agentAllowlistEntry.
  ///
  /// In en, this message translates to:
  /// **'Auto-run list'**
  String get agentAllowlistEntry;

  /// No description provided for @agentAllowlistSubtitleEnabled.
  ///
  /// In en, this message translates to:
  /// **'{enabled} of {total} categories allowed'**
  String agentAllowlistSubtitleEnabled(int enabled, int total);

  /// No description provided for @agentToolTierGroup.
  ///
  /// In en, this message translates to:
  /// **'Tool tier'**
  String get agentToolTierGroup;

  /// No description provided for @agentToolTierAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get agentToolTierAuto;

  /// No description provided for @agentToolTierLean.
  ///
  /// In en, this message translates to:
  /// **'Lean'**
  String get agentToolTierLean;

  /// No description provided for @agentToolTierFull.
  ///
  /// In en, this message translates to:
  /// **'Full'**
  String get agentToolTierFull;

  /// No description provided for @agentToolTierAutoDesc.
  ///
  /// In en, this message translates to:
  /// **'Auto: full tools for cloud models, lean (2 tools) for local models like Ollama'**
  String get agentToolTierAutoDesc;

  /// No description provided for @agentToolTierLeanDesc.
  ///
  /// In en, this message translates to:
  /// **'Lean: only bash and read_file — best for small/local models'**
  String get agentToolTierLeanDesc;

  /// No description provided for @agentToolTierFullDesc.
  ///
  /// In en, this message translates to:
  /// **'Full: also write_file, edit_file and set_plan — best for capable cloud models'**
  String get agentToolTierFullDesc;

  /// No description provided for @agentBannerAskTitle.
  ///
  /// In en, this message translates to:
  /// **'Currently: it will ask me first'**
  String get agentBannerAskTitle;

  /// No description provided for @agentBannerBypassTitle.
  ///
  /// In en, this message translates to:
  /// **'Currently: it won\'t ask you'**
  String get agentBannerBypassTitle;

  /// No description provided for @agentBannerPlanTitle.
  ///
  /// In en, this message translates to:
  /// **'Now: plan first'**
  String get agentBannerPlanTitle;

  /// No description provided for @agentCapabilityAutoLabel.
  ///
  /// In en, this message translates to:
  /// **'Runs automatically'**
  String get agentCapabilityAutoLabel;

  /// No description provided for @agentCapabilityAutoValue.
  ///
  /// In en, this message translates to:
  /// **'View logs, check processes, read files, inspect containers'**
  String get agentCapabilityAutoValue;

  /// No description provided for @agentCapabilityAskLabel.
  ///
  /// In en, this message translates to:
  /// **'Needs your confirmation'**
  String get agentCapabilityAskLabel;

  /// No description provided for @agentCapabilityAskValue.
  ///
  /// In en, this message translates to:
  /// **'Editing files, restarting services, deleting things, any command with a pipe'**
  String get agentCapabilityAskValue;

  /// No description provided for @agentRuleGroupServiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Service status & logs'**
  String get agentRuleGroupServiceTitle;

  /// No description provided for @agentRuleGroupServiceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Whether a service is running, and its logs'**
  String get agentRuleGroupServiceSubtitle;

  /// No description provided for @agentRuleGroupSystemTitle.
  ///
  /// In en, this message translates to:
  /// **'System & processes'**
  String get agentRuleGroupSystemTitle;

  /// No description provided for @agentRuleGroupSystemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s running, how much disk/memory is left'**
  String get agentRuleGroupSystemSubtitle;

  /// No description provided for @agentRuleGroupNetworkTitle.
  ///
  /// In en, this message translates to:
  /// **'Network listeners'**
  String get agentRuleGroupNetworkTitle;

  /// No description provided for @agentRuleGroupNetworkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Which ports are listening, what\'s connected'**
  String get agentRuleGroupNetworkSubtitle;

  /// No description provided for @agentRuleGroupFilesTitle.
  ///
  /// In en, this message translates to:
  /// **'File contents'**
  String get agentRuleGroupFilesTitle;

  /// No description provided for @agentRuleGroupFilesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sends file contents to the AI'**
  String get agentRuleGroupFilesSubtitle;

  /// No description provided for @agentRuleGroupFilesWarning.
  ///
  /// In en, this message translates to:
  /// **'Private keys, .env, .kube/config and similar files still prompt for approval separately, even with this group on.'**
  String get agentRuleGroupFilesWarning;

  /// No description provided for @agentRuleGroupDockerTitle.
  ///
  /// In en, this message translates to:
  /// **'Docker containers'**
  String get agentRuleGroupDockerTitle;

  /// No description provided for @agentRuleGroupDockerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Container status and logs'**
  String get agentRuleGroupDockerSubtitle;

  /// No description provided for @agentRuleGroupK8sTitle.
  ///
  /// In en, this message translates to:
  /// **'Kubernetes'**
  String get agentRuleGroupK8sTitle;

  /// No description provided for @agentRuleGroupK8sSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Cluster resources and logs'**
  String get agentRuleGroupK8sSubtitle;

  /// No description provided for @agentRuleGroupOtherTitle.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get agentRuleGroupOtherTitle;

  /// No description provided for @agentPanelBypassActiveTooltip.
  ///
  /// In en, this message translates to:
  /// **'\"Allow everything\" is on — the agent won\'t ask before running commands'**
  String get agentPanelBypassActiveTooltip;

  /// No description provided for @agentInstructionsExamplesLabel.
  ///
  /// In en, this message translates to:
  /// **'Try one of these:'**
  String get agentInstructionsExamplesLabel;

  /// No description provided for @agentInstructionsExample1.
  ///
  /// In en, this message translates to:
  /// **'Keep answers short, no padding'**
  String get agentInstructionsExample1;

  /// No description provided for @agentInstructionsExample2.
  ///
  /// In en, this message translates to:
  /// **'Lead with the conclusion'**
  String get agentInstructionsExample2;

  /// No description provided for @agentInstructionsExample3.
  ///
  /// In en, this message translates to:
  /// **'Answer in English'**
  String get agentInstructionsExample3;

  /// No description provided for @agentServerNotesEntry.
  ///
  /// In en, this message translates to:
  /// **'This machine\'s notes'**
  String get agentServerNotesEntry;

  /// No description provided for @agentServerNotesLines.
  ///
  /// In en, this message translates to:
  /// **'{n} lines'**
  String agentServerNotesLines(int n);

  /// No description provided for @agentServerNotesNone.
  ///
  /// In en, this message translates to:
  /// **'Not created'**
  String get agentServerNotesNone;

  /// No description provided for @agentServerNotesTitle.
  ///
  /// In en, this message translates to:
  /// **'This machine\'s notes'**
  String get agentServerNotesTitle;

  /// No description provided for @agentServerNotesHint.
  ///
  /// In en, this message translates to:
  /// **'Conventions and quirks of this box — \"uses podman, not docker\", \"logs live on /data\". Sent to the model on every turn, so keep it short.'**
  String get agentServerNotesHint;

  /// No description provided for @agentServerNotesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No notes yet'**
  String get agentServerNotesEmpty;

  /// No description provided for @agentServerNotesBytes.
  ///
  /// In en, this message translates to:
  /// **'{used} / {max} bytes'**
  String agentServerNotesBytes(int used, int max);

  /// No description provided for @agentServerNotesSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get agentServerNotesSave;

  /// No description provided for @agentServerNotesTooLong.
  ///
  /// In en, this message translates to:
  /// **'{n} bytes over the limit. Trim it down.'**
  String agentServerNotesTooLong(int n);

  /// No description provided for @agentServerNotesOverviewEntry.
  ///
  /// In en, this message translates to:
  /// **'Machine notes'**
  String get agentServerNotesOverviewEntry;

  /// No description provided for @agentServerNotesOverviewSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{n} machines'**
  String agentServerNotesOverviewSubtitle(int n);

  /// No description provided for @agentServerNotesOverviewEmpty.
  ///
  /// In en, this message translates to:
  /// **'No machine notes yet. They build up as you work, or you can write them by hand from a server\'s settings.'**
  String get agentServerNotesOverviewEmpty;

  /// No description provided for @agentServerNotesUpdatedAt.
  ///
  /// In en, this message translates to:
  /// **'Last updated: {time}'**
  String agentServerNotesUpdatedAt(String time);

  /// No description provided for @agentServerNotesDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete these notes'**
  String get agentServerNotesDelete;

  /// No description provided for @agentServerNotesForMachine.
  ///
  /// In en, this message translates to:
  /// **'Machine notes: {name}'**
  String agentServerNotesForMachine(String name);

  /// No description provided for @agentToolRunningFor.
  ///
  /// In en, this message translates to:
  /// **'running {seconds}s'**
  String agentToolRunningFor(int seconds);

  /// No description provided for @agentToolTook.
  ///
  /// In en, this message translates to:
  /// **'took {duration}'**
  String agentToolTook(String duration);

  /// No description provided for @agentJobRunning.
  ///
  /// In en, this message translates to:
  /// **'running for {elapsed}'**
  String agentJobRunning(String elapsed);

  /// No description provided for @agentJobFinished.
  ///
  /// In en, this message translates to:
  /// **'finished · exit {code}'**
  String agentJobFinished(int code);

  /// No description provided for @agentJobKilling.
  ///
  /// In en, this message translates to:
  /// **'stopping…'**
  String get agentJobKilling;

  /// No description provided for @agentJobSinceStart.
  ///
  /// In en, this message translates to:
  /// **'{elapsed} since start'**
  String agentJobSinceStart(String elapsed);

  /// No description provided for @agentJobCheckedJustNow.
  ///
  /// In en, this message translates to:
  /// **'just checked'**
  String get agentJobCheckedJustNow;

  /// No description provided for @agentJobCheckedMinutes.
  ///
  /// In en, this message translates to:
  /// **'checked {n}m ago'**
  String agentJobCheckedMinutes(int n);

  /// No description provided for @agentJobCheckedHours.
  ///
  /// In en, this message translates to:
  /// **'checked {n}h ago'**
  String agentJobCheckedHours(int n);

  /// No description provided for @agentJobCheckedDays.
  ///
  /// In en, this message translates to:
  /// **'checked {n}d ago'**
  String agentJobCheckedDays(int n);

  /// No description provided for @agentJobsBarCount.
  ///
  /// In en, this message translates to:
  /// **'{count} background jobs'**
  String agentJobsBarCount(int count);

  /// No description provided for @agentJobStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get agentJobStop;

  /// No description provided for @transferDownloading.
  ///
  /// In en, this message translates to:
  /// **'downloading'**
  String get transferDownloading;

  /// No description provided for @transferUploading.
  ///
  /// In en, this message translates to:
  /// **'uploading'**
  String get transferUploading;

  /// No description provided for @transferRelayDownloading.
  ///
  /// In en, this message translates to:
  /// **'fetching from {from}'**
  String transferRelayDownloading(String from);

  /// No description provided for @transferRelayUploading.
  ///
  /// In en, this message translates to:
  /// **'sending to {to}'**
  String transferRelayUploading(String to);

  /// No description provided for @transferDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get transferDone;

  /// No description provided for @transferCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get transferCancelled;

  /// No description provided for @transferFailed.
  ///
  /// In en, this message translates to:
  /// **'failed'**
  String get transferFailed;

  /// No description provided for @transferInterrupted.
  ///
  /// In en, this message translates to:
  /// **'interrupted'**
  String get transferInterrupted;

  /// No description provided for @transferCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get transferCancel;

  /// No description provided for @transferOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get transferOpen;

  /// No description provided for @transferLetAiRead.
  ///
  /// In en, this message translates to:
  /// **'Let AI read it'**
  String get transferLetAiRead;

  /// No description provided for @transferShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get transferShare;

  /// No description provided for @transferCredentialWarning.
  ///
  /// In en, this message translates to:
  /// **'Credential file — its contents will not be sent to the AI'**
  String get transferCredentialWarning;

  /// No description provided for @transferBackupKept.
  ///
  /// In en, this message translates to:
  /// **'Previous file kept at {path}'**
  String transferBackupKept(String path);

  /// No description provided for @agentCompacted.
  ///
  /// In en, this message translates to:
  /// **'compacted {count} earlier messages'**
  String agentCompacted(int count);

  /// No description provided for @agentTruncated.
  ///
  /// In en, this message translates to:
  /// **'{count} earlier entries omitted'**
  String agentTruncated(int count);

  /// Output line count label on the dense row
  ///
  /// In en, this message translates to:
  /// **'{count} lines'**
  String agentToolOutputLines(int count);

  /// Collapsed form of a plan checklist superseded by a later one
  ///
  /// In en, this message translates to:
  /// **'Plan updated ({count} steps)'**
  String agentPlanUpdatedCollapsed(int count);

  /// Dense form of the knowledge proposal card once all candidates are resolved
  ///
  /// In en, this message translates to:
  /// **'Knowledge proposal · resolved'**
  String get agentKnowledgeResolved;

  /// Dev-mode button that exports per-turn metrics as JSONL
  ///
  /// In en, this message translates to:
  /// **'Export timing metrics'**
  String get agentExportMetrics;

  /// No description provided for @batchApprovalTitle.
  ///
  /// In en, this message translates to:
  /// **'Needs your approval'**
  String get batchApprovalTitle;

  /// No description provided for @batchApprovalCount.
  ///
  /// In en, this message translates to:
  /// **'{count} calls'**
  String batchApprovalCount(int count);

  /// No description provided for @batchApprovalCurrentSession.
  ///
  /// In en, this message translates to:
  /// **'current session'**
  String get batchApprovalCurrentSession;

  /// No description provided for @batchApprovalApproveAll.
  ///
  /// In en, this message translates to:
  /// **'Approve all'**
  String get batchApprovalApproveAll;

  /// No description provided for @batchApprovalDiscard.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get batchApprovalDiscard;

  /// No description provided for @agentInterruptedTitle.
  ///
  /// In en, this message translates to:
  /// **'Last session was interrupted'**
  String get agentInterruptedTitle;

  /// No description provided for @agentInterruptedRunning.
  ///
  /// In en, this message translates to:
  /// **'Running at the time:\n{calls}'**
  String agentInterruptedRunning(String calls);

  /// No description provided for @aiSwitchModel.
  ///
  /// In en, this message translates to:
  /// **'Switch model'**
  String get aiSwitchModel;

  /// No description provided for @aiModelNoToolSupport.
  ///
  /// In en, this message translates to:
  /// **'No tool-calling support'**
  String get aiModelNoToolSupport;

  /// No description provided for @aiModelNoApiKey.
  ///
  /// In en, this message translates to:
  /// **'No API key configured'**
  String get aiModelNoApiKey;

  /// No description provided for @aiModelLeanTools.
  ///
  /// In en, this message translates to:
  /// **'Reduced tool set — no file transfer'**
  String get aiModelLeanTools;

  /// No description provided for @aiExportSession.
  ///
  /// In en, this message translates to:
  /// **'Export session'**
  String get aiExportSession;

  /// No description provided for @aiExportPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Export preview'**
  String get aiExportPreviewTitle;

  /// No description provided for @aiExportRedacted.
  ///
  /// In en, this message translates to:
  /// **'{count} secret(s) redacted'**
  String aiExportRedacted(int count);

  /// No description provided for @aiExportShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get aiExportShare;

  /// No description provided for @aiExportEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing to export in this session yet'**
  String get aiExportEmpty;

  /// No description provided for @agentSupersededCollapsed.
  ///
  /// In en, this message translates to:
  /// **'Resent — {count} item(s) collapsed'**
  String agentSupersededCollapsed(int count);

  /// No description provided for @agentInterruptedResume.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get agentInterruptedResume;

  /// No description provided for @navAI.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get navAI;

  /// No description provided for @navServers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get navServers;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @aiGlobalEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'How can I help?'**
  String get aiGlobalEmptyTitle;

  /// No description provided for @aiGlobalSuggest1.
  ///
  /// In en, this message translates to:
  /// **'Explain this error'**
  String get aiGlobalSuggest1;

  /// No description provided for @aiGlobalSuggest2.
  ///
  /// In en, this message translates to:
  /// **'Write a shell command'**
  String get aiGlobalSuggest2;

  /// No description provided for @aiGlobalSuggest3.
  ///
  /// In en, this message translates to:
  /// **'Explain a config file'**
  String get aiGlobalSuggest3;

  /// No description provided for @aiGlobalClearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get aiGlobalClearHistory;

  /// No description provided for @aiRunOnServer.
  ///
  /// In en, this message translates to:
  /// **'Run on server…'**
  String get aiRunOnServer;

  /// No description provided for @aiGlobalAgentEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'What can I do for you?'**
  String get aiGlobalAgentEmptyTitle;

  /// No description provided for @aiGlobalAgentSuggest1.
  ///
  /// In en, this message translates to:
  /// **'Which machine is running out of disk'**
  String get aiGlobalAgentSuggest1;

  /// No description provided for @aiGlobalAgentSuggest2.
  ///
  /// In en, this message translates to:
  /// **'Check load on all machines'**
  String get aiGlobalAgentSuggest2;

  /// No description provided for @aiGlobalAgentSuggest3.
  ///
  /// In en, this message translates to:
  /// **'Look for nginx errors'**
  String get aiGlobalAgentSuggest3;

  /// No description provided for @aiGlobalAgentSuggest4.
  ///
  /// In en, this message translates to:
  /// **'Make the terminal font bigger'**
  String get aiGlobalAgentSuggest4;

  /// No description provided for @aiHomeRecent.
  ///
  /// In en, this message translates to:
  /// **'Pick up where you left off'**
  String get aiHomeRecent;

  /// No description provided for @aiHomeMachines.
  ///
  /// In en, this message translates to:
  /// **'Machines'**
  String get aiHomeMachines;

  /// No description provided for @aiHomeOrAsk.
  ///
  /// In en, this message translates to:
  /// **'Or just ask'**
  String get aiHomeOrAsk;

  /// No description provided for @aiHomeMoreMachines.
  ///
  /// In en, this message translates to:
  /// **'+{count}'**
  String aiHomeMoreMachines(int count);

  /// No description provided for @relativeTimeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get relativeTimeJustNow;

  /// No description provided for @aiHomeSuggestDisk.
  ///
  /// In en, this message translates to:
  /// **'Check disk on {machine}'**
  String aiHomeSuggestDisk(String machine);

  /// No description provided for @aiHomeSuggestLoad.
  ///
  /// In en, this message translates to:
  /// **'Check load on {machine}'**
  String aiHomeSuggestLoad(String machine);

  /// No description provided for @aiHomeSuggestLogs.
  ///
  /// In en, this message translates to:
  /// **'Check logs on {machine}'**
  String aiHomeSuggestLogs(String machine);

  /// No description provided for @serversScanJobs.
  ///
  /// In en, this message translates to:
  /// **'Scan for background jobs'**
  String get serversScanJobs;

  /// No description provided for @jobsRunningBadge.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 job running} other{{count} jobs running}}'**
  String jobsRunningBadge(int count);

  /// No description provided for @importPasteTitle.
  ///
  /// In en, this message translates to:
  /// **'Paste to import'**
  String get importPasteTitle;

  /// No description provided for @importPasteHint.
  ///
  /// In en, this message translates to:
  /// **'Paste an ssh config block or a single ssh command'**
  String get importPasteHint;

  /// No description provided for @importPasteAction.
  ///
  /// In en, this message translates to:
  /// **'Detect'**
  String get importPasteAction;

  /// No description provided for @importParsedTitle.
  ///
  /// In en, this message translates to:
  /// **'Detected'**
  String get importParsedTitle;

  /// No description provided for @importNotRecognized.
  ///
  /// In en, this message translates to:
  /// **'No server details found'**
  String get importNotRecognized;

  /// No description provided for @importFormatExamples.
  ///
  /// In en, this message translates to:
  /// **'Supported formats:\nssh -p 2222 root@example.com\nHost web\n  HostName 10.0.0.5'**
  String get importFormatExamples;

  /// No description provided for @importTryAi.
  ///
  /// In en, this message translates to:
  /// **'Try with AI'**
  String get importTryAi;

  /// No description provided for @importAiFailed.
  ///
  /// In en, this message translates to:
  /// **'AI could not parse it either — please fill it in manually'**
  String get importAiFailed;

  /// No description provided for @importStrippedKey.
  ///
  /// In en, this message translates to:
  /// **'A private key in the pasted text was ignored and never sent anywhere'**
  String get importStrippedKey;

  /// No description provided for @importStrippedPassword.
  ///
  /// In en, this message translates to:
  /// **'A password line in the pasted text was ignored'**
  String get importStrippedPassword;

  /// No description provided for @importSawInclude.
  ///
  /// In en, this message translates to:
  /// **'Files referenced by Include were not read'**
  String get importSawInclude;

  /// No description provided for @importNeedsManualKey.
  ///
  /// In en, this message translates to:
  /// **'This host uses key authentication — pick a key manually'**
  String get importNeedsManualKey;

  /// No description provided for @importPickHost.
  ///
  /// In en, this message translates to:
  /// **'Several hosts found — pick one to import'**
  String get importPickHost;

  /// No description provided for @importPickServerForTunnel.
  ///
  /// In en, this message translates to:
  /// **'Which server should this forward belong to?'**
  String get importPickServerForTunnel;

  /// No description provided for @importApplied.
  ///
  /// In en, this message translates to:
  /// **'Filled into the form — review and save'**
  String get importApplied;

  /// No description provided for @appControlSection.
  ///
  /// In en, this message translates to:
  /// **'App control'**
  String get appControlSection;

  /// No description provided for @appChangeBarLabel.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 app setting changed} other{{count} app settings changed}}'**
  String appChangeBarLabel(int count);

  /// No description provided for @appChangeUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get appChangeUndo;

  /// No description provided for @appChangeIrreversible.
  ///
  /// In en, this message translates to:
  /// **'Includes changes that cannot be undone'**
  String get appChangeIrreversible;

  /// No description provided for @appChangeCardTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{AI changed 1 app setting} other{AI changed {count} app settings}}'**
  String appChangeCardTitle(int count);

  /// No description provided for @appChangeMore.
  ///
  /// In en, this message translates to:
  /// **'{count} more…'**
  String appChangeMore(int count);

  /// No description provided for @appChangeUndone.
  ///
  /// In en, this message translates to:
  /// **'Undone'**
  String get appChangeUndone;

  /// No description provided for @appChangeRestoredNote.
  ///
  /// In en, this message translates to:
  /// **'These app changes came from an earlier session and can no longer be undone'**
  String get appChangeRestoredNote;

  /// No description provided for @appChangeOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get appChangeOn;

  /// No description provided for @appChangeOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get appChangeOff;

  /// No description provided for @appChangeKindServer.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get appChangeKindServer;

  /// No description provided for @appChangeKindTunnel.
  ///
  /// In en, this message translates to:
  /// **'Port forward'**
  String get appChangeKindTunnel;

  /// No description provided for @appChangeKindKey.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get appChangeKindKey;

  /// No description provided for @appChangeKindSession.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get appChangeKindSession;

  /// No description provided for @appChangeKindLayout.
  ///
  /// In en, this message translates to:
  /// **'Split layout'**
  String get appChangeKindLayout;

  /// No description provided for @appChangeFieldFontFamily.
  ///
  /// In en, this message translates to:
  /// **'Terminal font'**
  String get appChangeFieldFontFamily;

  /// No description provided for @appChangeFieldLineHeight.
  ///
  /// In en, this message translates to:
  /// **'Line height'**
  String get appChangeFieldLineHeight;

  /// No description provided for @jobBoardTitle.
  ///
  /// In en, this message translates to:
  /// **'Background Jobs'**
  String get jobBoardTitle;

  /// No description provided for @jobBoardNoServers.
  ///
  /// In en, this message translates to:
  /// **'No servers yet'**
  String get jobBoardNoServers;

  /// No description provided for @jobBoardNoJobs.
  ///
  /// In en, this message translates to:
  /// **'No background jobs'**
  String get jobBoardNoJobs;

  /// No description provided for @jobBoardScanFailed.
  ///
  /// In en, this message translates to:
  /// **'Scan failed'**
  String get jobBoardScanFailed;

  /// No description provided for @jobBoardRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get jobBoardRetry;

  /// No description provided for @jobBoardSkippedEntries.
  ///
  /// In en, this message translates to:
  /// **'{count} entries not recognized'**
  String jobBoardSkippedEntries(int count);

  /// No description provided for @jobBoardRunning.
  ///
  /// In en, this message translates to:
  /// **'running'**
  String get jobBoardRunning;

  /// No description provided for @jobBoardExitCode.
  ///
  /// In en, this message translates to:
  /// **'exit code {code}'**
  String jobBoardExitCode(String code);

  /// No description provided for @jobBoardLogTimeUnknown.
  ///
  /// In en, this message translates to:
  /// **'log time unknown'**
  String get jobBoardLogTimeUnknown;

  /// No description provided for @jobBoardLogUpdatedAgo.
  ///
  /// In en, this message translates to:
  /// **'log updated {ago}'**
  String jobBoardLogUpdatedAgo(String ago);

  /// No description provided for @jobBoardLineCount.
  ///
  /// In en, this message translates to:
  /// **'{count} lines'**
  String jobBoardLineCount(int count);

  /// No description provided for @jobBoardReadLogFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to read log: {error}'**
  String jobBoardReadLogFailed(String error);

  /// No description provided for @jobBoardReadingLog.
  ///
  /// In en, this message translates to:
  /// **'Reading…'**
  String get jobBoardReadingLog;

  /// No description provided for @jobBoardKillTooltip.
  ///
  /// In en, this message translates to:
  /// **'Terminate'**
  String get jobBoardKillTooltip;

  /// No description provided for @jobBoardCopyJobIdTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy job id'**
  String get jobBoardCopyJobIdTooltip;

  /// No description provided for @jobBoardHandOffTooltip.
  ///
  /// In en, this message translates to:
  /// **'Let AI take over'**
  String get jobBoardHandOffTooltip;

  /// No description provided for @jobBoardNeedTabTooltip.
  ///
  /// In en, this message translates to:
  /// **'Connect to this server first'**
  String get jobBoardNeedTabTooltip;

  /// No description provided for @jobBoardCopiedJobId.
  ///
  /// In en, this message translates to:
  /// **'Job id copied'**
  String get jobBoardCopiedJobId;

  /// No description provided for @jobBoardKillSent.
  ///
  /// In en, this message translates to:
  /// **'Termination signal sent'**
  String get jobBoardKillSent;

  /// No description provided for @jobBoardConfirmKillTitle.
  ///
  /// In en, this message translates to:
  /// **'Terminate this job?'**
  String get jobBoardConfirmKillTitle;

  /// No description provided for @jobBoardConfirmKillContent.
  ///
  /// In en, this message translates to:
  /// **'{job} on {server}.\nSIGTERM will be sent to the whole process group; this cannot be undone.'**
  String jobBoardConfirmKillContent(String job, String server);

  /// No description provided for @jobBoardHandOffPrompt.
  ///
  /// In en, this message translates to:
  /// **'Background job `{id}` is still running. Use check_job to see its progress, then continue.'**
  String jobBoardHandOffPrompt(String id);

  /// No description provided for @timeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// No description provided for @timeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String timeMinutesAgo(int count);

  /// No description provided for @timeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String timeHoursAgo(int count);

  /// No description provided for @timeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} d ago'**
  String timeDaysAgo(int count);

  /// No description provided for @timeToday.
  ///
  /// In en, this message translates to:
  /// **'today'**
  String get timeToday;

  /// No description provided for @timeYesterday.
  ///
  /// In en, this message translates to:
  /// **'yesterday'**
  String get timeYesterday;

  /// No description provided for @timeMonthsAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} mo ago'**
  String timeMonthsAgo(int count);

  /// No description provided for @knownHostFirstSeen.
  ///
  /// In en, this message translates to:
  /// **'First seen {date} · last {time}'**
  String knownHostFirstSeen(String date, String time);

  /// No description provided for @fingerprintCopied.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint copied'**
  String get fingerprintCopied;

  /// No description provided for @selectionColorFollowTheme.
  ///
  /// In en, this message translates to:
  /// **'Follow theme'**
  String get selectionColorFollowTheme;

  /// No description provided for @selectionColorBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get selectionColorBlue;

  /// No description provided for @selectionColorPurple.
  ///
  /// In en, this message translates to:
  /// **'Purple'**
  String get selectionColorPurple;

  /// No description provided for @selectionColorOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange'**
  String get selectionColorOrange;

  /// No description provided for @selectionColorGray.
  ///
  /// In en, this message translates to:
  /// **'Gray'**
  String get selectionColorGray;

  /// No description provided for @floatingNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get floatingNotConnected;

  /// No description provided for @floatingDisconnected.
  ///
  /// In en, this message translates to:
  /// **'disconnected'**
  String get floatingDisconnected;

  /// No description provided for @floatingGhostMode.
  ///
  /// In en, this message translates to:
  /// **'Ghost mode'**
  String get floatingGhostMode;

  /// No description provided for @floatingExitGhostMode.
  ///
  /// In en, this message translates to:
  /// **'Exit ghost mode'**
  String get floatingExitGhostMode;

  /// No description provided for @fileSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get fileSaved;

  /// No description provided for @fileSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String fileSaveFailed(String error);

  /// No description provided for @fileTooLargeReadonly.
  ///
  /// In en, this message translates to:
  /// **'File too large; showing first 512 KB with saving disabled to prevent data loss'**
  String get fileTooLargeReadonly;

  /// No description provided for @imageDecodeFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to decode image'**
  String get imageDecodeFailed;

  /// No description provided for @browseAction.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get browseAction;

  /// No description provided for @keyImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String keyImportFailed(String error);

  /// No description provided for @keyPassphraseEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for no passphrase'**
  String get keyPassphraseEmptyHint;

  /// No description provided for @transferFileTitle.
  ///
  /// In en, this message translates to:
  /// **'Transfer file (QUIC)'**
  String get transferFileTitle;

  /// No description provided for @transferRemotePathHint.
  ///
  /// In en, this message translates to:
  /// **'Remote path (e.g. ~/upload/file.bin)'**
  String get transferRemotePathHint;

  /// No description provided for @transferUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get transferUpload;

  /// No description provided for @transferDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get transferDownload;

  /// No description provided for @transferWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting...'**
  String get transferWaiting;

  /// No description provided for @transferFailedWithReason.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String transferFailedWithReason(String error);

  /// No description provided for @transferUnknownError.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get transferUnknownError;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loading;

  /// No description provided for @settingsConnectionAdvancedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Compression {compression} · keep-alive {keepAlive}'**
  String settingsConnectionAdvancedSubtitle(
    String compression,
    String keepAlive,
  );

  /// No description provided for @settingsSecuritySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Dangerous command guard {state}'**
  String settingsSecuritySubtitle(String state);

  /// No description provided for @settingsPrivacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Crash reports {crash} · analytics {analytics}'**
  String settingsPrivacySubtitle(String crash, String analytics);

  /// No description provided for @refreshLosesSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Refreshing loses the session'**
  String get refreshLosesSessionTitle;

  /// No description provided for @refreshLosesSessionBody.
  ///
  /// In en, this message translates to:
  /// **'This server runs in Once mode. Refreshing starts a new shell — the original scrollback, running commands, and SHELL process will all be lost.\n\nIf you enable Daemon mode in the server settings, refreshing will truly \"restore\" the original session.'**
  String get refreshLosesSessionBody;

  /// No description provided for @dontShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show again'**
  String get dontShowAgain;

  /// No description provided for @continueRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh anyway'**
  String get continueRefresh;

  /// No description provided for @highRiskCommandTitle.
  ///
  /// In en, this message translates to:
  /// **'High-risk command'**
  String get highRiskCommandTitle;

  /// No description provided for @highRiskCommandBody.
  ///
  /// In en, this message translates to:
  /// **'This command may damage data or the system. Run it anyway?'**
  String get highRiskCommandBody;

  /// No description provided for @aiExplain.
  ///
  /// In en, this message translates to:
  /// **'AI explain'**
  String get aiExplain;

  /// No description provided for @execute.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get execute;

  /// No description provided for @quicConnectFailedHint.
  ///
  /// In en, this message translates to:
  /// **'QUIC connect failed: {error}\nFor an SSH fallback, change Transport to SSH in the server settings.'**
  String quicConnectFailedHint(String error);

  /// No description provided for @tmuxNotFoundClosed.
  ///
  /// In en, this message translates to:
  /// **'[tmux not found, session closed automatically]'**
  String get tmuxNotFoundClosed;

  /// No description provided for @backAction.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get backAction;

  /// No description provided for @sftpRecentPaths.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get sftpRecentPaths;

  /// No description provided for @sftpPinnedPaths.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get sftpPinnedPaths;

  /// No description provided for @sftpNoRecentPaths.
  ///
  /// In en, this message translates to:
  /// **'No history yet'**
  String get sftpNoRecentPaths;

  /// No description provided for @sftpNoPinnedPaths.
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet — long-press an entry to pin it'**
  String get sftpNoPinnedPaths;

  /// No description provided for @sftpPathSuggestions.
  ///
  /// In en, this message translates to:
  /// **'Suggestions'**
  String get sftpPathSuggestions;

  /// No description provided for @sftpPinPath.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get sftpPinPath;

  /// No description provided for @sftpUnpinPath.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get sftpUnpinPath;

  /// No description provided for @sftpRemovePath.
  ///
  /// In en, this message translates to:
  /// **'Remove from history'**
  String get sftpRemovePath;

  /// No description provided for @agentPermReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get agentPermReadOnly;

  /// No description provided for @agentPermReadOnlyDesc.
  ///
  /// In en, this message translates to:
  /// **'AI can look but not change anything'**
  String get agentPermReadOnlyDesc;

  /// No description provided for @agentPermAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask me'**
  String get agentPermAsk;

  /// No description provided for @agentPermAskDesc.
  ///
  /// In en, this message translates to:
  /// **'Read commands just run; file changes queue up for one approval'**
  String get agentPermAskDesc;

  /// No description provided for @agentPermBypass.
  ///
  /// In en, this message translates to:
  /// **'Allow all'**
  String get agentPermBypass;

  /// No description provided for @agentPermBypassDesc.
  ///
  /// In en, this message translates to:
  /// **'Does anything without asking (credential files excepted)'**
  String get agentPermBypassDesc;

  /// No description provided for @agentPermTitle.
  ///
  /// In en, this message translates to:
  /// **'AI permissions'**
  String get agentPermTitle;

  /// No description provided for @agentPermFollowGlobal.
  ///
  /// In en, this message translates to:
  /// **'Follow global ({mode})'**
  String agentPermFollowGlobal(String mode);

  /// No description provided for @agentPermServerTitle.
  ///
  /// In en, this message translates to:
  /// **'AI permissions for this server'**
  String get agentPermServerTitle;

  /// No description provided for @agentApprovalOnce.
  ///
  /// In en, this message translates to:
  /// **'Just this once'**
  String get agentApprovalOnce;

  /// No description provided for @agentApprovalAlways.
  ///
  /// In en, this message translates to:
  /// **'Always allow'**
  String get agentApprovalAlways;

  /// No description provided for @agentApprovalRulePrefix.
  ///
  /// In en, this message translates to:
  /// **'Always allow'**
  String get agentApprovalRulePrefix;

  /// No description provided for @agentApprovalReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get agentApprovalReject;

  /// No description provided for @promptLanguageName.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get promptLanguageName;

  /// No description provided for @aqtPortsLabel.
  ///
  /// In en, this message translates to:
  /// **'UDP ports'**
  String get aqtPortsLabel;

  /// No description provided for @aqtPortsHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for 61001-61999. A single port or a range; allow it as UDP in the server firewall / security group.'**
  String get aqtPortsHint;

  /// No description provided for @aqtPortsInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a port or range between 1024 and 65535, e.g. 61001-61999'**
  String get aqtPortsInvalid;

  /// No description provided for @aqtPortRestartTitle.
  ///
  /// In en, this message translates to:
  /// **'Restart FlyTerm Server?'**
  String get aqtPortRestartTitle;

  /// No description provided for @aqtPortRestartBody.
  ///
  /// In en, this message translates to:
  /// **'The server is listening on UDP {current}, outside the configured {ports}. Restarting moves it to the new ports but ends the {sessions} AQT session(s) on this server, including ones on other devices.'**
  String aqtPortRestartBody(String current, String ports, int sessions);

  /// No description provided for @aqtPortRestartBodyUnknown.
  ///
  /// In en, this message translates to:
  /// **'The server is listening on UDP {current}, outside the configured {ports}. Restarting moves it to the new ports but ends every AQT session on this server, including ones on other devices.'**
  String aqtPortRestartBodyUnknown(String current, String ports);

  /// No description provided for @aqtPortRestartConfirm.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get aqtPortRestartConfirm;

  /// No description provided for @aqtPortRestartKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep current port'**
  String get aqtPortRestartKeep;

  /// No description provided for @aqtFellBackToSsh.
  ///
  /// In en, this message translates to:
  /// **'UDP is unavailable, so FlyTerm connected through the SSH channel. Allow UDP {ports} for lower latency.'**
  String aqtFellBackToSsh(String ports);

  /// No description provided for @aqtViaSshLabel.
  ///
  /// In en, this message translates to:
  /// **'Always use the SSH channel'**
  String get aqtViaSshLabel;

  /// No description provided for @aqtViaSshDesc.
  ///
  /// In en, this message translates to:
  /// **'Skip direct UDP. For servers that only expose port 22 or networks that block UDP; slightly higher latency.'**
  String get aqtViaSshDesc;

  /// No description provided for @aqtRouteViaSshTooltip.
  ///
  /// In en, this message translates to:
  /// **'QUIC · via SSH channel'**
  String get aqtRouteViaSshTooltip;

  /// No description provided for @aqtRelayUnsupported.
  ///
  /// In en, this message translates to:
  /// **'The server's flyterm-server is too old for the SSH channel. Please upgrade it.'**
  String get aqtRelayUnsupported;

  /// No description provided for @aqtRelayStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not set up the SSH channel: {error}'**
  String aqtRelayStartFailed(String error);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

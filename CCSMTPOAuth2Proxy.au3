#NoTrayIcon
#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Icon=icons\default.ico
#AutoIt3Wrapper_Res_Fileversion=1.0.0.62
#AutoIt3Wrapper_Res_Fileversion_AutoIncrement=y
#AutoIt3Wrapper_Res_Icon_Add=icons\Exit.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\Settings.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\Log.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\ProviderMicrosoft.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\ProviderGoogle.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\ProviderCustom.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\Accounts.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\Advanced.ico
#AutoIt3Wrapper_Res_Icon_Add=icons\Notify.ico
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
Opt("TrayMenuMode", 3)          ; 1 = no automatic default menu, 2 = no automatic checkmark on click
Opt("TrayOnEventMode", 0)       ; use the TrayGetMsg() polling style
Opt("MustDeclareVars", 1)       ; every variable must be explicitly Local/Global/Dim/Const'd before use
#include <TrayConstants.au3>
#include <Constants.au3>
#include <GUIConstantsEx.au3>
#include <ComboConstants.au3>
#include <EditConstants.au3>
#include <GuiListView.au3>
#include <GuiMenu.au3>
#include <WinAPIGdi.au3>
#include <WinAPIShellEx.au3>
#include <WinAPIIcons.au3>
#include <WinAPIError.au3>
#include <StructureConstants.au3>
#include <WindowsConstants.au3>
#include <WindowsNotifsConstants.au3>
#include <Array.au3>
#include <Crypt.au3>
#include <Misc.au3>

#cs
	=============================================================================
	 About This Project
	=============================================================================
	CCSMTPOAuth2Proxy is a small local SMTP-to-OAuth2 proxy: it lets legacy
	e-mail clients and devices that only support plain username/password
	SMTP authentication (old printers, scanners, line-of-business software,
	...) send mail through modern providers - Microsoft 365, Google
	Workspace, and others - that require OAuth2 instead.

	This project was inspired by the IDEAS behind email-oauth2-proxy (c)
	Simon Robinson - https://github.com/simonrob/email-oauth2-proxy - the
	general concept of a local SMTP-to-OAuth2 proxy comes from there. The
	code itself is entirely new: a self-contained, from-scratch AutoIt
	implementation, not a port or translation of that project's own source
	code, written for a single admin's own small set of accounts rather
	than as a drop-in replacement or a general-purpose tool for others to
	deploy as-is.

	by Markus Debus, 2026

	Since email-oauth2-proxy is itself licensed under the Apache License,
	Version 2.0, this project is released under that same license, so that
	anyone receiving this program has the same rights that project's
	license already gave to this one - see LICENSE.txt (the unmodified
	license text) and NOTICE.txt (attribution) alongside this script, or
	http://www.apache.org/licenses/LICENSE-2.0 for the canonical copy.

	Copyright 2026 Markus Debus

	Licensed under the Apache License, Version 2.0 (the "License");
	you may not use this file except in compliance with the License.
	You may obtain a copy of the License at

	    http://www.apache.org/licenses/LICENSE-2.0

	Unless required by applicable law or agreed to in writing, software
	distributed under the License is distributed on an "AS IS" BASIS,
	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
	See the License for the specific language governing permissions and
	limitations under the License.


	=============================================================================
	 What makes this project more interesting than it looks
	=============================================================================
	On the surface this is "just" a little tray tool with a handful of
	dialogs. Under the hood, it ends up doing a surprising amount for a
	single AutoIt script:

	- AutoIt has no built-in TLS sockets, so every proxied connection gets
	  its own short-lived PowerShell helper process that performs the
	  actual TLS handshake and talks to the real SMTP server - see
	  _EnsureRelayHelperScript() / _Upstream_Start().
	- The OAuth2 authorization-code flow, including PKCE, is implemented
	  from scratch - down to a tiny local HTTP server
	  (_Auth_WaitForRedirect()) whose only job is catching the browser's
	  redirect and reading the "code" out of it.
	- The local redirect port for that flow is picked freshly on every
	  sign-in attempt rather than fixed, relying on how Microsoft Entra ID
	  (and most other providers using the same "loopback" convention, see
	  RFC 8252 section 7.3) ignores the port when matching a registered
	  "http://localhost/" redirect URI - see _RunInteractiveAuth().
	- AutoIt is single-threaded, so keeping the proxy actually relaying
	  mail *while* a Settings dialog, a message box, or an OAuth2 sign-in
	  wait is left open took real, deliberate work - see
	  _ServiceConnections() and how every dialog loop in this script calls
	  it on every tick.
	- Client secrets, local SMTP passwords, and OAuth2 tokens are all
	  encrypted at rest via Windows DPAPI, tied to the Windows user account
	  the script runs under - see _DPAPI_Protect() / _DPAPI_Unprotect().

	None of that is visible from the tray icon - it just quietly works.


	=============================================================================
	 AI assistance
	=============================================================================
	Large parts of this script - including most of the GUI dialogs, the
	Icons, the OAuth2/SMTP state machine, the DPAPI-based secret storage,
	and a good deal of the debugging along the way - were developed
	together with Claude (Anthropic) as a coding assistant.


	=============================================================================
	 TODO / ROADMAP
	=============================================================================
	Since v79 the list of open items (ideas, deferred and performance items,
	with effort estimates) is kept in ONE place only: the README, section 16
	"ROADMAP (POSSIBLE FUTURE CHANGES)". The short codes used in comments
	of this script (C6, L1, F2, G1 ...) refer to the entries there.
#ce

; ---------------------------------------------------------------------------
; States of the SMTP client connection (modelled on the original project)
; ---------------------------------------------------------------------------
Global Const $STATE_GREETING = 0             ; waiting for the server greeting (220), passed straight through
Global Const $STATE_EHLO_WAIT = 1            ; EHLO sent to the server, waiting for the full response
Global Const $STATE_STARTTLS_WAIT = 2        ; STARTTLS sent to the server, waiting for 220
Global Const $STATE_EHLO_WAIT_POST_TLS = 3   ; EHLO re-sent after the TLS upgrade
Global Const $STATE_READY = 4                ; ready for an AUTH command from the client
Global Const $STATE_AUTH_PLAIN_WAIT_CREDS = 5
Global Const $STATE_AUTH_LOGIN_WAIT_USER = 6
Global Const $STATE_AUTH_LOGIN_WAIT_PASS = 7
Global Const $STATE_XOAUTH2_WAIT_334 = 8     ; AUTH XOAUTH2 sent, waiting for "334 "
Global Const $STATE_XOAUTH2_WAIT_RESULT = 9  ; credentials sent, waiting for 235/5xx
Global Const $STATE_AUTHENTICATED = 10       ; signed in -> from here on, pure raw pass-through

Global Const $SENTINEL = "##PROXY_STARTTLS##"

; Maximum number of bytes _ExtractLines()/_Upstream_ReadLineBlocking() will
; buffer while waiting for a CRLF before giving up and treating it as an
; error, so a client/server that never sends a line terminator cannot grow
; memory usage without bound. Generous relative to real SMTP control lines
; (RFC 5321 suggests 512 bytes per command line) while still being a hard
; ceiling.
Global Const $MAX_LINE_BUFFER_BYTES = 65536

; E5: DPAPI must never show a dialog - the proxy runs unattended and is single-threaded,
; so a dialog waiting for a click would stop everything. With this flag Windows returns
; an error instead (the function then returns ""), see _DPAPI_Protect()/_DPAPI_Unprotect().
Global Const $CRYPTPROTECT_UI_FORBIDDEN = 0x1

; Approximate target size, in bytes, generated for EACH of the text/plain
; and text/html parts of a "large test e-mail" (see
; _ShowSendTestEmailDialog()'s "Send large test e-mail" option and
; _GenerateLoremText()/_GenerateLoremHtml()).
Global Const $LARGE_TEST_EMAIL_BODY_BYTES = 300000

; ---------------------------------------------------------------------------
; Global state variables.
; Note on AutoIt variable scoping: all globals pre-declared here can be
; assigned to from inside any function WITHOUT repeating the "Global"
; keyword, because AutoIt resolves a bare assignment to an already-existing
; global of the same name (as long as it is not shadowed by a Local
; variable of the same name in that function).
; ---------------------------------------------------------------------------

;icon numbers
; Win32 resource numbers of the extra icons embedded into the compiled .exe:
; the #AutoIt3Wrapper_Res_Icon_Add directives at the top of this file are
; numbered 201, 202, 203 ... in the order they are listed there, so these
; values must be kept in step with that order (Exit, Settings, Log,
; ProviderMicrosoft, ProviderGoogle, ProviderCustom, Accounts, Advanced,
; Notify).
; (Up to v71 About.ico was the first one (201); it was no longer shown
; anywhere since v61 and was removed in v72 - so Exit/Settings/Log moved
; down by one.)
Global $iIconNumberExit = 201
Global $iIconNumberSettings = 202
Global $iIconNumberLog = 203
; U1 (v74): one icon per provider type for the account entries of the tray
; menu - see _TrayProviderIcon().
Global $iIconNumberProviderMicrosoft = 204
Global $iIconNumberProviderGoogle = 205
Global $iIconNumberProviderCustom = 206
; W1 (v77): own icons for the items of the Settings submenu (until v76 all
; three showed the gear icon of "Settings" itself).
Global $iIconNumberAccounts = 207
Global $iIconNumberAdvanced = 208
Global $iIconNumberNotify = 209
Global $iIconOffset = 199 ;the Autoit Icon numbering is not the same as the Win32 Icon Numbering, so we need an offset to use win32 functions
Global Const $iTrayIconSize = 16 ;standard small-icon size for context menu items
; Global object used to store tray items and their hBitmaps
Global $mhBitmapStorage = ObjCreate("Scripting.Dictionary")

; Display name of this tool. Used everywhere the application name is shown
; to the user (tray tooltip, tray title item, window titles, TrayTip
; messages, log start/stop lines, the test e-mail subject/body) and
; many other locations. Change this in one place to rebrand the tool.
Global $g_sAppName = "CCSMTPOAuth2Proxy"

Global $g_sIniPath = @ScriptDir & "\" & $g_sAppName & ".ini"
; E3: the log file (and its older generations, see _RotateLogFile()) is
; kept in a "log" folder next to the program; the generated PowerShell helper
; script lives directly next to the program (_EnsureRelayHelperScript()).
; N2 (v71): there is only ONE log file - the lines of the PowerShell helpers
; go into it as well (see _HelperStderrDrain()); the separate
; <AppName>-RelayHelper.log of v32-v70 no longer exists.
Global $g_sLogDir = @ScriptDir & "\log"
Global $g_sLogPath = $g_sLogDir & "\" & $g_sAppName & ".log"
Global $g_sRelayScriptPath = ""
Global $g_iMaxLogSizeMB = 10          ; E3: rotate the log when it reaches this size (0 = never)
Global $g_iLogGenerations = 5         ; E3: number of older parts kept (Name.1.log ... Name.5.log)
Global $g_hLastLogRotateCheck = 0     ; E3: _LogRotationTick() throttling (0 = check at once)
Global $g_iLastAcceptCheck = 0

; ---------------------------------------------------------------------------
; Global variables backing the INI file's [General] section.
; These are populated exclusively by _LoadGeneralSettings() (called once at
; startup) and written back to disk by _SaveGeneralSettings(). Every other
; part of the script reads these globals instead of calling
; IniRead($g_sIniPath, "General", ...) directly, so the [General] section of
; the INI file is only ever touched from within those two functions.
; ---------------------------------------------------------------------------
Global $g_bClearLogOnStart = True
Global $g_iAuthPortStart = 8462
Global $g_iSmtpPortStart = 1587
; Logging (see LogFile()): $g_bUseLogSetting turns writing to the log FILE
; on/off entirely - defaults to True (unlike the plain 0/off default a
; similar setting might use elsewhere, this project's log file has always
; been on unconditionally, so keeping that behaviour as the default here
; matters). $g_iLogLevel is the message-level threshold: a message is only
; written if $g_iLogLevel is at least as high as the message's own $iLevel
; argument (0 = always, 9 = only with the most verbose setting) - defaults
; to 5 when compiled, 9 when run as a raw script (matching how the console
; output half of this used to only ever appear that way anyway - see
; LogFile()'s own header comment for why). Both are read from - and can be
; overridden via - the "UseLogFile"/"LogLevel" [General] INI settings,
; same as $g_bClearLogOnStart and the other settings below.
Global $g_bUseLogSetting = True
Global $g_iLogLevel = 5
If Not @Compiled Then $g_iLogLevel = 9
Global $g_iAcceptCheckIntervalMs = 200
Global $g_iTcpTimeoutMs = 0          ; Opt("TCPTimeout"): how long TCPAccept()/TCPRecv() wait when nothing is pending (AutoIt default 100) - see _LoadGeneralSettings()
Global $g_iMainLoopTickMs = 5
Global $g_iRelayPollMs = 2
Global $g_iStallWatchdogMs = 15000    ; _PumpConnection(): warn once if not authenticated within this long
Global $g_iIdleWatchdogMs = 120000    ; _PumpConnection(): warn repeatedly if authenticated but idle this long
Global $g_iAuthRedirectTimeoutSec = 180 ; _Auth_WaitForRedirect(): give up waiting for the OAuth2 browser redirect after this long
Global $g_iHttpTimeoutMs = 15000      ; _HttpPostForm(): applied to all four WinHttp SetTimeouts() parameters
Global $g_iProactiveRefreshLeadSec = 600 ; _ProactiveTokenRefresh(): refresh a token this long before it actually expires
Global $g_iLoopBlockWarnMs = 3000     ; _CheckLoopGap(): log a warning if one pass of the main loop took longer than this (0 = off)
Global $g_iAuthResultTimeoutMs = 20000 ; O2: _PumpConnection(): answer "454" and close if the real server does not answer the XOAUTH2 sign-in within this long (0 = never)
Global $g_iPreAuthTimeoutMs = 60000   ; _PumpConnection(): close a connection that has not finished the local login within this long (0 = never)
Global $g_iIdleCloseMs = 600000       ; _PumpConnection(): close a signed-in connection with no data in either direction for this long (0 = never)

; Runtime-only state for _CheckLoopGap() / _OpEnd() - not persisted to the INI.
Global $g_hLastServiceTick = 0        ; TimerInit() of the previous _ServiceConnections() call (0 = none yet)
Global $g_iLastWallSec = 0            ; wall clock (Unix seconds) at the last wall-clock check
Global $g_hLastWallTimer = 0          ; TimerInit() at the last wall-clock check
Global $g_sGapLongestOp = ""          ; name of the longest timed operation since the previous _ServiceConnections() call
Global $g_iGapLongestOpMs = 0         ; ... and how long it took

Global $g_iLastProactiveRefreshCheck = 0 ; runtime-only timer for _ProactiveTokenRefresh()'s own throttling - not persisted to the INI, same as $g_iLastAcceptCheck
Global $g_sSettingsWarnings = ""   ; collected by _IniReadInt(), logged by _Main() right after the "started" line
Global $g_oDpapiWarned = ObjCreate("Scripting.Dictionary") ; E4: values whose decryption failure was already logged
Global $g_iRelayDebugLog = 0          ; F1: 1 = the PowerShell helpers also log every data chunk (in the main log at LogLevel 6, N2) - only for troubleshooting
Global $g_iMaxConnections = 5         ; D1: _AcceptNewConnections(): at most this many client connections at once (0 = no limit)
Global $g_hLastRejectLog = 0          ; D1: throttles the "connection refused - limit reached" log line
Global $g_iRejectedSinceLog = 0       ; D1: connections refused since that line was last written
; E8: tray tooltip statistics (runtime only)
Global $g_sStatsDay = ""
Global $g_sStatsLabel = "Today" ; tooltip label of the day counters: "Since HH:MM" on the day the proxy was started, "Today" from the next midnight on
Global $g_iStatsRelayedToday = 0
Global $g_iStatsRejectedToday = 0
Global $g_sStatsLastError = ""      ; text of the most recent error (tooltip)
Global $g_sStatsLastErrorDay = ""   ; its date as YYYYMMDD - the tooltip shows the full date if it is not today
Global $g_sStatsLastErrorTime = ""  ; its time as HH:MM
Global $g_bTooltipDirty = True
Global $g_hLastTooltipUpdate = 0
Global $g_iTooltipLastConnCount = -1

Global $g_oListeners = ObjCreate("Scripting.Dictionary")          ; Key: "SMTP-<port>" -> Dictionary with listener configuration
Global $g_oActiveConnections = ObjCreate("Scripting.Dictionary")  ; Key: client socket (String) -> connection Dictionary
Global $g_oAccountsByEmail = ObjCreate("Scripting.Dictionary")    ; Key: e-mail address -> account Dictionary
Global $g_oAccountMenuItems = ObjCreate("Scripting.Dictionary")   ; Key: tray control ID (String) -> e-mail address
Global $g_oHelperLogPrefix = ObjCreate("Scripting.Dictionary")    ; M1: helper PID (String) -> context in front of its log lines
Global $g_oHelperLogPartial = ObjCreate("Scripting.Dictionary")   ; M1: helper PID (String) -> unfinished stderr line (binary)
Global $g_oHelperErrTail = ObjCreate("Scripting.Dictionary")      ; M1: helper PID (String) -> last 2000 chars of real error output
Global $g_aAllTrayItemIds[0]
Global $g_idTrayTitle = 0 ; the title item's ID (program name + version) - since v61 it opens the About dialog (the separate "About" item was removed)
Global $g_iOpenDialogCount = 0 ; how many GUI dialogs are currently open (nested) - see _DialogOpened()/_DialogClosed()
Global $g_hAccountListView = 0 ; handle of the Account Settings dialog's account ListView, while it is open - see _WM_NOTIFY_AccountList()
Global $g_bAccountListDblClk = False ; set by _WM_NOTIFY_AccountList() when that ListView is double-clicked, consumed by _ShowSettingsDialog()

Global $g_idMenuSettings = 0   ; the "Settings" SUBMENU (since v61) - holds "Accounts" and "Advanced"
Global $g_idMenuAccounts = 0   ; Settings > Accounts  -> _ShowSettingsDialog() ("Account Settings")
Global $g_idMenuAdvanced = 0   ; Settings > Advanced  -> _ShowAdvancedSettingsDialog()
Global $g_idMenuSettingsSep = 0 ; separator inside the Settings submenu (before Autostart)
Global $g_idMenuOpenLog = 0
Global $g_idMenuAutostart = 0
Global $g_idMenuExit = 0

; Autostart registry location - HKEY_CURRENT_USER (not HKLM) deliberately,
; since this needs no administrator rights and only affects the current
; Windows user, matching this tool's own "single admin's own accounts"
; single-user design. See _IsAutostartEnabled()/_ToggleAutostart().
Global Const $g_sAutostartRegKey = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

; ---------------------------------------------------------------------------
; E1 (v76): notifications - settings of the [Notify] INI section (read by
; _NotifyLoadSettings(), edited in Settings > Notifications) and the
; engine's state. See the "NOTIFICATIONS" section further down.
; ---------------------------------------------------------------------------
Global $g_idMenuNotifications = 0 ; Settings > Notifications -> _ShowNotificationSettingsDialog()
Global $g_bNtfyEnabled = False
Global $g_sNtfyServer = "https://ntfy.sh"
Global $g_sNtfyTopic = ""
Global $g_sNtfyTokenEnc = ""          ; optional access token, DPAPI-encrypted (as in the INI)
Global $g_bWebhookEnabled = False
Global $g_sWebhookUrlEnc = ""         ; DPAPI-encrypted - the URL itself is the secret
Global $g_sWebhookTemplate = ""
Global $g_bCommandEnabled = False
Global $g_sNotifyCommand = ""
Global $g_bHeartbeatEnabled = False
Global $g_sHeartbeatUrlEnc = ""       ; DPAPI-encrypted
Global $g_iHeartbeatIntervalMin = 5
Global $g_iNotifyMinIntervalMin = 60  ; rate limit: same event (and account) at most every N minutes, 0 = no limit
Global $g_iNotifyLoopBlockSec = 60    ; "proxy was blocked" only from this duration on
Global $g_bNotifyAllClear = True
; Event switches: INI key "Event" & name, code = StringLower(name)
Global Const $g_sNotifyEventNames = "Reauth|RefreshFail|Refused|Errors|LoopBlock|StartStop"
Global $g_oNotifyEventOn = ObjCreate("Scripting.Dictionary")   ; event code -> True/False
Global $g_oNotifyLastSent = ObjCreate("Scripting.Dictionary")  ; "event|account" -> TimerInit() of the last message
Global $g_oNotifyActive = ObjCreate("Scripting.Dictionary")    ; "event|account" -> title of a problem not yet resolved (for the all-clear)
Global $g_oNotifyProcs = ObjCreate("Scripting.Dictionary")     ; PID (String) -> dictionary of a running /notify process
Global $g_oNotifyDone = ObjCreate("Scripting.Dictionary")      ; PID (String) -> collected output of a finished test job
Global $g_oNotifyErrTimes = ObjCreate("Scripting.Dictionary")  ; account -> "|"-separated Unix times of recent errors
Global $g_hNotifyLastTick = 0
Global $g_hHeartbeatTimer = 0         ; 0 = ping at the next tick
Global $g_sLastComError = ""          ; description of the last COM error (_ComErrorHandler())
; Webhook templates (placeholders: see __NotifyFill()). JSON on one line.
Global Const $NOTIFY_TPL_ALL = '{"text":"{headline}: {message}","event":"{event}","title":"{title}","message":"{text}",' & _
		'"account":"{account}","time":"{time}","host":"{host}","app":"{app}"}'
Global Const $NOTIFY_TPL_SLACK = '{"text":"{headline}\n{message}"}'
Global Const $NOTIFY_TPL_DISCORD = '{"content":"**{headline}**\n{message}"}'
Global Const $NOTIFY_TPL_TEAMS = '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive",' & _
		'"contentUrl":null,"content":{"$schema":"http://adaptivecards.io/schemas/adaptive-card.json","type":"AdaptiveCard",' & _
		'"version":"1.4","body":[{"type":"TextBlock","text":"{headline}","weight":"Bolder","size":"Medium","wrap":true},' & _
		'{"type":"TextBlock","text":"{message}","wrap":true},{"type":"TextBlock","text":"{time}","isSubtle":true,' & _
		'"spacing":"None","wrap":true}]}}]}'

; ---------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------

; E1: "/notify <job file>" - this program was started by itself only to send
; one notification (see _NotifyProcessMain()): no single-instance check, no
; tray icon, no listeners. Must come before _Singleton().
If $CmdLine[0] >= 2 Then
	If $CmdLine[1] = "/notify" Then
		_NotifyProcessMain($CmdLine[2])
		Exit
	EndIf
EndIf

; Prevent a second instance (named mutex). Flag 1 matters: on collision
; it returns 0 here instead of _Singleton() exiting internally, so this
; can still log first, with no message shown to the user.
If _Singleton($g_sAppName, 1) = 0 Then
	LogFile($g_sAppName & " is already running - this second instance is exiting immediately without doing anything.")
	Exit
EndIf

_Main()

; ############################################################################
; #  MAIN PROGRAM FLOW
; ############################################################################

; ============================================================================
; _Main
; ----------------------------------------------------------------------------
; Description : Program entry point. Configures the tray menu behaviour,
;               loads the [General] section of the INI file into its
;               globals via _LoadGeneralSettings() (see the "backing the
;               INI file's [General] section" globals declared near the top
;               of the script, e.g. $g_iLogLevel / used by LogFile(), and $g_iAcceptCheckIntervalMs / used by the
;               loop below), starts the TCP subsystem, (re)writes the
;               PowerShell TLS helper script, optionally clears the log
;               file for a fresh session (_ClearLogsOnStartIfConfigured -
;               driven by the $g_bClearLogOnStart global), loads the
;               configuration file, starts all configured SMTP
;               listeners, builds the tray menu, opens the Account Settings
;               dialog directly if no account is configured yet at all
;               (a direct prompt to add the first one, rather than
;               leaving a first-time user to go find the tray menu
;               themselves), and then runs the main
;               loop for the lifetime of the program: it polls tray
;               events, then calls _ServiceConnections() (accepts new
;               client connections and pumps data for all currently
;               active ones) once per iteration, in a single non-blocking
;               cycle ($g_iMainLoopTickMs between iterations - default
;               5ms; this directly bounds how much latency the proxy
;               itself adds to each leg of a relayed SMTP conversation,
;               see the "MainLoopTickMs" INI setting). Every GUI dialog
;               and the OAuth2 redirect wait (_Auth_WaitForRedirect) call
;               _ServiceConnections() from inside their own message/wait
;               loops too - see its header comment for why this matters:
;               without it, opening so much as the Settings dialog would
;               silently stop the proxy from working until it is closed
;               again, since AutoIt is single-threaded and every one of
;               those loops otherwise fully monopolises execution while
;               it runs.
;               Right after the "started" line (which includes the version,
;               see _GetScriptVersion()) it logs any warnings about invalid
;               INI values collected by _IniReadInt(). "Exit" asks for
;               confirmation while connections are active.
; Parameters  : (none)
; Returns     : (nothing - only returns when the process exits)
; ============================================================================
Func _Main()

	_LoadGeneralSettings()
	$g_iLastAcceptCheck = TimerInit()

	; Catch COM errors (e.g. from WinHttp) so the script does not crash
	Local $oComErrorHandler = ObjEvent("AutoIt.Error", "_ComErrorHandler")
	TCPStartup()

	_EnsureRelayHelperScript() ; also creates the "log" folder (E3)
	_ClearLogsOnStartIfConfigured()

	LogFile($g_sAppName & " started (version " & _GetScriptVersion() & ")")
	LogFile("TCP wait time per accept/receive check (TcpTimeoutMs): " & $g_iTcpTimeoutMs & " ms", 5)
	; B1: report INI values that were out of range (collected while the
	; settings were read, before the log file was set up).
	If $g_sSettingsWarnings <> "" Then
		Local $aSettingsWarn = StringSplit(StringTrimRight($g_sSettingsWarnings, 2), @CRLF, 1)
		Local $iWarn = 0
		For $iWarn = 1 To $aSettingsWarn[0]
			LogFile($aSettingsWarn[$iWarn])
		Next
	EndIf
	_NotifyLoadSettings() ; E1

	_LoadAllListeners()
	_StartAllListeners()
	_RebuildTrayMenu()

	; E1: "Proxy started", and "Sign-in required" for every active account
	; that has no stored sign-in (devices using it cannot send right now).
	_NotifyEvent("start", "", "Version " & _GetScriptVersion() & " started with " & $g_oAccountsByEmail.Count & " account(s).")
	Local $aStartEmails = $g_oAccountsByEmail.Keys()
	Local $iStartAcc = 0
	For $iStartAcc = 0 To UBound($aStartEmails) - 1
		Local $oStartAcc = $g_oAccountsByEmail.Item($aStartEmails[$iStartAcc])
		Local $oStartL = _FindListenerForAccount($aStartEmails[$iStartAcc])
		If $oStartAcc.Item("NeedsReauth") And IsObj($oStartL) And $oStartL.Item("Active") Then
			_NotifyEvent("reauth", $oStartAcc.Item("Username"), "No valid sign-in is stored for this account - devices using " & _
					"it cannot send e-mail until someone signs in via the tray menu.")
		EndIf
	Next

	If $g_oAccountsByEmail.Count = 0 Then
		TrayTip($g_sAppName, "No account configured yet. Please add one now.", 10)
		; Straight to Settings, as a direct prompt to add the first
		; account, rather than leaving a first-time user to discover the
		; tray menu on their own - opens with an empty list, "New"
		; front and center, exactly as if the user had clicked it
		; themselves.
		_ShowSettingsDialog()
	EndIf

	; -------------------------------------------------------------------
	; Main loop: tray events, new connections and active connections are
	; all handled within the same (non-blocking) cycle.
	; -------------------------------------------------------------------
	While 1
		Local $nTrayMsg = TrayGetMsg()
		If $nTrayMsg <> 0 Then
			Switch $nTrayMsg
				Case $g_idMenuAccounts
					_ShowSettingsDialog()

				Case $g_idMenuAdvanced
					_ShowAdvancedSettingsDialog()

				Case $g_idMenuNotifications
					_ShowNotificationSettingsDialog() ; E1

				Case $g_idTrayTitle
					; R1 (v61): the title item (program name + version) opens the
					; About dialog - the separate "About" item was removed.
					_ShowAboutDialog()

				Case $g_idMenuOpenLog
					; ShellExecute() opens the file with whatever program
					; is associated with .log (Notepad, by default, on a
					; typical Windows install) - if that program is not
					; itself already running, this returns immediately
					; without blocking the proxy (a brand new process is
					; started; ShellExecute() does not wait for it), same
					; as ShellExecute() already being used for opening the
					; OAuth2 sign-in URL in the user's browser.
					If FileExists($g_sLogPath) Then
						ShellExecute($g_sLogPath)
					Else
						_ProxyMsgBox(48, "No log file yet", "The log file does not exist yet:" & @CRLF & $g_sLogPath)
					EndIf

				Case $g_idMenuAutostart
					_ToggleAutostart()
					; Update just this one item's checkmark directly,
					; rather than tearing down and rebuilding the entire
					; tray menu (accounts, icons, everything) just to
					; reflect one flag - _IsAutostartEnabled() re-reads
					; the registry fresh, so this reflects the actual new
					; state regardless of which way it was just toggled.
					; The @Compiled check matters here too, same as in
					; _RebuildTrayMenu(): a registry entry could still
					; exist from an earlier compiled run even while this
					; is now running uncompiled (where _ToggleAutostart()
					; never touches it), and without this check the
					; checkmark would misleadingly show "on" right after
					; a click that _ToggleAutostart() just explained (via
					; TrayTip()) did nothing.
					If @Compiled And _IsAutostartEnabled() Then
						TrayItemSetState($g_idMenuAutostart, $TRAY_CHECKED)
					Else
						TrayItemSetState($g_idMenuAutostart, $TRAY_UNCHECKED)
					EndIf

				Case $g_idMenuExit
					; E6: do not cut off transfers in progress without asking
					If $g_oActiveConnections.Count > 0 Then
						If _ProxyMsgBox(BitOR(4, 48), "Exit " & $g_sAppName & "?", $g_oActiveConnections.Count & _
								" connection(s) are active right now - an e-mail may be in transfer." & @CRLF & _
								"Exiting closes them immediately." & @CRLF & @CRLF & "Exit anyway?") <> 6 Then ContinueLoop
					EndIf
					_Shutdown()
					Exit

				Case Else
					If $g_oAccountMenuItems.Exists(String($nTrayMsg)) Then
						Local $sEmail = $g_oAccountMenuItems.Item(String($nTrayMsg))
						If $g_oAccountsByEmail.Exists($sEmail) Then
							Local $oAcc = $g_oAccountsByEmail.Item($sEmail)
							Local $oListenerClicked = _FindListenerForAccount($sEmail)
							Local $bProceedWithSignIn = True

							If IsObj($oListenerClicked) And Not $oListenerClicked.Item("Active") Then
								; [disabled] - signing in would not actually
								; change anything, since the listener stays
								; disabled either way until re-enabled via
								; Settings, so skip the whole interactive
								; flow (browser + up to a 3-minute wait) and
								; just point at where to fix that instead.
								; _ProxyMsgBox() (not a native MsgBox()) so
								; this does not block the proxy while shown.
								_ProxyMsgBox(48, "Account disabled", _
										$sEmail & " is currently disabled." & @CRLF & _
										"Enable it first via Settings (""Enable/Disable"") before signing in.")
								$bProceedWithSignIn = False
							ElseIf Not $oAcc.Item("NeedsReauth") Then
								; [signed in] - confirm first (again via
								; _ProxyMsgBox(), not a blocking native
								; MsgBox()), since silently re-running the
								; whole interactive flow for an account that
								; already has valid tokens would be an easy
								; accidental click to make with no real
								; upside, only a needless round trip through
								; the browser.
								If _ProxyMsgBox(BitOR(4, 48), "Sign in again?", _
										$sEmail & " is already signed in." & @CRLF & _
										"Sign in again anyway?") <> 6 Then $bProceedWithSignIn = False
							EndIf
							; [sign-in required] falls through both checks
							; above unchanged - the direct, expected case.

							If $bProceedWithSignIn Then
								; NeedsReauth is already set correctly by _SaveTokens()
								; on a genuine success (called from
								; _RunInteractiveAuth() -> _Auth_ExchangeCode()) - it
								; must NOT be cleared here unconditionally, or a
								; cancelled/failed sign-in attempt would incorrectly
								; end up shown as "[signed in]" in the tray menu.
								; _DialogOpened()/_DialogClosed() here for the same
								; reason every other dialog uses them: without this,
								; the tray menu stays fully clickable for the whole
								; up-to-3-minute browser wait, and clicks made during
								; it would queue up instead of doing nothing visibly,
								; exactly like the problem that motivated
								; _SetTrayMenuEnabled() in the first place - this is
								; the one place that flow could still be entered
								; without going through a dialog at all.
								_DialogOpened()
								_RunInteractiveAuth($oAcc)
								_DialogClosed()
								_RebuildTrayMenu()
							EndIf
						EndIf
					EndIf
			EndSwitch
		EndIf

		; Every active connection is only serviced once per tick (see
		; _ServiceConnections()), so this directly bounds how much latency
		; the proxy itself adds to each leg of a relayed SMTP conversation -
		; see the "MainLoopTickMs" INI setting under [General] (read by
		; _LoadGeneralSettings()) for tuning notes. Only actually slept
		; when _ServiceConnections() itself reports an idle tick - see its
		; own header comment for why.
		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_Main

; ============================================================================
; _ServiceConnections
; ----------------------------------------------------------------------------
; Description : Does one "tick" of proxy work: accepts new client
;               connections if $g_iAcceptCheckIntervalMs has elapsed since
;               the last check (see the comment this was moved from, in
;               _Main(), for why that throttling exists - TCPAccept() has
;               measurable per-call latency even when nothing is pending,
;               so checking it on every single tick would slow down
;               everything else that also runs once per tick; until v36
;               that was the full Opt("TCPTimeout") of 100 ms, since v37
;               it is set to TcpTimeoutMs = 0 - see _LoadGeneralSettings()),
;               then
;               proactively refreshes any account's access token that is
;               getting close to expiry (_ProactiveTokenRefresh() - see
;               its own header comment), then pumps data for every
;               currently active connection (_PumpConnection()).
;               Returns True if anything real happened this tick (a new
;               connection accepted, or any connection relaying data) -
;               callers use this to skip their own end-of-tick Sleep()
;               while a transfer is actively in progress, the same way
;               the PowerShell relay script's own main loop does (see
;               its "$anyActivity" comment in _EnsureRelayHelperScript())
;               rather than adding a fixed MainLoopTickMs delay after
;               every single tick regardless of whether more was already
;               waiting to be relayed.
;               This is the one piece of "keep the proxy actually
;               working" logic in the whole script, factored out so it
;               can be called from more than just _Main()'s own loop:
;               every GUI dialog's message loop (_ShowSettingsDialog(),
;               _ShowEditAccountDialog(), _ShowAddAccountDialog(),
;               _ShowSendTestEmailDialog(), _ProxyMsgBox()) and
;               _Auth_WaitForRedirect()'s OAuth2 redirect wait loop call
;               this too. Without that, AutoIt being single-threaded means
;               any one of those - e.g. simply having the Settings dialog
;               open, or a sign-in attempt that has not yet completed -
;               would fully monopolise execution and silently stop the
;               proxy from accepting or relaying anything until it closes
;               again, since none of those are "the" main loop and
;               nothing else runs while they are.
;               It also starts with _CheckLoopGap(), which measures how long
;               the previous pass of the main loop took and writes a warning
;               to the log if something blocked it (see there), and ends
;               with _UpdateTrayTooltip(), which refreshes the tray icon's
;               status tooltip (at most every 2 seconds), _LogRotationTick()
;               and _NotifyTick() (E1: heartbeat ping, results of the
;               notification processes).
; Parameters  : (none)
; Returns     : True if a new connection was accepted or any active
;               connection relayed data this tick, False if the tick was
;               genuinely idle.
; ============================================================================
Func _ServiceConnections()
	_CheckLoopGap()

	Local $bAnyActivity = False

	If TimerDiff($g_iLastAcceptCheck) >= $g_iAcceptCheckIntervalMs Then
		$g_iLastAcceptCheck = TimerInit()
		Local $iConnectionsBefore = $g_oActiveConnections.Count
		_AcceptNewConnections()
		If $g_oActiveConnections.Count > $iConnectionsBefore Then $bAnyActivity = True
	EndIf

	_ProactiveTokenRefresh()

	Local $aKeys = $g_oActiveConnections.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		If $g_oActiveConnections.Exists($aKeys[$i]) Then
			_PumpConnection($g_oActiveConnections.Item($aKeys[$i]), $bAnyActivity)
		EndIf
	Next

	_UpdateTrayTooltip() ; E8
	_LogRotationTick()   ; E3
	_NotifyTick()        ; E1: heartbeat + results of the notification processes

	Return $bAnyActivity
EndFunc   ;==>_ServiceConnections

; ============================================================================
; _CheckLoopGap
; ----------------------------------------------------------------------------
; Description : Called at the start of every _ServiceConnections() pass.
;               Measures the time since the previous pass started. AutoIt is
;               single-threaded, so while anything blocks (an HTTPS call to
;               Microsoft/Google, a write into the pipe of a stuck helper
;               process, the PC being in standby, ...), NOTHING else runs -
;               no connection is accepted, no data relayed - and a client
;               simply sees "connected, but no answer". If a pass took
;               longer than $g_iLoopBlockWarnMs, a warning with the duration
;               and the longest operation timed by _OpEnd() during that
;               time is written to the log, so the cause is visible
;               afterwards. A second check compares the system clock with
;               this program's own timer (about once per second) to spot a
;               standby/hibernation or a clock change.
;               Limit: a block that never ends cannot be logged from inside
;               the blocked process itself - in that case the last line in
;               the log, the tray menu not reacting and the CPU use in Task
;               Manager (spinning vs. idle) are the clues.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _CheckLoopGap()
	If $g_iLoopBlockWarnMs <= 0 Then Return

	If $g_hLastServiceTick = 0 Then
		$g_hLastServiceTick = TimerInit()
		$g_hLastWallTimer = TimerInit()
		$g_iLastWallSec = _UnixTimeNow()
		Return
	EndIf

	Local $iGapMs = Round(TimerDiff($g_hLastServiceTick))
	$g_hLastServiceTick = TimerInit()

	Local $iClockJumpMs = 0
	Local $iTimerSinceMs = Round(TimerDiff($g_hLastWallTimer))
	If $iTimerSinceMs >= 1000 Then
		Local $iWallNow = _UnixTimeNow()
		Local $iWallSinceMs = ($iWallNow - $g_iLastWallSec) * 1000
		If $iWallSinceMs - $iTimerSinceMs > 10000 Then $iClockJumpMs = $iWallSinceMs - $iTimerSinceMs
		$g_iLastWallSec = $iWallNow
		$g_hLastWallTimer = TimerInit()
	EndIf

	If $iGapMs >= $g_iLoopBlockWarnMs Or $iClockJumpMs > 0 Then
		Local $sWhat = ""
		If $g_iGapLongestOpMs > 0 Then
			$sWhat = "Longest timed operation in that period: " & $g_sGapLongestOp & " (" & _FormatDurationMs($g_iGapLongestOpMs) & ")."
			If $g_iGapLongestOpMs * 2 < $iGapMs Then
				$sWhat &= " This does not account for the whole delay."
			ElseIf StringRegExp($g_sGapLongestOp, "(?i)^HTTPS request to https?://\S*token\S*$") Then
				; P1: say in plain words what it was. A token refresh is a
				; blocking HTTPS call (see C6 in the README roadmap); normally it takes about
				; 0.3 s - several seconds mean the provider's sign-in service
				; was slow (seen 12./13.11.2026 during a Microsoft 365
				; disruption: 5.9 s and 12.3 s), not a problem of this PC.
				Local $aHost = StringRegExp($g_sGapLongestOp, "(?i)https?://([^/ ]+)", 1)
				Local $sHost = "the sign-in service"
				If Not @error Then $sHost = $aHost[0]
				$sWhat &= " That was the OAuth2 token request (normally the token refresh) - the provider's sign-in service (" & $sHost & _
						") answered slowly (normally well under 1 s); nothing was wrong with this PC or the proxy. If this" & _
						" happens often, check the provider's service status."
			EndIf
		Else
			; AutoIt pauses the whole script while its tray menu is open (the menu
			; runs a modal Windows menu loop) - by far the most common cause of
			; this warning when someone works on the PC (solved for good by L1 in the README roadmap).
			$sWhat = "No timed operation explains it - most likely the tray menu was open (AutoIt pauses the program while it is shown)," & _
					" otherwise the process was suspended (PC standby/hibernation, security software) or blocked in code that is not timed."
		EndIf
		If $iClockJumpMs > 0 Then $sWhat &= " The system clock advanced " & _FormatDurationMs($iClockJumpMs) & " more than this program's own timer - the PC was most likely in standby/hibernation (or the clock was changed)."
		LogFile("Warning: the main loop was not serviced for " & _FormatDurationMs($iGapMs) & " (warning threshold " & _
				_FormatDurationMs($g_iLoopBlockWarnMs) & ") - nothing was accepted or relayed during that time. " & $sWhat & _
				" Active connections now: " & $g_oActiveConnections.Count & ".")
		_StatsNoteError("main loop blocked " & _FormatDurationMs($iGapMs)) ; E8
		; E1: a real block (not a standby of the PC) of at least LoopBlockSec
		If $iClockJumpMs = 0 And $iGapMs >= $g_iNotifyLoopBlockSec * 1000 Then
			_NotifyEvent("loopblock", "", "For " & _FormatDurationMs($iGapMs) & " nothing could be accepted or relayed. " & $sWhat)
		EndIf
	EndIf

	$g_sGapLongestOp = ""
	$g_iGapLongestOpMs = 0
EndFunc   ;==>_CheckLoopGap

; ============================================================================
; _OpEnd
; ----------------------------------------------------------------------------
; Description : Ends the timing of one operation that may block the whole
;               program (see _CheckLoopGap()) and remembers it if it is the
;               longest one since the previous main-loop pass. Cheap enough
;               to call on every chunk of data.
; Parameters  : $hTimer  - TimerInit() value taken just before the operation.
;               $sName   - Short description of the operation.
;               $vDetail - Optional extra detail (e.g. a PID or URL), only
;               appended to the name if this operation is the longest so far.
; Returns     : The duration in milliseconds.
; ============================================================================
Func _OpEnd($hTimer, $sName, $vDetail = "")
	Local $iMs = Round(TimerDiff($hTimer))
	If $iMs > $g_iGapLongestOpMs Then
		$g_iGapLongestOpMs = $iMs
		$g_sGapLongestOp = $sName
		If String($vDetail) <> "" Then $g_sGapLongestOp &= " " & $vDetail
	EndIf
	Return $iMs
EndFunc   ;==>_OpEnd

; ============================================================================
; _ProactiveTokenRefresh
; ----------------------------------------------------------------------------
; Description : Refreshes any configured account's OAuth2 access token
;               that is getting close to expiry (within
;               $g_iProactiveRefreshLeadSec, default 600s/10 minutes),
;               BEFORE a client connection actually needs it - so that
;               by the time one does, _Auth_GetValidAccessToken() finds
;               an already-fresh cached token instead of having to
;               perform its own on-demand, blocking refresh right then.
;
;               Why this matters: _Auth_RefreshToken() (called from
;               either this function or _Auth_GetValidAccessToken())
;               makes a synchronous WinHTTP call (_HttpPostForm()) that
;               blocks this entire single-threaded process for its
;               duration (typically well under a second, bounded by
;               $g_iHttpTimeoutMs in the worst case) - while it runs, no
;               other connection is serviced at all. An on-demand refresh
;               happening to coincide with another connection actively
;               relaying data would delay that other connection
;               noticeably; a refresh done here, during an otherwise
;               idle tick, is far less likely to coincide with one.
;               This does not ELIMINATE the possibility of a blocking
;               on-demand refresh (a client can still connect and need a
;               token that happens to have just gone stale, e.g. right
;               after this program starts, before the first check below
;               has even run once) - it only makes that the rare
;               fallback case instead of the normal one. See the
;               project's own code review notes for two heavier
;               alternatives (a background helper process, or WinHTTP's
;               asynchronous mode) that were considered and not chosen,
;               since this option gives most of the practical benefit
;               for a small fraction of the implementation risk.
;
;               Throttled to run at most once every 30 seconds
;               (hardcoded - unlike the other timing knobs, this one is
;               cheap enough, and inconsequential enough to get slightly
;               wrong, that it did not seem worth its own INI setting)
;               via $g_iLastProactiveRefreshCheck, regardless of how
;               often _ServiceConnections() itself is called (which can
;               be every few milliseconds while the main loop is
;               otherwise idle).
;
;               An account with NeedsReauth=True is skipped outright -
;               there is no refresh token to use without the user
;               interactively signing in again, which this function does
;               not attempt to trigger on its own (that stays a
;               user-initiated action, same as it is everywhere else in
;               this script). The refresh token itself is lazily
;               decrypted from the INI file on first use here, the same
;               way _Auth_GetValidAccessToken() already does, so this
;               works correctly even for an account that has not had any
;               connection yet this session.
;
;               After a failed attempt the next one for that account waits
;               longer each time (30 s, 60 s, 120 s ... up to 10 minutes,
;               kept in RefreshFailCount/RefreshRetryAt), so an unreachable
;               token endpoint does not block the proxy every 30 seconds; any
;               successful refresh, also an on-demand one, resets this (see
;               _Auth_RefreshToken()). A fully asynchronous refresh is on the
;               roadmap (C6, README section 16) but has not been needed so far.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _ProactiveTokenRefresh()
	If TimerDiff($g_iLastProactiveRefreshCheck) < 30000 Then Return
	$g_iLastProactiveRefreshCheck = TimerInit()

	Local $aKeys = $g_oAccountsByEmail.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		Local $oAcc = $g_oAccountsByEmail.Item($aKeys[$i])
		If $oAcc.Item("NeedsReauth") Then ContinueLoop

		If $oAcc.Item("RefreshToken") = "" Then
			Local $sEnc = IniRead($g_sIniPath, $oAcc.Item("IniSection"), "RefreshTokenEnc", "")
			If $sEnc <> "" Then $oAcc.Item("RefreshToken") = _DPAPI_Unprotect($sEnc, "refresh token of " & $oAcc.Item("Username"))
		EndIf
		If $oAcc.Item("RefreshToken") = "" Then ContinueLoop ; nothing to refresh with yet (never signed in)

		Local $iExpiry = Number($oAcc.Item("AccessTokenExpiry"))
		If ($iExpiry - _UnixTimeNow()) > $g_iProactiveRefreshLeadSec Then ContinueLoop ; not due yet
		If _UnixTimeNow() < Number($oAcc.Item("RefreshRetryAt")) Then ContinueLoop ; C3: waiting after a failed attempt (backoff)

		LogFile("_ProactiveTokenRefresh: refreshing " & $oAcc.Item("Username") & " (access token expires in " & _
				($iExpiry - _UnixTimeNow()) & "s, lead time is " & $g_iProactiveRefreshLeadSec & "s) ...", 6)
		If Not _Auth_RefreshToken($oAcc, "proactive") Then
			; C3: back off instead of retrying (and blocking) every 30 s while the
			; provider cannot be reached: 30 s, 60 s, 120 s ... up to 10 minutes.
			; A success (also an on-demand one) resets this - see _Auth_RefreshToken().
			Local $iFails = Number($oAcc.Item("RefreshFailCount")) + 1
			$oAcc.Item("RefreshFailCount") = $iFails
			Local $iWaitSec = 30 * (2 ^ ($iFails - 1))
			If $iWaitSec > 600 Then $iWaitSec = 600
			$oAcc.Item("RefreshRetryAt") = _UnixTimeNow() + $iWaitSec
			LogFile("Proactive token refresh for " & $oAcc.Item("Username") & " failed " & $iFails & _
					" time(s) in a row - next attempt in " & $iWaitSec & " s.")
		EndIf
	Next
EndFunc   ;==>_ProactiveTokenRefresh

; ============================================================================
; _IsAutostartEnabled
; ----------------------------------------------------------------------------
; Description : Checks whether this program is currently registered to
;               start automatically with Windows, by reading the
;               "Run" registry value named after $g_sAppName under
;               $g_sAutostartRegKey. Only ever True if that value both
;               exists AND matches this exact program's current path
;               (quoted, matching what _ToggleAutostart() itself writes)
;               - a stale entry left over from the exe having since been
;               moved/renamed reads as "not enabled" rather than
;               silently claiming autostart is on for a path that no
;               longer matches where this copy is actually running from;
;               clicking the tray item again in that case simply
;               overwrites it with the current, correct path.
; Parameters  : (none)
; Returns     : True if enabled and pointing at this exact program path,
;               False otherwise (including if the value does not exist
;               at all).
; ============================================================================
Func _IsAutostartEnabled()
	Local $sExpected = '"' & @ScriptFullPath & '"'
	Local $sCurrent = RegRead($g_sAutostartRegKey, $g_sAppName)
	If @error Then Return False
	Return ($sCurrent = $sExpected)
EndFunc   ;==>_IsAutostartEnabled

; ============================================================================
; _ToggleAutostart
; ----------------------------------------------------------------------------
; Description : Handles a click on the tray menu's "Autostart" item.
;               Only does anything when @Compiled - autostart pointing
;               at a raw, uncompiled .au3 script would not work anyway
;               (nothing would be there to interpret it without AutoIt
;               itself, and there is no reliable "this machine has
;               AutoIt installed" assumption to make), so in that case
;               this deliberately makes no registry change at all, logs a
;               note explaining why, and also shows a TrayTip() - a click
;               on a checkable tray item is otherwise easy to assume did
;               something, so this makes the "not available like this"
;               outcome visible right where the click happened, not just
;               in the log file. When compiled, toggles based on the
;               CURRENT state as read fresh from the registry via
;               _IsAutostartEnabled() (not a separately-tracked flag of
;               our own - the registry itself is the single source of
;               truth here, so this can never drift out of sync with
;               it, e.g. if a value was ever removed by some other
;               means): writes the "Run" value (REG_SZ, this program's
;               current path, quoted) if it was not enabled, or deletes
;               it if it was. The caller is expected to follow up with
;               _RebuildTrayMenu() to refresh the checkmark shown next
;               to the item.
; Parameters  : (none)
; Returns     : (nothing - writes to the registry and the log file as a
;               side effect)
; ============================================================================
Func _ToggleAutostart()
	If Not @Compiled Then
		LogFile("Autostart was clicked, but this is not the compiled program (running as a raw .au3 " & _
				"script) - no registry change was made. Autostart only applies to the compiled .exe.")
		TrayTip($g_sAppName, "Autostart is only available in the compiled program (the .exe) - it has " & _
				"no effect when running this as a raw script.", 10)
		Return
	EndIf

	If _IsAutostartEnabled() Then
		RegDelete($g_sAutostartRegKey, $g_sAppName)
		If @error Then
			LogFile("Error: could not remove the autostart registry entry (" & $g_sAutostartRegKey & "\" & $g_sAppName & ").")
		Else
			LogFile("Autostart disabled (removed " & $g_sAutostartRegKey & "\" & $g_sAppName & ").")
		EndIf
	Else
		RegWrite($g_sAutostartRegKey, $g_sAppName, "REG_SZ", '"' & @ScriptFullPath & '"')
		If @error Then
			LogFile("Error: could not create the autostart registry entry (" & $g_sAutostartRegKey & "\" & $g_sAppName & ").")
		Else
			LogFile("Autostart enabled (" & $g_sAutostartRegKey & "\" & $g_sAppName & " = " & @ScriptFullPath & ").")
		EndIf
	EndIf
EndFunc   ;==>_ToggleAutostart

; ============================================================================
; _SetTrayMenuEnabled
; ----------------------------------------------------------------------------
; Description : Enables or disables every tray menu item except the
;               entries INSIDE the Settings submenu (Accounts, Advanced,
;               the separator, Autostart): they need no state of their own,
;               because the submenu cannot be opened while "Settings" itself
;               is disabled. See _DialogOpened() /
;               _DialogClosed(), which call this whenever the count of
;               currently-open dialogs transitions to/from zero.
; Parameters  : $bEnabled - True to enable every item, False to disable
;               every item.
; Returns     : (nothing)
; ============================================================================
Func _SetTrayMenuEnabled($bEnabled)
	Local $i = 0
	For $i = 0 To UBound($g_aAllTrayItemIds) - 1
		; The items INSIDE the Settings submenu need no state of their own:
		; while "Settings" itself is disabled, the submenu cannot be opened.
		Switch $g_aAllTrayItemIds[$i]
			Case $g_idMenuAccounts, $g_idMenuAdvanced, $g_idMenuNotifications, $g_idMenuSettingsSep, $g_idMenuAutostart
				ContinueLoop
		EndSwitch
		If $bEnabled Then
			TrayItemSetState($g_aAllTrayItemIds[$i], $TRAY_ENABLE)
		Else
			TrayItemSetState($g_aAllTrayItemIds[$i], $TRAY_DISABLE)
		EndIf
	Next
EndFunc   ;==>_SetTrayMenuEnabled

; ============================================================================
; _DialogOpened / _DialogClosed
; ----------------------------------------------------------------------------
; Description : Every GUI dialog in this script (Settings, About, New,
;               Edit, Test E-Mail, Advanced, _ProxyMsgBox()) calls
;               _DialogOpened() right after creating its window and
;               _DialogClosed() on every one of its own exit paths (right
;               before each Return). $g_iOpenDialogCount tracks how many
;               are currently open at once, since dialogs can be nested
;               (e.g. Settings -> Edit -> a validation _ProxyMsgBox()) -
;               the tray menu is disabled only once, when the FIRST
;               dialog opens (count 0 -> 1), and re-enabled only once
;               every dialog has closed again (count -> 0), rather than
;               toggling on every individual dialog regardless of
;               nesting.
;               This exists because AutoIt is single-threaded: while any
;               dialog's own message loop has control, _Main()'s own loop
;               - the only place TrayGetMsg() is ever polled - does not
;               run at all, so a tray menu click made while a dialog is
;               open does not do nothing, it queues up and then fires
;               only once every open dialog finally closes and control
;               returns to _Main(), all at once, well after the click -
;               visibly surprising, and easy to mistake for a missed
;               click and (mistakenly) retry into a queued-up pile of
;               clicks. Disabling the tray menu for as long as any dialog
;               is open makes this visibly unavailable instead, exactly
;               as it actually is, rather than silently queuing input.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _DialogOpened()
	$g_iOpenDialogCount += 1
	If $g_iOpenDialogCount = 1 Then _SetTrayMenuEnabled(False)
EndFunc   ;==>_DialogOpened

; Counterpart of _DialogOpened() (same header): re-enables the tray menu
; once the last open dialog has closed.
Func _DialogClosed()
	$g_iOpenDialogCount -= 1
	If $g_iOpenDialogCount <= 0 Then
		$g_iOpenDialogCount = 0
		_SetTrayMenuEnabled(True)
	EndIf
EndFunc   ;==>_DialogClosed

; ============================================================================
; _SetDialogIcon
; ----------------------------------------------------------------------------
; Description : Sets the title bar / taskbar icon for a dialog window to
;               the app's own default icon. A compiled .exe's windows
;               already inherit this automatically - the same reason
;               TraySetIcon(@ScriptFullPath) needs no icon number in
;               _RebuildTrayMenu() - but a window created while running
;               uncompiled (via the AutoIt interpreter, e.g. from SciTE)
;               shows no icon of its own unless one is set explicitly.
;               Mirrors the same @Compiled branching used everywhere else
;               in the script for icon resources, so every dialog looks
;               the same whether run compiled or not. Called once, right
;               after GUICreate(), by every dialog function in the script.
; Parameters  : $hGui - Window handle (from GUICreate()) to set the icon on.
; Returns     : (nothing)
; ============================================================================
Func _SetDialogIcon($hGui)
	If @Compiled Then
		GUISetIcon(@ScriptFullPath, Default, $hGui)
	Else
		GUISetIcon(@ScriptDir & "\icons\default.ico", Default, $hGui)
	EndIf
EndFunc   ;==>_SetDialogIcon

; ============================================================================
; _ProxyMsgBox
; ----------------------------------------------------------------------------
; Description : Drop-in replacement for MsgBox() that keeps the proxy
;               working (via _ServiceConnections(), on every message-loop
;               tick) for as long as it is left on screen, instead of
;               freezing everything the way a native MsgBox() call does -
;               see _ServiceConnections()'s header comment for why a
;               native MsgBox has exactly the same "blocks the whole
;               proxy" problem as any other modal dialog here, and cannot
;               be fixed by adding anything to ITS OWN loop, since AutoIt
;               has no way to run code while a MsgBox is on screen; it has
;               to be a real GUI window with its own message loop instead.
;               Deliberately does not attempt to draw a matching icon
;               graphic (unlike the icon/severity that a native MsgBox
;               shows) - the title text of every call site already states
;               the severity in words ("Error", "Incomplete input",
;               "Delete account?", ...), so this stays simple and safe
;               rather than risking a repeat of the tray icon rendering
;               problems from earlier.
;               Supports the two button layouts actually used in this
;               script: OK-only (default), and Yes/No when $iFlags has
;               bit 4 set (BitAND($iFlags, 4) = 4) - the same bit MsgBox()
;               itself uses for its Yes/No button set. The icon bits
;               (16/32/48/64) are accepted for call-site compatibility
;               with existing MsgBox() calls but otherwise ignored, per
;               the above.
; Parameters  : $iFlags   - Same "type" flag MsgBox() takes; only the
;               Yes/No button bit (4) is actually used.
;               $sTitle   - Window title.
;               $sText    - Message text (@CRLF for line breaks, same as
;               MsgBox()).
;               $hParent  - Optional owner window handle, so this stays
;               visually associated with (and on top of) the dialog it
;               belongs to - the same role MsgBox()'s own hwnd parameter
;               played at existing call sites. 0 (default) = no owner.
;               $iTextAreaHeight - Optional fixed height in pixels for the
;               text area. Default (-1, used by every call site): the
;               window is sized to fit the text (T1, v73) - see below.
; Returns     : 1 for OK-only mode (including via the window's close
;               button); 6 for Yes, 7 for No or the window's close button
;               in Yes/No mode - the same codes MsgBox() itself returns
;               for these buttons, so existing call sites that inspect
;               the return value (e.g. "<> 6") do not need to change.
;               Window size (T1, v73): up to v72 the text area was always
;               140 px high and the window 440 px wide, so a one- or
;               two-line question (e.g. "... is already signed in. Sign in
;               again anyway?") sat in a window far too big for it. Now the
;               text is measured with the label's own font
;               (__MsgBoxMeasureText()) and the window is made just big
;               enough: width between 300 and 520 px (longer lines wrap at
;               520), height as needed (at most 520 px of text).
; ============================================================================
Func _ProxyMsgBox($iFlags, $sTitle, $sText, $hParent = 0, $iTextAreaHeight = -1)
	Local $bYesNo = (BitAND($iFlags, 4) = 4)
	Local Const $iMinWidth = 300, $iMaxWidth = 520, $iMaxTextHeight = 520
	Local $iWidth = $iMaxWidth
	Local $iTextWidth = $iWidth - 40

	; Created at the largest size first; the label is needed to measure the
	; text with exactly the font it will be shown in, then window and label
	; are shrunk to fit before the window is shown.
	Local $hGui = GUICreate($sTitle, $iWidth, 200, -1, -1, -1, -1, $hParent)
	_SetDialogIcon($hGui)
	Local $idLabel = GUICtrlCreateLabel($sText, 20, 20, $iTextWidth, 140)

	If $iTextAreaHeight < 0 Then
		; 1st pass: natural width of the longest line (no wrapping)
		Local $aSize = __MsgBoxMeasureText($idLabel, $sText, 0)
		$iTextWidth = $aSize[0]
		If $iTextWidth = 0 Then $iTextWidth = 400 ; measuring failed: old width
		If $iTextWidth > $iMaxWidth - 40 Then $iTextWidth = $iMaxWidth - 40
		If $iTextWidth < $iMinWidth - 40 Then $iTextWidth = $iMinWidth - 40
		$iWidth = $iTextWidth + 40
		; 2nd pass: height at that width (long lines wrap)
		$aSize = __MsgBoxMeasureText($idLabel, $sText, $iTextWidth)
		$iTextAreaHeight = $aSize[1] + 4 ; small reserve against clipping
		If $aSize[1] = 0 Then $iTextAreaHeight = 140 ; measuring failed: old height
		If $iTextAreaHeight < 20 Then $iTextAreaHeight = 20
		If $iTextAreaHeight > $iMaxTextHeight Then $iTextAreaHeight = $iMaxTextHeight
	EndIf

	Local $iButtonY = 20 + $iTextAreaHeight + 15
	Local $iHeight = $iButtonY + 30 + 15
	GUICtrlSetPos($idLabel, 20, 20, $iTextWidth, $iTextAreaHeight)
	__MsgBoxSetClientSize($hGui, $iWidth, $iHeight)

	; -1 (never a real control ID, and never 0 - the value GUIGetMsg()
	; returns when no message is pending) for whichever of these three
	; buttons does NOT get created below, so the "no message this tick"
	; case can never accidentally match an unused Case here.
	Local $idOk = -1, $idYes = -1, $idNo = -1
	If $bYesNo Then
		$idYes = GUICtrlCreateButton("Yes", $iWidth / 2 - 100, $iButtonY, 90, 30)
		$idNo = GUICtrlCreateButton("No", $iWidth / 2 + 10, $iButtonY, 90, 30)
	Else
		$idOk = GUICtrlCreateButton("OK", $iWidth / 2 - 50, $iButtonY, 100, 30)
	EndIf

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	While 1
		Local $nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE
				GUIDelete($hGui)
				_DialogClosed()
				If $bYesNo Then Return 7
				Return 1

			Case $idOk
				GUIDelete($hGui)
				_DialogClosed()
				Return 1

			Case $idYes
				GUIDelete($hGui)
				_DialogClosed()
				Return 6

			Case $idNo
				GUIDelete($hGui)
				_DialogClosed()
				Return 7
		EndSwitch

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ProxyMsgBox

; ============================================================================
; __MsgBoxMeasureText
; ----------------------------------------------------------------------------
; Description : Internal helper of _ProxyMsgBox() (T1): measures how much
;               space $sText needs when drawn with the font of the label
;               $idLabel, using the Win32 DrawText() function with
;               DT_CALCRECT (measures only, draws nothing).
; Parameters  : $idLabel - Control ID of the label (its font is used).
;               $sText   - The text (@CRLF line breaks allowed).
;               $iWidth  - 0 = no wrapping (returns the width of the
;                          longest line); > 0 = wrap at this width (as the
;                          label does) and return the resulting height.
; Returns     : Array [width, height] in pixels.
; ============================================================================
Func __MsgBoxMeasureText($idLabel, $sText, $iWidth)
	Local Const $DT_WORDBREAK_ = 0x10, $DT_EXPANDTABS_ = 0x40, $DT_CALCRECT_ = 0x400
	Local $aResult[2] = [0, 0]
	Local $hLabel = GUICtrlGetHandle($idLabel)
	; Plain DllCalls (user32 GetDC/DrawTextW/ReleaseDC, gdi32 SelectObject)
	; so this does not depend on which WinAPI UDF file contains which wrapper.
	Local $aRet = DllCall("user32.dll", "handle", "GetDC", "hwnd", $hLabel)
	If @error Or Not $aRet[0] Then Return $aResult
	Local $hDC = $aRet[0]
	; WM_GETFONT (0x31): the font the label really uses (AutoIt's GUI font)
	Local $hFont = GUICtrlSendMsg($idLabel, 0x31, 0, 0)
	Local $hOldFont = 0
	If $hFont Then
		$aRet = DllCall("gdi32.dll", "handle", "SelectObject", "handle", $hDC, "handle", $hFont)
		If Not @error Then $hOldFont = $aRet[0]
	EndIf
	Local $tRect = DllStructCreate($tagRECT)
	Local $iFlags = BitOR($DT_EXPANDTABS_, $DT_CALCRECT_)
	If $iWidth > 0 Then
		DllStructSetData($tRect, "Right", $iWidth)
		$iFlags = BitOR($iFlags, $DT_WORDBREAK_)
	EndIf
	DllCall("user32.dll", "int", "DrawTextW", "handle", $hDC, "wstr", $sText, "int", -1, "struct*", $tRect, "uint", $iFlags)
	$aResult[0] = DllStructGetData($tRect, "Right") - DllStructGetData($tRect, "Left")
	$aResult[1] = DllStructGetData($tRect, "Bottom") - DllStructGetData($tRect, "Top")
	If $hOldFont Then DllCall("gdi32.dll", "handle", "SelectObject", "handle", $hDC, "handle", $hOldFont)
	DllCall("user32.dll", "int", "ReleaseDC", "hwnd", $hLabel, "handle", $hDC)
	Return $aResult
EndFunc   ;==>__MsgBoxMeasureText

; ============================================================================
; __MsgBoxSetClientSize
; ----------------------------------------------------------------------------
; Description : Internal helper of _ProxyMsgBox() (T1): resizes a window so
;               that its CLIENT area (without title bar and border) gets
;               the given size, and centres it on the screen again.
; Parameters  : $hGui            - Window handle.
;               $iClientW/$iClientH - Wanted client area size in pixels.
; Returns     : (nothing)
; ============================================================================
Func __MsgBoxSetClientSize($hGui, $iClientW, $iClientH)
	Local $aPos = WinGetPos($hGui)
	Local $aClient = WinGetClientSize($hGui)
	If Not IsArray($aPos) Or Not IsArray($aClient) Then Return
	Local $iW = $iClientW + ($aPos[2] - $aClient[0])
	Local $iH = $iClientH + ($aPos[3] - $aClient[1])
	WinMove($hGui, "", (@DesktopWidth - $iW) / 2, (@DesktopHeight - $iH) / 2, $iW, $iH)
EndFunc   ;==>__MsgBoxSetClientSize

; ============================================================================
; _LoadGeneralSettings
; ----------------------------------------------------------------------------
; Description : Single point where the [General] section of the INI file is
;               read. If the INI file does not exist yet, it is first
;               created with the default value for every [General] setting.
;               Every setting is then read from disk into its dedicated
;               global variable (see the "backing the INI file's [General]
;               section" globals declared near the top of the script) -
;               no other function in the script should IniRead($g_sIniPath,
;               "General", ...) directly; they should read the global
;               instead. Must be called once, early during startup, before
;               any of those globals are used.
;               Whole-number settings are read through _IniReadInt(), which
;               replaces a value that is not a number or lies outside its
;               allowed range by the default and collects a warning that
;               _Main() writes to the log right after the "started" line.
;               Settings added in later versions (LoopBlockWarnMs,
;               PreAuthTimeoutMs, IdleCloseMs, MaxConnections, RelayDebugLog)
;               are written to an existing INI file with their default via
;               _EnsureIniDefault(), so they can be edited right away.
; Parameters  : (none)
; Returns     : (nothing - populates the [General] globals as a side effect)
; ============================================================================
Func _LoadGeneralSettings()

	If Not FileExists($g_sIniPath) Then
		IniWrite($g_sIniPath, "General", "ClearLogOnStart", "1")
		IniWrite($g_sIniPath, "General", "AuthPortStart", "8462")
		IniWrite($g_sIniPath, "General", "SmtpPortStart", "1587")
		IniWrite($g_sIniPath, "General", "UseLogFile", "1")
		Local $sDefaultLogLevel = "5"
		If Not @Compiled Then $sDefaultLogLevel = "9"
		IniWrite($g_sIniPath, "General", "LogLevel", $sDefaultLogLevel)
		IniWrite($g_sIniPath, "General", "AcceptCheckIntervalMs", "200")
		IniWrite($g_sIniPath, "General", "MainLoopTickMs", "5")
		IniWrite($g_sIniPath, "General", "RelayPollMs", "2")
		IniWrite($g_sIniPath, "General", "StallWatchdogMs", "15000")
		IniWrite($g_sIniPath, "General", "IdleWatchdogMs", "120000")
		IniWrite($g_sIniPath, "General", "AuthRedirectTimeoutSec", "180")
		IniWrite($g_sIniPath, "General", "HttpTimeoutMs", "15000")
		IniWrite($g_sIniPath, "General", "ProactiveRefreshLeadSec", "600")
	EndIf

	$g_bClearLogOnStart = (Number(IniRead($g_sIniPath, "General", "ClearLogOnStart", "1")) = 1)
	$g_iAuthPortStart = _IniReadInt("AuthPortStart", 8462, 1024, 65000)
	$g_iSmtpPortStart = _IniReadInt("SmtpPortStart", 1587, 1024, 65000)
	$g_bUseLogSetting = (Number(IniRead($g_sIniPath, "General", "UseLogFile", "1")) = 1)
	; The INI's "LogLevel" only applies when compiled - when run as a raw
	; script, $g_iLogLevel must always stay at 9 (full debug detail),
	; never lowered by whatever an earlier compiled run happened to save
	; to the INI (both share the same INI file).
	If @Compiled Then $g_iLogLevel = _IniReadInt("LogLevel", $g_iLogLevel, 0, 9)
	$g_iAcceptCheckIntervalMs = _IniReadInt("AcceptCheckIntervalMs", 200, 10, 5000)
	$g_iMainLoopTickMs = _IniReadInt("MainLoopTickMs", 5, 1, 100)
	$g_iRelayPollMs = _IniReadInt("RelayPollMs", 2, 1, 100)
	$g_iStallWatchdogMs = _IniReadInt("StallWatchdogMs", 15000, 1000, 600000)
	$g_iIdleWatchdogMs = _IniReadInt("IdleWatchdogMs", 120000, 10000, 86400000)
	$g_iAuthRedirectTimeoutSec = _IniReadInt("AuthRedirectTimeoutSec", 180, 30, 1800)
	$g_iHttpTimeoutMs = _IniReadInt("HttpTimeoutMs", 15000, 1000, 120000)
	$g_iProactiveRefreshLeadSec = _IniReadInt("ProactiveRefreshLeadSec", 600, 180, 3000)

	; Settings added in later versions: written to the INI with their default
	; if the file predates them, so they are visible and editable right away.
	_EnsureIniDefault("LoopBlockWarnMs", "3000")
	_EnsureIniDefault("PreAuthTimeoutMs", "60000")
	_EnsureIniDefault("IdleCloseMs", "600000")
	_EnsureIniDefault("MaxConnections", "5")
	_EnsureIniDefault("RelayDebugLog", "0")
	_EnsureIniDefault("TcpTimeoutMs", "0")
	_EnsureIniDefault("MaxLogSizeMB", "10")
	_EnsureIniDefault("LogGenerations", "5")
	_EnsureIniDefault("AuthResultTimeoutMs", "20000")
	$g_iLoopBlockWarnMs = _IniReadInt("LoopBlockWarnMs", 3000, 500, 600000, True)
	$g_iPreAuthTimeoutMs = _IniReadInt("PreAuthTimeoutMs", 60000, 10000, 3600000, True)
	$g_iAuthResultTimeoutMs = _IniReadInt("AuthResultTimeoutMs", 20000, 5000, 600000, True)
	$g_iIdleCloseMs = _IniReadInt("IdleCloseMs", 600000, 60000, 86400000, True)
	$g_iMaxConnections = _IniReadInt("MaxConnections", 5, 1, 100, True)
	$g_iRelayDebugLog = _IniReadInt("RelayDebugLog", 0, 0, 1)

	; v37: AutoIt's TCPAccept() and TCPRecv() do NOT return at once when
	; nothing is pending - they wait up to Opt("TCPTimeout") milliseconds
	; (AutoIt default: 100) for a connection or for data. Since this script
	; is single-threaded, every such wait stopped ALL other work: the
	; accept check (every AcceptCheckIntervalMs) cost about 100 ms each time,
	; and every connection that was waiting for its client added about
	; 100 ms to every pass of the main loop - for every other connection
	; too. Measured in the relay log: about 240 ms per SMTP command/answer
	; round trip, and a 5 MB upload that only moved 3 x 64 KB per 200 ms.
	; 0 = return at once (the loops that call these functions all sleep on
	; their own when idle, so this does not make the program spin).
	; The INI value is kept so the old behaviour (100) can be restored for a
	; comparison without a new version.
	$g_iTcpTimeoutMs = _IniReadInt("TcpTimeoutMs", 0, 0, 1000)
	; E3: log rotation - see _RotateLogFile() / _LogRotationTick()
	$g_iMaxLogSizeMB = _IniReadInt("MaxLogSizeMB", 10, 1, 1000, True)
	$g_iLogGenerations = _IniReadInt("LogGenerations", 5, 1, 99)
	Opt("TCPTimeout", $g_iTcpTimeoutMs)
EndFunc   ;==>_LoadGeneralSettings

; ============================================================================
; _IniReadInt
; ----------------------------------------------------------------------------
; Description : Reads a whole-number [General] INI setting and checks it
;               against an allowed range. A value that is not a whole
;               number, or lies outside the range, is replaced by the
;               default, and a warning is collected in $g_sSettingsWarnings
;               (written to the log right after the "started" line, since
;               the log may not exist yet while the settings are read).
;               Protects against values such as IdleWatchdogMs=0 (a log
;               line on every main-loop pass) or HttpTimeoutMs=0 (WinHTTP
;               treats 0 as "wait forever").
; Parameters  : $sKey          - Key name inside [General].
;               $iDefault      - Value used if the key is missing or invalid.
;               $iMin, $iMax   - Allowed range (inclusive).
;               $bZeroMeansOff - True if 0 is a valid "switched off" value
;               even though it lies below $iMin.
; Returns     : The value to use.
; ============================================================================
Func _IniReadInt($sKey, $iDefault, $iMin, $iMax, $bZeroMeansOff = False)
	Local $sRaw = StringStripWS(IniRead($g_sIniPath, "General", $sKey, String($iDefault)), 3)
	If Not StringRegExp($sRaw, "^-?[0-9]+$") Then
		$g_sSettingsWarnings &= "Warning: INI setting [General] " & $sKey & "=" & $sRaw & _
				" is not a whole number - using the default " & $iDefault & " instead." & @CRLF
		Return $iDefault
	EndIf
	Local $iVal = Number($sRaw)
	If $bZeroMeansOff And $iVal = 0 Then Return 0
	If $iVal < $iMin Or $iVal > $iMax Then
		Local $sRange = $iMin & "-" & $iMax
		If $bZeroMeansOff Then $sRange = "0 (off) or " & $sRange
		$g_sSettingsWarnings &= "Warning: INI setting [General] " & $sKey & "=" & $iVal & _
				" is outside the allowed range (" & $sRange & ") - using the default " & $iDefault & " instead." & @CRLF
		Return $iDefault
	EndIf
	Return $iVal
EndFunc   ;==>_IniReadInt

; ============================================================================
; _EnsureIniDefault
; ----------------------------------------------------------------------------
; Description : Writes a [General] INI key with its default value, but only
;               if the key does not exist yet. Used for settings that were
;               added after the INI file of an existing installation was
;               first created, so they show up in the file (ready to edit)
;               without waiting for the first clean program exit, when
;               _SaveGeneralSettings() would write them.
; Parameters  : $sKey     - Key name inside [General].
;               $sDefault - Default value to write if the key is missing.
; Returns     : (nothing)
; ============================================================================
Func _EnsureIniDefault($sKey, $sDefault)
	If IniRead($g_sIniPath, "General", $sKey, "##missing##") = "##missing##" Then IniWrite($g_sIniPath, "General", $sKey, $sDefault)
EndFunc   ;==>_EnsureIniDefault

; ============================================================================
; _SaveGeneralSettings
; ----------------------------------------------------------------------------
; Description : Single point where the [General] section of the INI file is
;               written. Persists the current value of every [General]
;               global variable back to disk. Counterpart to
;               _LoadGeneralSettings(); called by _Shutdown(). (The
;               "Advanced" dialog writes the keys it changes itself and then
;               reloads them with _LoadGeneralSettings() - see
;               _ShowAdvancedSettingsDialog().)
; Parameters  : (none)
; Returns     : (nothing - writes to the INI file as a side effect)
; ============================================================================
Func _SaveGeneralSettings()
	Local $sClearLog = "0"
	If $g_bClearLogOnStart Then $sClearLog = "1"
	IniWrite($g_sIniPath, "General", "ClearLogOnStart", $sClearLog)

	IniWrite($g_sIniPath, "General", "AuthPortStart", $g_iAuthPortStart)
	IniWrite($g_sIniPath, "General", "SmtpPortStart", $g_iSmtpPortStart)

	Local $sVerbose = "0"
	If $g_bUseLogSetting Then $sVerbose = "1"
	IniWrite($g_sIniPath, "General", "UseLogFile", $sVerbose)
	; Only persist LogLevel when compiled - see the matching comment in
	; _LoadGeneralSettings() for why: an uncompiled debug session's fixed
	; $g_iLogLevel=9 must never leak into the shared INI file and end up
	; silently changing a later compiled run's own, separately-intended
	; LogLevel setting.
	If @Compiled Then IniWrite($g_sIniPath, "General", "LogLevel", $g_iLogLevel)

	IniWrite($g_sIniPath, "General", "AcceptCheckIntervalMs", $g_iAcceptCheckIntervalMs)
	IniWrite($g_sIniPath, "General", "MainLoopTickMs", $g_iMainLoopTickMs)
	IniWrite($g_sIniPath, "General", "RelayPollMs", $g_iRelayPollMs)
	IniWrite($g_sIniPath, "General", "StallWatchdogMs", $g_iStallWatchdogMs)
	IniWrite($g_sIniPath, "General", "IdleWatchdogMs", $g_iIdleWatchdogMs)
	IniWrite($g_sIniPath, "General", "AuthRedirectTimeoutSec", $g_iAuthRedirectTimeoutSec)
	IniWrite($g_sIniPath, "General", "HttpTimeoutMs", $g_iHttpTimeoutMs)
	IniWrite($g_sIniPath, "General", "ProactiveRefreshLeadSec", $g_iProactiveRefreshLeadSec)
	IniWrite($g_sIniPath, "General", "LoopBlockWarnMs", $g_iLoopBlockWarnMs)
	IniWrite($g_sIniPath, "General", "PreAuthTimeoutMs", $g_iPreAuthTimeoutMs)
	IniWrite($g_sIniPath, "General", "IdleCloseMs", $g_iIdleCloseMs)
	IniWrite($g_sIniPath, "General", "MaxConnections", $g_iMaxConnections)
	IniWrite($g_sIniPath, "General", "RelayDebugLog", $g_iRelayDebugLog)
	IniWrite($g_sIniPath, "General", "TcpTimeoutMs", $g_iTcpTimeoutMs)
	IniWrite($g_sIniPath, "General", "MaxLogSizeMB", $g_iMaxLogSizeMB)
	IniWrite($g_sIniPath, "General", "LogGenerations", $g_iLogGenerations)
	IniWrite($g_sIniPath, "General", "AuthResultTimeoutMs", $g_iAuthResultTimeoutMs)
EndFunc   ;==>_SaveGeneralSettings

; ============================================================================
; _Shutdown
; ----------------------------------------------------------------------------
; Description : Performs an orderly shutdown: persists the current
;               in-memory [General] settings back to the INI file
;               (_SaveGeneralSettings() - the counterpart to
;               _LoadGeneralSettings() at startup; it also writes keys that
;               were missing from the INI with their current values),
;               closes every active client connection (and its upstream
;               helper process), closes every listening socket, releases
;               the tray icon bitmaps (DeleteAllhBitmaps() - Windows would
;               reclaim these anyway once the process exits, same as the
;               sockets below, but releasing what was explicitly created
;               keeps this function consistent with itself), shuts down
;               the TCP subsystem and writes a final line to the log
;               file. Called from the tray "Exit" menu item (after a
;               confirmation if connections are still active), right
;               before the process terminates.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _Shutdown()
	_SaveGeneralSettings()
	_NotifyEvent("stop", "", "The proxy was ended (Exit in the tray menu).") ; E1

	Local $aKeys = $g_oActiveConnections.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		_CloseConnection($g_oActiveConnections.Item($aKeys[$i]), "the program is shutting down")
	Next

	Local $aLKeys = $g_oListeners.Keys()
	For $i = 0 To UBound($aLKeys) - 1
		Local $oL = $g_oListeners.Item($aLKeys[$i])
		If $oL.Item("Socket") <> -1 Then TCPCloseSocket($oL.Item("Socket"))
	Next

	DeleteAllhBitmaps()

	TCPShutdown()
	; E1: give the notification processes still running (normally just
	; "Proxy stopped") a moment, so their result still reaches the log.
	_NotifyWaitAll(3000)
	LogFile($g_sAppName & " stopped.")
EndFunc   ;==>_Shutdown

; ============================================================================
; _GetScriptVersion
; ----------------------------------------------------------------------------
; Description : Returns this program's version for the log, the About dialog
;               and the tray menu title (cached after the first call). Compiled: the
;               .exe's FileVersion resource, which AutoIt3Wrapper sets from
;               the "#AutoIt3Wrapper_Res_Fileversion" directive. Uncompiled:
;               that directive is read directly from the script file itself
;               (there is no version resource in that case), marked with
;               "uncompiled".
; Parameters  : (none)
; Returns     : The version text, or "unknown" if it cannot be determined.
; ============================================================================
Func _GetScriptVersion()
	; Worked out once and then cached - it is also used for the tray menu title,
	; which is rebuilt often, and uncompiled it means reading the whole script.
	Local Static $sCached = ""
	If $sCached <> "" Then Return $sCached
	$sCached = __GetScriptVersionUncached()
	Return $sCached
EndFunc   ;==>_GetScriptVersion

; Internal helper of _GetScriptVersion(): the actual (uncached) lookup.
Func __GetScriptVersionUncached()
	If @Compiled Then
		Local $sFileVer = FileGetVersion(@ScriptFullPath)
		If $sFileVer = "" Then Return "unknown"
		Return $sFileVer
	EndIf
	Local $sSource = FileRead(@ScriptFullPath)
	If @error Then Return "unknown"
	Local $aMatch = StringRegExp($sSource, "(?im)^\s*#AutoIt3Wrapper_Res_Fileversion\s*=\s*([0-9.]+)\s*$", 1)
	If @error Then Return "unknown"
	Return $aMatch[0] & ", uncompiled"
EndFunc   ;==>__GetScriptVersionUncached

; ============================================================================
; _ShowAboutDialog
; ----------------------------------------------------------------------------
; Description : Shows a dedicated "About" GUI window (not _ProxyMsgBox() -
;               this one wants its own richer layout: icon, bold app name,
;               version, description, and a visually distinct credit
;               block, rather than one plain block of text): the script
;               name ($g_sAppName) in bold next to the program's own main
;               icon, its version (the compiled .exe's
;               embedded FileVersion resource - see the
;               #AutoIt3Wrapper_Res_Fileversion / _AutoIncrement
;               directives near the top of the script - or, when running
;               uncompiled, the version read from that directive and marked
;               "uncompiled" (both via _GetScriptVersion()), a short
;               description of what the tool does, and a fixed attribution/credit block in a
;               smaller, greyed-out font. Like every other dialog in this
;               script, its own message loop calls _ServiceConnections()
;               on every tick so the proxy keeps working while it is left
;               open - see _ServiceConnections()'s header comment. Opened
;               by clicking the tray menu's title item (program name and
;               version) - there is no separate "About" item since v61.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _ShowAboutDialog()
	Local $sVersion = _GetScriptVersion() ; H2: same version text as the "started" log line

	Local $hGui = GUICreate("About " & $g_sAppName, 460, 280)
	_SetDialogIcon($hGui)

	; The program's own main icon: it is not one of the extra
	; #AutoIt3Wrapper_Res_Icon_Add resources (it is the one set via
	; #AutoIt3Wrapper_Icon), so it is index 0 without any $iIconOffset
	; adjustment - the same as for the tray title item in
	; _RebuildTrayMenu() and in _SetDialogIcon(). Uncompiled, the .ico
	; file next to the script is used instead.
	If @Compiled Then
		GUICtrlCreateIcon(@ScriptFullPath, 0, 20, 20, 32, 32)
	Else
		GUICtrlCreateIcon(@ScriptDir & "\icons\default.ico", 0, 20, 20, 32, 32)
	EndIf

	Local $idName = GUICtrlCreateLabel($g_sAppName, 64, 18, 360, 24)
	GUICtrlSetFont($idName, 12, 700)

	Local $idVersion = GUICtrlCreateLabel("Version: " & $sVersion, 64, 44, 360, 18)
	GUICtrlSetColor($idVersion, 0x555555)

	GUICtrlCreateLabel( _
			"A local SMTP-to-OAuth2 proxy: lets legacy e-mail clients and devices that " & _
			"only support plain username/password SMTP authentication send mail through " & _
			"modern providers (Microsoft 365, Google Workspace, ...) that require OAuth2.", _
			20, 75, 420, 65)

	Local $idCredit = GUICtrlCreateLabel( _
			"Inspired by the ideas behind email-oauth2-proxy (c) Simon Robinson -" & @CRLF & _
			"https://github.com/simonrob/email-oauth2-proxy - the code itself is entirely new." & @CRLF & _
			"by Markus Debus 2026  -  Licensed under the Apache License, Version 2.0", _
			20, 150, 420, 60)
	GUICtrlSetFont($idCredit, 8)
	GUICtrlSetColor($idCredit, 0x808080)

	Local $idOk = GUICtrlCreateButton("OK", 180, 225, 100, 30)
	GUICtrlSetTip($idOk, "Close this window.")

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	While 1
		Local $nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE, $idOk
				GUIDelete($hGui)
				_DialogClosed()
				Return
		EndSwitch

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowAboutDialog

; ############################################################################
; #  LOADING CONFIGURATION / MANAGING LISTENERS
; ############################################################################

; ============================================================================
; _LoadAllListeners
; ----------------------------------------------------------------------------
; Description : (Re-)loads the entire configuration from the INI file into
;               memory: iterates every "SMTP-<port>" section, reads its
;               associated "Account:<email>" section (decrypting the client
;               secret and the local SMTP password via DPAPI), and rebuilds
;               $g_oAccountsByEmail and $g_oListeners from scratch. Safe to
;               call again later (e.g. after adding an account) to refresh
;               the in-memory configuration from disk.
;               Two things are deliberately carried over from the PREVIOUS
;               in-memory state rather than being rebuilt/reset, so that
;               calling this again (e.g. right after adding one new
;               account) does not disturb anything already working:
;                 - A listener whose section still has the exact same
;                   LocalAddress/LocalPort/ServerAddress/ServerPort/
;                   ServerSTARTTLS/Active as before keeps its already-open
;                   socket (via _StartAllListeners(), which then skips it)
;                   instead of being closed here and reopened moments
;                   later - only listeners that are new, removed, or
;                   actually changed (including an Active flip) are touched.
;                 - An account whose e-mail already existed before keeps
;                   its in-memory cached AccessToken/AccessTokenExpiry/
;                   RefreshToken instead of having them reset to blank
;                   (they would otherwise just be lazily re-decrypted from
;                   the INI on next use anyway via
;                   _Auth_GetValidAccessToken(), so this is a minor
;                   efficiency improvement rather than a correctness fix).
; Parameters  : (none)
; Returns     : (nothing - populates the global $g_oListeners /
;               $g_oAccountsByEmail dictionaries as a side effect)
; ============================================================================
Func _LoadAllListeners()
	Local $oOldListeners = $g_oListeners
	Local $oOldAccounts = $g_oAccountsByEmail
	$g_oListeners = ObjCreate("Scripting.Dictionary")
	$g_oAccountsByEmail = ObjCreate("Scripting.Dictionary")

	If Not FileExists($g_sIniPath) Then
		_CloseStaleListeners($oOldListeners, $g_oListeners)
		Return
	EndIf

	Local $aSections = IniReadSectionNames($g_sIniPath)
	If @error Then
		_CloseStaleListeners($oOldListeners, $g_oListeners)
		Return
	EndIf

	Local $i = 0
	For $i = 1 To $aSections[0]
		Local $sSection = $aSections[$i]
		If StringLeft($sSection, 5) = "SMTP-" Then
			Local $sEmail = IniRead($g_sIniPath, $sSection, "Account", "")
			If $sEmail = "" Then ContinueLoop
			Local $sAccSection = "Account:" & $sEmail

			Local $oAcc = ObjCreate("Scripting.Dictionary")
			$oAcc.Item("Username") = $sEmail
			$oAcc.Item("Provider") = IniRead($g_sIniPath, $sAccSection, "Provider", "custom")
			$oAcc.Item("PermissionURL") = IniRead($g_sIniPath, $sAccSection, "PermissionURL", "")
			$oAcc.Item("TokenURL") = IniRead($g_sIniPath, $sAccSection, "TokenURL", "")
			$oAcc.Item("Scope") = IniRead($g_sIniPath, $sAccSection, "Scope", "")
			; Purely informational (last redirect URI used for a successful
			; sign-in, see _RunInteractiveAuth) - never read back
			; authoritatively, since a fresh local port is picked on every
			; sign-in attempt.
			$oAcc.Item("RedirectURI") = IniRead($g_sIniPath, $sAccSection, "RedirectURI", "")
			$oAcc.Item("ClientID") = IniRead($g_sIniPath, $sAccSection, "ClientID", "")
			$oAcc.Item("TenantID") = IniRead($g_sIniPath, $sAccSection, "TenantID", "")

			Local $sSecretEnc = IniRead($g_sIniPath, $sAccSection, "ClientSecretEnc", "")
			Local $sSecret = ""
			If $sSecretEnc <> "" Then $sSecret = _DPAPI_Unprotect($sSecretEnc, "client secret of " & $sEmail)
			$oAcc.Item("ClientSecret") = $sSecret

			; Local password the SMTP client on 127.0.0.1 must present (AUTH
			; PLAIN/LOGIN) before this proxy will forward anything upstream -
			; see _CheckLocalCredentials(). Empty means "not configured yet",
			; which _CheckLocalCredentials() treats as "reject every local
			; login" rather than silently skipping the check.
			Local $sLocalPasswordEnc = IniRead($g_sIniPath, $sAccSection, "LocalPasswordEnc", "")
			Local $sLocalPassword = ""
			If $sLocalPasswordEnc <> "" Then $sLocalPassword = _DPAPI_Unprotect($sLocalPasswordEnc, "local SMTP password of " & $sEmail)
			$oAcc.Item("LocalPassword") = $sLocalPassword

			$oAcc.Item("UsePKCE") = IniRead($g_sIniPath, $sAccSection, "UsePKCE", "0")
			$oAcc.Item("IniSection") = $sAccSection
			$oAcc.Item("AccessToken") = ""
			$oAcc.Item("AccessTokenExpiry") = Number(IniRead($g_sIniPath, $sAccSection, "AccessTokenExpiry", "0"))
			$oAcc.Item("RefreshToken") = ""
			$oAcc.Item("NeedsReauth") = (IniRead($g_sIniPath, $sAccSection, "RefreshTokenEnc", "") = "")

			; Carry over cached tokens from the previous in-memory state for
			; an account that already existed (see header comment above).
			If $oOldAccounts.Exists($sEmail) Then
				Local $oPrevAcc = $oOldAccounts.Item($sEmail)
				$oAcc.Item("AccessToken") = $oPrevAcc.Item("AccessToken")
				$oAcc.Item("RefreshToken") = $oPrevAcc.Item("RefreshToken")
			EndIf

			$g_oAccountsByEmail.Item($sEmail) = $oAcc

			Local $oListener = ObjCreate("Scripting.Dictionary")
			$oListener.Item("LocalAddress") = IniRead($g_sIniPath, $sSection, "LocalAddress", "127.0.0.1")
			$oListener.Item("LocalPort") = Number(IniRead($g_sIniPath, $sSection, "LocalPort", "0"))
			$oListener.Item("ServerAddress") = IniRead($g_sIniPath, $sSection, "ServerAddress", "")
			$oListener.Item("ServerPort") = Number(IniRead($g_sIniPath, $sSection, "ServerPort", "587"))
			$oListener.Item("ServerSTARTTLS") = IniRead($g_sIniPath, $sSection, "ServerSTARTTLS", "1")
			; Whether this listener should actually accept connections - see
			; the "Enable/Disable" action in _ShowSettingsDialog() and
			; _SetListenerActive(). Defaults to enabled ("1") so listeners
			; configured before this setting existed keep working unchanged.
			$oListener.Item("Active") = (Number(IniRead($g_sIniPath, $sSection, "Active", "1")) = 1)
			$oListener.Item("Account") = $oAcc
			$oListener.Item("Socket") = -1

			; Reuse the already-open socket if this listener's configuration
			; is byte-for-byte unchanged from before (see header comment).
			If $oOldListeners.Exists($sSection) Then
				Local $oPrevL = $oOldListeners.Item($sSection)
				If $oPrevL.Item("Socket") <> -1 And _
						$oPrevL.Item("LocalAddress") = $oListener.Item("LocalAddress") And _
						Number($oPrevL.Item("LocalPort")) = $oListener.Item("LocalPort") And _
						$oPrevL.Item("ServerAddress") = $oListener.Item("ServerAddress") And _
						Number($oPrevL.Item("ServerPort")) = $oListener.Item("ServerPort") And _
						Number($oPrevL.Item("ServerSTARTTLS")) = Number($oListener.Item("ServerSTARTTLS")) And _
						$oPrevL.Item("Active") = $oListener.Item("Active") Then
					$oListener.Item("Socket") = $oPrevL.Item("Socket")
					$oOldListeners.Remove($sSection) ; so the cleanup pass below leaves this socket open
				EndIf
			EndIf

			$g_oListeners.Item($sSection) = $oListener
		EndIf
	Next

	; Close whatever old listener sockets were NOT reused above (removed
	; from the config, changed enough to need a fresh socket, or just
	; switched to Active=False).
	_CloseStaleListeners($oOldListeners, $g_oListeners)
EndFunc   ;==>_LoadAllListeners

; ============================================================================
; _CloseStaleListeners
; ----------------------------------------------------------------------------
; Description : Closes the socket of every listener in $oOldListeners that
;               is no longer present in $oNewListeners (i.e. was not
;               reused by _LoadAllListeners()). Small helper factored out
;               so _LoadAllListeners() can call it from each of its early
;               "nothing to load" return paths as well as its normal exit.
; Parameters  : $oOldListeners - Dictionary of listeners from before this
;               reload (entries already reused have been removed from it).
;               $oNewListeners - The freshly (re)built $g_oListeners.
; Returns     : (nothing - closes sockets as a side effect)
; ============================================================================
Func _CloseStaleListeners($oOldListeners, $oNewListeners)
	Local $aOldKeys = $oOldListeners.Keys()
	Local $i = 0
	For $i = 0 To UBound($aOldKeys) - 1
		Local $oOld = $oOldListeners.Item($aOldKeys[$i])
		If $oOld.Item("Socket") <> -1 Then TCPCloseSocket($oOld.Item("Socket"))
	Next
EndFunc   ;==>_CloseStaleListeners

; ============================================================================
; _StartAllListeners
; ----------------------------------------------------------------------------
; Description : Opens a TCP listening socket for every listener currently
;               held in $g_oListeners (as populated by _LoadAllListeners())
;               that is Active and does not already have one
;               (_LoadAllListeners() may have carried an existing socket
;               over for a listener whose configuration did not change -
;               see its header comment). A listener with Active=False (see
;               "Enable/Disable" in _ShowSettingsDialog()) is skipped
;               entirely and logged as disabled rather than as an error.
;               A bind that fails is retried a few times with a short
;               pause first (see the retry loop's own comment for why -
;               in short, a just-changed LocalAddress/LocalPort can hit a
;               brief, transient conflict with the old socket
;               _CloseStaleListeners() only just closed). Logs a warning
;               if a port is still in use after every retry, otherwise
;               stores the socket handle back into the listener's
;               dictionary and logs a confirmation line.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _StartAllListeners()
	Local $aKeys = $g_oListeners.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		Local $sKey = $aKeys[$i]
		Local $oL = $g_oListeners.Item($sKey)
		If $oL.Item("Socket") <> -1 Then ContinueLoop ; carried over unchanged from before, already open
		If Not $oL.Item("Active") Then
			LogFile("SMTP listener " & $sKey & " is disabled - not starting.")
			ContinueLoop
		EndIf

		; A listener whose LocalAddress/LocalPort just changed (see
		; _LoadAllListeners()) had its old socket closed moments ago by
		; _CloseStaleListeners(), immediately before this runs - Windows
		; does not always release a just-closed listening socket's port
		; instantly, especially when the new bind is to a different
		; address on the same port (e.g. switching to the 0.0.0.0
		; wildcard, which can briefly conflict with any not-yet-fully-
		; released specific-address binding on that port). A few short
		; retries covers this transient timing gap without giving up
		; immediately on what is usually not a real conflict.
		Local $iSock = -1
		Local $iAttempt = 0
		For $iAttempt = 1 To 5
			$iSock = TCPListen($oL.Item("LocalAddress"), $oL.Item("LocalPort"), 10)
			If $iSock <> -1 Then ExitLoop
			Sleep(100)
		Next

		If $iSock = -1 Then
			LogFile("Error: SMTP listener " & $sKey & " could not open port " & $oL.Item("LocalPort") & " (already in use?).")
		Else
			$oL.Item("Socket") = $iSock
			LogFile("SMTP listener started: " & $sKey & " (" & $oL.Item("LocalAddress") & ":" & $oL.Item("LocalPort") & _
					" -> " & $oL.Item("ServerAddress") & ":" & $oL.Item("ServerPort") & _
					") for " & $oL.Item("Account").Item("Username"))
		EndIf
	Next
EndFunc   ;==>_StartAllListeners

; ============================================================================
; _AcceptNewConnections
; ----------------------------------------------------------------------------
; Description : Called once per main-loop iteration. Performs a
;               TCPAccept() on every listener's socket (non-blocking since
;               v37 - TcpTimeoutMs = 0, see _LoadGeneralSettings()); for
;               each newly accepted client connection it creates a fresh
;               connection-state dictionary (initial state = greeting),
;               immediately starts a dedicated upstream PowerShell/TLS
;               helper process for that connection (see _Upstream_Start),
;               and registers the connection in $g_oActiveConnections
;               keyed by its client socket handle.
;               If MaxConnections (default 5) connections are already active,
;               a new one is refused at once with "421 too many connections"
;               - before any helper process is started - and logged at most
;               every 10 seconds. Each accepted connection also gets the
;               client's IP address and port (_GetPeerAddress()) and the
;               fields used for the summary in the "Connection closed" log
;               line (see _ConnectionSummary()).
; Parameters  : (none)
; Returns     : (nothing - populates $g_oActiveConnections as a side effect)
; ============================================================================
Func _AcceptNewConnections()
	Local $aKeys = $g_oListeners.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		Local $oL = $g_oListeners.Item($aKeys[$i])
		If $oL.Item("Socket") = -1 Then ContinueLoop

		Local $iClientSock = TCPAccept($oL.Item("Socket"))
		If $iClientSock <> -1 Then
		; D1: connection limit - refused BEFORE a helper process is started,
		; so a flood of connections (scanner, faulty device) costs almost nothing.
		If $g_iMaxConnections > 0 And $g_oActiveConnections.Count >= $g_iMaxConnections Then
			TCPSend($iClientSock, StringToBinary("421 4.7.0 " & $g_sAppName & ": too many connections, please try again later" & @CRLF, 1))
			Local $sRefusedPeer = _GetPeerAddress($iClientSock)
			TCPCloseSocket($iClientSock)
			$g_iRejectedSinceLog += 1
			If $g_hLastRejectLog = 0 Or TimerDiff($g_hLastRejectLog) > 10000 Then
				LogFile("Warning: connection from " & $sRefusedPeer & " on " & $aKeys[$i] & " refused - the limit of " & $g_iMaxConnections & _
						" simultaneous connections (MaxConnections) is reached. Refused since the last such line: " & $g_iRejectedSinceLog & ".")
				_StatsNoteError("connection limit reached")
				$g_hLastRejectLog = TimerInit()
				$g_iRejectedSinceLog = 0
			EndIf
			ContinueLoop
		EndIf

			Local $oConn = ObjCreate("Scripting.Dictionary")
			$oConn.Item("ClientSocket") = $iClientSock
			$oConn.Item("Account") = $oL.Item("Account")
			$oConn.Item("State") = $STATE_GREETING
			$oConn.Item("RecvBufClient") = ""
			$oConn.Item("RecvBufServer") = ""
			$oConn.Item("EhloCommand") = ""
			$oConn.Item("EhloAccum") = ""
			; Timestamp this connection was accepted, plus whether the
			; stall watchdog below has already logged about it once - see
			; the watchdog check near the top of _PumpConnection().
			$oConn.Item("AcceptedAt") = TimerInit()
			$oConn.Item("StallWarned") = False
			; Idle watchdog (post-authentication) - see its own check
			; further down in _PumpConnection(). Reset on any activity in
			; either direction (and by the watchdog check itself, to
			; re-arm for the next interval of continued silence).
			$oConn.Item("LastActivity") = TimerInit()
			; Holds the (decoded) username between the "Username:" and
			; "Password:" turns of an AUTH LOGIN exchange - see
			; _OnClientLine()/_CheckLocalCredentials(). Cleared again right
			; after use.
			$oConn.Item("PendingAuthUser") = ""

			; Sniffing state for logging what gets sent once authenticated
			; (see _SniffClientData()) - separate from the actual raw
			; pass-through relay, which is unaffected by any of this.
			$oConn.Item("SniffBuf") = ""
			$oConn.Item("SniffActive") = True
			$oConn.Item("SniffInData") = False
			$oConn.Item("SniffMailFrom") = ""
			$oConn.Item("SniffRcptTo") = ""
			$oConn.Item("SniffSubject") = ""
			$oConn.Item("SniffHeaderBytes") = 0
			; Once True, _SniffClientData() skips the expensive line-based
			; _ExtractLines() scan entirely for the rest of the current
			; message - see that function's own header comment for why
			; this exists at all.
			$oConn.Item("SniffFastMode") = False
			; DATA-phase timing (level 8 - see _SniffClientData()/
			; _SniffServerData()): how long the client itself takes to
			; send a message, separately from how long the real server
			; then takes to acknowledge it afterward.
			; Diagnostics for the one-line summary written when this connection is
			; closed (see _ConnectionSummary()): who connected, which commands the
			; client sent, the last reply of the real server, and when the greeting,
			; the EHLO answer and the login were completed (-1 = not reached).
			$oConn.Item("PeerAddr") = _GetPeerAddress($iClientSock)
			$oConn.Item("CmdTrail") = ""
			$oConn.Item("LastServerLine") = ""
			$oConn.Item("SniffLastCmd") = ""
			$oConn.Item("SniffLastMail") = ""
			$oConn.Item("LastDataAt") = TimerInit()
			$oConn.Item("T_Greeting") = -1
			$oConn.Item("T_Ehlo") = -1
			$oConn.Item("T_Auth") = -1
			; A1: set once the connection to the mail server has been switched to TLS
			; (STARTTLS done), so a later EHLO from the client does not trigger a
			; second STARTTLS. A2: remembers whether the client greeted with HELO.
			$oConn.Item("UpstreamTlsActive") = False
			$oConn.Item("ClientUsedHelo") = False
			$oConn.Item("StderrTail") = "" ; F3: last error output of the helper process, see _CollectHelperStderr()
			$oConn.Item("SniffDataStartedAt") = 0
			$oConn.Item("SniffClientSendDoneAt") = 0
			$oConn.Item("SniffAwaitingDataAck") = False
			$oConn.Item("SniffServerBuf") = ""
			$oConn.Item("SniffData354Seen") = False ; N1: the server has answered DATA with 354 (see _SniffServerData())
			$oConn.Item("AuthUpstreamAt") = 0 ; O1/O2: timer - when "AUTH XOAUTH2" was sent to the real server (0 = not yet)
			; J1: message content after DATA - bytes counted and time of the last
			; chunk, so the "Connection closed" line can say plainly when a client
			; stopped in the middle of a message (see _ConnectionSummary()).
			$oConn.Item("SniffDataBytes") = 0
			$oConn.Item("SniffDataLastTimer") = 0

			; ServerSTARTTLS and "ImplicitTls" (see _Upstream_Start()'s own
			; parameter) are deliberately inverted from one another: TLS
			; either starts immediately as the very first bytes on the wire
			; ("implicit TLS", e.g. port 465) or the connection begins in
			; plain text and is explicitly upgraded via STARTTLS partway
			; through (e.g. port 587) - exactly one of the two applies, so
			; ServerSTARTTLS=0 (STARTTLS not in use) is exactly when
			; implicit TLS is needed instead, and vice versa.
			Local $bImplicit = (Number($oL.Item("ServerSTARTTLS")) = 0)
			$oConn.Item("NeedsUpstreamStartTls") = Not $bImplicit
			Local $iPID = _Upstream_Start($oL.Item("ServerAddress"), $oL.Item("ServerPort"), $bImplicit)
			$oConn.Item("UpstreamPID") = $iPID
			_HelperLogRegister($iPID, "socket " & $iClientSock & " | " & $oConn.Item("PeerAddr")) ; M1

			$g_oActiveConnections.Item(String($iClientSock)) = $oConn
			LogFile("New connection on " & $aKeys[$i] & " (socket " & $iClientSock & ", upstream helper PID=" & $iPID & _
					") - " & $g_oActiveConnections.Count & " connection(s) now active in total. Client: " & $oConn.Item("PeerAddr") & ".")
		EndIf
	Next
EndFunc   ;==>_AcceptNewConnections

; ============================================================================
; _CloseConnection
; ----------------------------------------------------------------------------
; Description : Tears down one proxy connection: closes the client TCP
;               socket, terminates its dedicated upstream helper process
;               (if still running), and removes the connection from
;               $g_oActiveConnections.
; Parameters  : $oConn - Connection dictionary, as created in
;               _AcceptNewConnections() (must contain "ClientSocket" and
;               "UpstreamPID").
;               $sReason - Optional short text saying WHY the connection is
;               being closed; it is appended to the "Connection closed"
;               log line together with a summary (see
;               _ConnectionSummary()).
; Returns     : (nothing)
; ============================================================================
Func _CloseConnection($oConn, $sReason = "")
	Local $iSock = $oConn.Item("ClientSocket")
	Local $bSockClosed = TCPCloseSocket($iSock)

	Local $iPID = $oConn.Item("UpstreamPID")
	Local $bWasRunning = ProcessExists($iPID)
	_CollectHelperStderr($oConn) ; M1: last log lines / error output before the helper is ended
	; Ends the helper if it is still running AND releases the pipe handles
	; AutoIt holds for it (see _Upstream_Kill()).
	_Upstream_Kill($iPID)

	If $g_oActiveConnections.Exists(String($iSock)) Then $g_oActiveConnections.Remove(String($iSock))

	; Logged with the same level of detail as _AcceptNewConnections()'s
	; "New connection" line (including TCPCloseSocket()'s own success/
	; failure and whether the upstream helper process actually was still
	; running at this point) specifically so the two can be compared
	; against each other in the log file - a growing gap between "New
	; connection" and "Connection closed" counts over time would show up
	; clearly here if connections were ever failing to close properly. The
	; text after the first sentence (reason, client, lifetime, timeline,
	; client commands, last server reply) explains what happened on it.
	LogFile("Connection closed (socket=" & $iSock & ", TCPCloseSocket succeeded=" & $bSockClosed & _
			", upstream helper PID=" & $iPID & ", was still running=" & $bWasRunning & _
			") - " & $g_oActiveConnections.Count & " connection(s) still active." & _ConnectionSummary($oConn, $sReason))
EndFunc   ;==>_CloseConnection

; ============================================================================
; _CloseConnectionsForAccount
; ----------------------------------------------------------------------------
; Description : Forcibly closes every currently active connection that
;               belongs to a given account (matched via
;               $oConn.Item("Account").Item("Username")), via
;               _CloseConnection() for each - used by "Disable" and
;               "Delete" in _ShowSettingsDialog() so a mail transfer that
;               is mid-flight through a listener the admin just disabled
;               or removed does not keep running to completion
;               unsupervised. Snapshots the key list first (via Keys())
;               since _CloseConnection() mutates $g_oActiveConnections
;               while this loop is iterating it - the same safe pattern
;               already used in _Main()'s main loop and in _Shutdown().
; Parameters  : $sEmail - Account e-mail address whose connections should
;               be closed.
; Returns     : The number of connections that were closed.
; ============================================================================
Func _CloseConnectionsForAccount($sEmail)
	Local $aKeys = $g_oActiveConnections.Keys()
	Local $i = 0
	Local $iClosed = 0
	For $i = 0 To UBound($aKeys) - 1
		If $g_oActiveConnections.Exists($aKeys[$i]) Then
			Local $oConn = $g_oActiveConnections.Item($aKeys[$i])
			If $oConn.Item("Account").Item("Username") = $sEmail Then
				_CloseConnection($oConn, "the account was disabled or deleted in Settings")
				$iClosed += 1
			EndIf
		EndIf
	Next
	If $iClosed > 0 Then LogFile("Forcibly closed " & $iClosed & " active connection(s) for " & $sEmail & ".")
	Return $iClosed
EndFunc   ;==>_CloseConnectionsForAccount

; ============================================================================
; _StatsRollDay / _StatsCountRelayed / _StatsCountRejected / _StatsNoteError
; ----------------------------------------------------------------------------
; Description : Small counters for the tray tooltip (see _UpdateTrayTooltip()):
;               e-mails relayed today, e-mails the mail server refused today,
;               and the most recent error with its time (and date, when it
;               was not today - see _UpdateTrayTooltip()). The day counters
;               start again at 0 after midnight. On the day the proxy was
;               started they only cover the time since the start, so the
;               tooltip label is "Since HH:MM" then and "Today" afterwards.
;               _StatsRollDay() starts a new day's counters after midnight
;               (called by the others and by _UpdateTrayTooltip()).
; Parameters  : $sText - (_StatsNoteError only) short description of the error.
; Returns     : (nothing)
; ============================================================================
Func _StatsRollDay()
	Local $sToday = @YEAR & @MON & @MDAY
	If $g_sStatsDay <> $sToday Then
		; On the day the proxy was started the counters do not cover the whole
		; day (anything sent before the start is not counted), so the tooltip
		; says "Since HH:MM" then; after the first midnight it says "Today".
		; The first call happens right after the start (_UpdateTrayTooltip()).
		If $g_sStatsDay = "" Then
			$g_sStatsLabel = "Since " & @HOUR & ":" & @MIN
		Else
			$g_sStatsLabel = "Today"
		EndIf
		$g_sStatsDay = $sToday
		$g_iStatsRelayedToday = 0
		$g_iStatsRejectedToday = 0
		; Show the reset counters (and an error from yesterday with its date)
		; right away - before v56 the tooltip kept yesterday's figures after
		; midnight until something else changed.
		$g_bTooltipDirty = True
	EndIf
EndFunc   ;==>_StatsRollDay

Func _StatsCountRelayed()
	_StatsRollDay()
	$g_iStatsRelayedToday += 1
	$g_bTooltipDirty = True
EndFunc   ;==>_StatsCountRelayed

Func _StatsCountRejected()
	_StatsRollDay()
	$g_iStatsRejectedToday += 1
	$g_bTooltipDirty = True
EndFunc   ;==>_StatsCountRejected

Func _StatsNoteError($sText)
	$g_sStatsLastError = $sText
	$g_sStatsLastErrorDay = @YEAR & @MON & @MDAY
	$g_sStatsLastErrorTime = @HOUR & ":" & @MIN
	$g_bTooltipDirty = True
EndFunc   ;==>_StatsNoteError

; ============================================================================
; _UpdateTrayTooltip
; ----------------------------------------------------------------------------
; Description : E8: shows a short status in the tray icon's tooltip - e-mails
;               relayed/refused today ("Since HH:MM" on the start day - see
;               _StatsRollDay()), active connections and the last error.
;               Called from _ServiceConnections(); only does real work at
;               most once every 2 seconds, and only if something changed.
;               Windows limits a tray tooltip to 127 characters, so the text
;               is kept short and the error is truncated.
;               The last error shows only its time ("14:23") if it happened
;               today, otherwise its full date in the same form as the log
;               ("2026-10-12 14:23"), so it can be found in the log by
;               searching for that text.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _UpdateTrayTooltip()
	If TimerDiff($g_hLastTooltipUpdate) < 2000 Then Return
	$g_hLastTooltipUpdate = TimerInit()
	_StatsRollDay()
	If $g_oActiveConnections.Count <> $g_iTooltipLastConnCount Then $g_bTooltipDirty = True
	If Not $g_bTooltipDirty Then Return
	$g_bTooltipDirty = False
	$g_iTooltipLastConnCount = $g_oActiveConnections.Count

	Local $sTip = $g_sAppName & @CRLF & $g_sStatsLabel & ": " & $g_iStatsRelayedToday & " sent"
	If $g_iStatsRejectedToday > 0 Then $sTip &= ", " & $g_iStatsRejectedToday & " refused"
	$sTip &= @CRLF & "Active connections: " & $g_oActiveConnections.Count
	If $g_sStatsLastError <> "" Then
		Local $sErrWhen = $g_sStatsLastErrorTime
		If $g_sStatsLastErrorDay <> @YEAR & @MON & @MDAY Then $sErrWhen = StringLeft($g_sStatsLastErrorDay, 4) & "-" & _
				StringMid($g_sStatsLastErrorDay, 5, 2) & "-" & StringRight($g_sStatsLastErrorDay, 2) & " " & $sErrWhen
		Local $sErr = "Last error: " & $sErrWhen & " " & $g_sStatsLastError
		Local $iRoom = 127 - StringLen($sTip) - 2
		If StringLen($sErr) > $iRoom Then $sErr = StringLeft($sErr, $iRoom - 3) & "..."
		$sTip &= @CRLF & $sErr
	EndIf
	TraySetToolTip($sTip)
EndFunc   ;==>_UpdateTrayTooltip

; ============================================================================
; _RunConnectionTest
; ----------------------------------------------------------------------------
; Description : E9: "Test Connection" in Account Settings - checks the whole chain for
;               one account WITHOUT sending an e-mail: helper process,
;               connection and TLS to the mail server, access token, and the
;               XOAUTH2 sign-in. Uses _SendTestEmail() with $bLoginOnly, so it
;               runs exactly the same steps as a real test e-mail up to the
;               sign-in. Shows the result (with duration) and logs it.
;               V1 (v75): the test takes a few seconds (helper start, TLS,
;               token, sign-in), and up to v74 the window showed no sign of
;               it - easily taken for a click that did not register. Now,
;               for the duration of the test, the button reads
;               "Testing ..." and the Account Settings window shows the
;               wait cursor; both are restored before the result appears.
;               (The former Windows notification "Testing the connection
;               ..." was dropped: on Windows 10/11 it often appeared late
;               or stayed in the notification centre after the result.)
; Parameters  : $sEmail   - Account to test.
;               $hParent  - Account Settings window (disabled while the test runs).
;               $idButton - Control ID of the "Test Connection" button (0 =
;                           no button feedback).
; Returns     : (nothing)
; ============================================================================
Func _RunConnectionTest($sEmail, $hParent, $idButton = 0)
	Local $oAcc = $g_oAccountsByEmail.Item($sEmail)
	Local $oListener = _FindListenerForAccount($sEmail)
	If Not IsObj($oListener) Then
		_ProxyMsgBox(16, "Error", "No matching listener was found for this account.", $hParent)
		Return
	EndIf

	; V1: visible "busy" state BEFORE the blocking test starts
	Local $sButtonText = ""
	If $idButton Then
		$sButtonText = GUICtrlRead($idButton)
		GUICtrlSetData($idButton, "Testing ...")
	EndIf
	GUISetCursor(15, 1, $hParent) ; 15 = wait cursor, 1 = for the whole window
	GUISetState(@SW_DISABLE, $hParent)
	Local $hTimer = TimerInit()
	Local $sResult = _SendTestEmail($oAcc, $oListener, "", False, 0, True)
	Local $bFailed = @error
	Local $sDuration = _FormatDurationMs(Round(TimerDiff($hTimer)))
	GUISetState(@SW_ENABLE, $hParent)
	GUISetCursor(2, 0, $hParent) ; 2 = normal arrow again
	If $idButton Then GUICtrlSetData($idButton, $sButtonText)
	WinActivate($hParent)

	If $bFailed Then
		LogFile("Connection test for " & $sEmail & " failed after " & $sDuration & ": " & StringReplace($sResult, @CRLF, " "))
		_StatsNoteError("connection test " & $sEmail & " failed")
		_ProxyMsgBox(16, "Connection test failed", "The connection test for " & $sEmail & " failed after " & $sDuration & ":" & _
				@CRLF & @CRLF & $sResult, $hParent)
	Else
		LogFile("Connection test for " & $sEmail & " succeeded in " & $sDuration & " (connection, TLS and sign-in at the mail server).")
		_ProxyMsgBox(64, "Connection test successful", "Connection, encryption and sign-in for " & $sEmail & _
				" work (" & $sDuration & ")." & @CRLF & @CRLF & "No e-mail was sent.", $hParent)
	EndIf
EndFunc   ;==>_RunConnectionTest

; ############################################################################
; #  DIAGNOSTICS AND SAFETY NETS
; ############################################################################
; Added to make a "client connects, but nothing happens" situation
; analysable from the log file alone, and to keep one hopeless connection
; from living forever. Everything here only OBSERVES (log lines, counters)
; or closes a connection that is already stuck - none of it changes how a
; healthy connection is relayed.

; ============================================================================
; _Upstream_Kill
; ----------------------------------------------------------------------------
; Description : Ends an upstream helper process (if it is still running) AND
;               releases the stdin/stdout/stderr pipe handles AutoIt keeps
;               open for a process started with Run() and STDIO
;               redirection. ProcessClose() alone leaves those handles
;               open: in the log of earlier versions the client socket
;               numbers (which are process handle values) crept up by about
;               6 per connection - a small but steady handle leak.
; Parameters  : $iPID - PID returned by _Upstream_Start() (0 is ignored).
; Returns     : (nothing)
; ============================================================================
Func _Upstream_Kill($iPID)
	If Not $iPID Then Return
	If ProcessExists($iPID) Then ProcessClose($iPID)
	_HelperStderrDrain($iPID) ; M1/N2: whatever is still in the pipe goes into the log
	StdioClose($iPID)
	_HelperLogForget($iPID)
EndFunc   ;==>_Upstream_Kill

; ============================================================================
; _GetPeerAddress
; ----------------------------------------------------------------------------
; Description : Returns "a.b.c.d:port" of the remote end of an accepted
;               (IPv4) client socket, via ws2_32 getpeername(). Used for the
;               log, so it is visible WHICH device or program connected.
; Parameters  : $iSocket - Socket returned by TCPAccept().
; Returns     : The address as text, or "unknown" if it could not be read.
; ============================================================================
Func _GetPeerAddress($iSocket)
	Local $tAddr = DllStructCreate("ushort Family;ushort Port;byte Addr[4];byte Zero[8]")
	Local $aRet = DllCall("ws2_32.dll", "int", "getpeername", "uint_ptr", $iSocket, "struct*", $tAddr, "int*", DllStructGetSize($tAddr))
	If @error Or Not IsArray($aRet) Then Return "unknown"
	If $aRet[0] <> 0 Then Return "unknown"
	Local $iPortNet = DllStructGetData($tAddr, "Port")
	Local $iPort = BitOR(BitShift(BitAND($iPortNet, 0xFF), -8), BitShift($iPortNet, 8))
	Return DllStructGetData($tAddr, "Addr", 1) & "." & DllStructGetData($tAddr, "Addr", 2) & "." & _
			DllStructGetData($tAddr, "Addr", 3) & "." & DllStructGetData($tAddr, "Addr", 4) & ":" & $iPort
EndFunc   ;==>_GetPeerAddress

; ============================================================================
; _StateName
; ----------------------------------------------------------------------------
; Description : Human-readable name of a connection state ($STATE_*), for log
;               lines.
; Parameters  : $iState - One of the $STATE_* constants.
; Returns     : A short description.
; ============================================================================
Func _StateName($iState)
	Switch $iState
		Case $STATE_GREETING
			Return "waiting for the server greeting"
		Case $STATE_EHLO_WAIT
			Return "waiting for the server's EHLO answer"
		Case $STATE_STARTTLS_WAIT
			Return "waiting for the server's STARTTLS answer"
		Case $STATE_EHLO_WAIT_POST_TLS
			Return "waiting for the EHLO answer after STARTTLS"
		Case $STATE_READY
			Return "ready for the client's login"
		Case $STATE_AUTH_PLAIN_WAIT_CREDS, $STATE_AUTH_LOGIN_WAIT_USER, $STATE_AUTH_LOGIN_WAIT_PASS
			Return "waiting for the client's login data"
		Case $STATE_XOAUTH2_WAIT_334
			Return "waiting for the server's XOAUTH2 prompt"
		Case $STATE_XOAUTH2_WAIT_RESULT
			Return "waiting for the server's XOAUTH2 result"
		Case $STATE_AUTHENTICATED
			Return "signed in"
	EndSwitch
	Return "state " & $iState
EndFunc   ;==>_StateName

; ============================================================================
; _TrailAdd
; ----------------------------------------------------------------------------
; Description : Appends one item to a connection's short "client commands"
;               trail (shown in the "Connection closed" log line). The
;               trail stops growing at about 240 characters.
; Parameters  : $oConn - Connection dictionary.
;               $sItem - Text to append (a command word, never credentials).
; Returns     : (nothing)
; ============================================================================
Func _TrailAdd($oConn, $sItem)
	Local $sTrail = $oConn.Item("CmdTrail")
	If StringLen($sTrail) >= 240 Then
		If StringRight($sTrail, 3) <> "..." Then $oConn.Item("CmdTrail") = $sTrail & ", ..."
		Return
	EndIf
	If $sTrail <> "" Then $sTrail &= ", "
	$oConn.Item("CmdTrail") = $sTrail & $sItem
EndFunc   ;==>_TrailAdd

; ============================================================================
; _ClientCmdLabel
; ----------------------------------------------------------------------------
; Description : Reduces a line received from the client to a safe, short
;               label for the log: the command word (e.g. "EHLO", "QUIT"),
;               "AUTH PLAIN"/"AUTH LOGIN" for a login (without the
;               credentials), "(credentials)" for the lines that carry login
;               data, or "(non-SMTP/binary data)" for anything that is not
;               printable text (for example a TLS handshake).
; Parameters  : $sLine  - The line as received.
;               $iState - The connection state it arrived in.
; Returns     : The label.
; ============================================================================
Func _ClientCmdLabel($sLine, $iState)
	Switch $iState
		Case $STATE_AUTH_PLAIN_WAIT_CREDS, $STATE_AUTH_LOGIN_WAIT_USER, $STATE_AUTH_LOGIN_WAIT_PASS
			Return "(credentials)"
	EndSwitch
	If StringRegExp($sLine, "[^\x20-\x7E]") Then Return "(non-SMTP/binary data)"
	Local $sTrim = StringStripWS($sLine, 3)
	If $sTrim = "" Then Return "(empty line)"
	Local $aWords = StringSplit($sTrim, " ", 2)
	Local $sVerb = StringUpper(StringLeft($aWords[0], 12))
	If $sVerb = "AUTH" And UBound($aWords) >= 2 Then Return "AUTH " & StringUpper(StringLeft($aWords[1], 12))
	Return $sVerb
EndFunc   ;==>_ClientCmdLabel

; ============================================================================
; _MaskClientLine
; ----------------------------------------------------------------------------
; Description : Returns a line received from the client in a form that is
;               safe to write to the log: the login data of AUTH PLAIN /
;               AUTH LOGIN (the local SMTP password, base64-encoded) is
;               replaced by a note. Earlier versions wrote those lines
;               unmasked at LogLevel 6 and higher.
; Parameters  : $sLine  - The line as received.
;               $iState - The connection state it arrived in.
; Returns     : The line, or a masked version of it.
; ============================================================================
Func _MaskClientLine($sLine, $iState)
	Switch $iState
		Case $STATE_AUTH_PLAIN_WAIT_CREDS, $STATE_AUTH_LOGIN_WAIT_USER, $STATE_AUTH_LOGIN_WAIT_PASS
			Return "(credentials hidden)"
	EndSwitch
	Local $aMatch = StringRegExp($sLine, "(?i)^\s*(AUTH\s+\S+)\s+\S+", 1)
	If Not @error Then Return $aMatch[0] & " (credentials hidden)"
	Return $sLine
EndFunc   ;==>_MaskClientLine

; ============================================================================
; _NoteServerLine
; ----------------------------------------------------------------------------
; Description : Called for every line the real server sends while the
;               connection is still being set up (greeting, EHLO, STARTTLS,
;               XOAUTH2). Remembers it as the "last server reply" and writes
;               every error reply (4xx/5xx) to the log - earlier versions
;               only told the client "535" and kept the server's real
;               reason to themselves. (After the login, the same is done by
;               _SniffServerData().)
; Parameters  : $oConn  - Connection dictionary.
;               $sLine  - One reply line from the real server.
;               $iState - The connection state it arrived in.
; Returns     : (nothing)
; ============================================================================
Func _NoteServerLine($oConn, $sLine, $iState)
	$oConn.Item("LastServerLine") = StringLeft($sLine, 100)
	If StringLen($sLine) >= 4 And StringIsDigit(StringLeft($sLine, 3)) Then
		Local $sFirst = StringLeft($sLine, 1)
		If $sFirst = "4" Or $sFirst = "5" Then
			LogFile("Warning: the real server answered with an error (while " & _StateName($iState) & "; client commands so far: " & _
					$oConn.Item("CmdTrail") & "): " & StringLeft($sLine, 300))
			_StatsNoteError("server: " & StringLeft($sLine, 40)) ; E8
			_NotifyCountError(__ConnAccountName($oConn), StringLeft($sLine, 150)) ; E1
		EndIf
	EndIf
EndFunc   ;==>_NoteServerLine

; ============================================================================
; _SniffLogRelayed
; ----------------------------------------------------------------------------
; Description : Writes the "E-mail relayed: From=... To=... Subject=..." log
;               line when the client has finished sending a message, and
;               remembers the same text (for the warning written if the
;               real server then refuses the message - see
;               _SniffServerData()) plus the command trail entry.
; Parameters  : $oConn - Connection dictionary.
; Returns     : (nothing)
; ============================================================================
Func _SniffLogRelayed($oConn)
	Local $sSummary = "From=" & $oConn.Item("SniffMailFrom") & " To=" & $oConn.Item("SniffRcptTo") & _
			" Subject=""" & $oConn.Item("SniffSubject") & """"
	$oConn.Item("SniffLastMail") = $sSummary
	$oConn.Item("SniffLastCmd") = "end of message (.)"
	_TrailAdd($oConn, "<end of message>")
	LogFile("E-mail relayed: " & $sSummary)
	_StatsCountRelayed() ; E8
EndFunc   ;==>_SniffLogRelayed

; ============================================================================
; _ConnectionSummary
; ----------------------------------------------------------------------------
; Description : Builds the text appended to the "Connection closed" log
;               line: why it was closed, who the client was, how long the
;               connection lived and in which state it ended, when the
;               greeting / EHLO answer / login were completed, which
;               commands the client sent, the last reply of the real
;               server, and - if the client had sent data that the proxy
;               could not interpret - a note on that (a TLS handshake sent
;               to this plain-text port, for example, looks like a client
;               that connects "securely" and then gets no answer).
;               J1: if the connection ended in the middle of a message
;               (DATA sent, end-of-message marker never received), a
;               "MESSAGE INCOMPLETE" note with the number of bytes received
;               and the time of the last data; if the client sent the whole
;               message but the real server had not answered it yet, a note
;               that delivery is uncertain.
; Parameters  : $oConn   - Connection dictionary.
;               $sReason - Why the connection is being closed ("" = not
;               stated).
; Returns     : The text, starting with a space.
; ============================================================================
Func _ConnectionSummary($oConn, $sReason)
	Local $sOut = ""
	If $sReason <> "" Then $sOut &= " Reason: " & $sReason & "."
	$sOut &= " Client=" & $oConn.Item("PeerAddr") & ", lifetime=" & _
			_FormatDurationMs(Round(TimerDiff($oConn.Item("AcceptedAt")))) & ", state=" & _StateName($oConn.Item("State")) & "."

	Local $sTimeline = ""
	If $oConn.Item("T_Greeting") >= 0 Then $sTimeline &= "server greeting passed on to the client after " & _FormatDurationMs($oConn.Item("T_Greeting")) & "; "
	If $oConn.Item("T_Ehlo") >= 0 Then $sTimeline &= "EHLO answered after " & _FormatDurationMs($oConn.Item("T_Ehlo")) & "; "
	If $oConn.Item("T_Auth") >= 0 Then $sTimeline &= "login completed after " & _FormatDurationMs($oConn.Item("T_Auth")) & "; "
	If $sTimeline <> "" Then $sOut &= " Timeline: " & StringTrimRight($sTimeline, 2) & "."

	If $oConn.Item("CmdTrail") <> "" Then $sOut &= " Client commands: " & $oConn.Item("CmdTrail") & "."
	If $oConn.Item("LastServerLine") <> "" Then $sOut &= " Last server reply: " & $oConn.Item("LastServerLine") & "."
	; O1: "Last server reply: 334" alone reads as if the server had just sent
	; something - say plainly when the connection ended while the proxy was
	; still waiting for the real server's answer to the sign-in.
	If ($oConn.Item("State") = $STATE_XOAUTH2_WAIT_334 Or $oConn.Item("State") = $STATE_XOAUTH2_WAIT_RESULT) And _
			$oConn.Item("AuthUpstreamAt") <> 0 Then
		$sOut &= " The proxy had been waiting " & _FormatDurationMs(Round(TimerDiff($oConn.Item("AuthUpstreamAt")))) & _
				" for the real server's answer to the sign-in (XOAUTH2) - no answer came."
	EndIf

	; J1: say plainly when the connection ended in the middle of a message.
	; Only possible while the sniffing is active (it is switched off for the
	; rest of a connection after a buffer overflow - see _SniffClientData()).
	If $oConn.Item("SniffActive") And $oConn.Item("State") = $STATE_AUTHENTICATED Then
		If $oConn.Item("SniffInData") Then
			If $oConn.Item("SniffDataBytes") > 0 Then
				Local $iSinceLastData = Round(TimerDiff($oConn.Item("SniffDataLastTimer")))
				$sOut &= " MESSAGE INCOMPLETE: after DATA the client sent " & _FormatBytes($oConn.Item("SniffDataBytes")) & _
						" of message content (last data at " & _ClockTimeAgo($iSinceLastData) & ", " & _
						_FormatDurationMs($iSinceLastData) & " before the connection closed)" & _
						", but never the end-of-message marker (a line with only a dot). The mail server discards such a" & _
						" message - nothing was delivered. Usually the client program stopped or crashed in the middle of sending."
			Else
				$sOut &= " MESSAGE INCOMPLETE: the client sent DATA, but no message content followed - nothing was delivered."
			EndIf
			_StatsNoteError("message incomplete (client stopped)") ; E8
		ElseIf $oConn.Item("SniffAwaitingDataAck") Then
			$sOut &= " The client sent the complete message, but the real server had not yet answered it when the connection" & _
					" closed - it is unclear whether it was delivered."
		EndIf
	EndIf

	; F3: error output of the helper process (e.g. PowerShell refusing to run
	; the script because of an execution policy, or a crash) - otherwise
	; such a failure would only show up as "Upstream process has ended".
	Local $sHelperErr = StringStripWS(StringRegExpReplace($oConn.Item("StderrTail"), "[\r\n]+", " | "), 3)
	If $sHelperErr <> "" Then $sOut &= " Helper error output: " & StringLeft($sHelperErr, 500)

	Local $sPending = $oConn.Item("RecvBufClient")
	If StringLen($sPending) > 0 Then
		$sOut &= " Unprocessed client bytes: " & StringLen($sPending) & "."
		If StringLen($sPending) > 2 And Asc(StringLeft($sPending, 1)) = 22 And Asc(StringMid($sPending, 2, 1)) = 3 Then
			$sOut &= " They look like a TLS handshake - the client seems to expect SSL/TLS on this port, which the proxy does not offer (the client must connect without encryption)."
		EndIf
	EndIf
	Return $sOut
EndFunc   ;==>_ConnectionSummary

; ============================================================================
; _HelperStderrDrain
; ----------------------------------------------------------------------------
; Description : M1 (v70): reads whatever a PowerShell relay helper has
;               written to its stderr since the last call. The helpers write
;               no log file of their own (M1, v70): every log line is sent
;               over stderr with a marker, and the proxy writes it into its
;               OWN log (N2, v71 - one log file for everything, so the
;               helper's lines stand right next to the proxy's lines of the
;               same connection, and no line can get lost when several
;               helpers log at the same moment):
;                 "ERR|" an error of the helper  -> always logged (level 0)
;                 "LOG|" normal trace            -> LogLevel 6
;                 "DBG|" one line per data chunk -> LogLevel 6 (only sent
;                        by the helper with RelayDebugLog=1)
;               Each line is prefixed with "Helper [<context>]:" - the
;               context registered for the helper's PID in
;               $g_oHelperLogPrefix (socket, client address, PID - or "test
;               e-mail"/"connection test"). Everything on stderr WITHOUT
;               such a marker is real error output of PowerShell itself
;               (e.g. an execution policy refusing the script) and is
;               returned to the caller and kept in $g_oHelperErrTail
;               (last 2000 characters) for the "Helper error output" note.
;               The helper writes UTF-8; the data is read as binary and
;               only complete lines are decoded, so a character split
;               across two reads is never garbled. An incomplete last line
;               is kept for the next call.
;               Must be called regularly while a helper runs (every main
;               loop tick for connections, every wait step of the test
;               e-mail): if nobody reads its stderr, the pipe fills up and
;               the helper stops at its next log line.
; Parameters  : $iPID - PID of the helper process.
; Returns     : The non-"LOG|" text read in this call ("" if none).
; ============================================================================
Func _HelperStderrDrain($iPID)
	If Not $iPID Then Return ""
	Local $bNew = StderrRead($iPID, False, True)
	If @error Or BinaryLen($bNew) = 0 Then Return ""
	Local $sKey = String($iPID)
	Local $bBuf = $bNew
	; (joined via hex text - "&" is a string operator and must not be relied on for binary data)
	If $g_oHelperLogPartial.Exists($sKey) And BinaryLen($g_oHelperLogPartial.Item($sKey)) > 0 Then _
			$bBuf = Binary("0x" & Hex($g_oHelperLogPartial.Item($sKey)) & Hex($bNew))
	; Find the last line feed (byte-wise: ANSI decoding maps 1 byte -> 1 char)
	Local $iLastLf = StringInStr(BinaryToString($bBuf, 1), @LF, 0, -1)
	Local $sErr = ""
	If $iLastLf > 0 Then
		Local $aLines = StringSplit(StringStripCR(BinaryToString(BinaryMid($bBuf, 1, $iLastLf), 4)), @LF, 1)
		Local $i = 0
		For $i = 1 To $aLines[0]
			Local $sLine = $aLines[$i]
			If StringRegExp($sLine, "^(LOG|ERR|DBG)\|") Then
				__HelperLogLine($sKey, StringLeft($sLine, 3), StringMid($sLine, 5))
			ElseIf StringStripWS($sLine, 3) <> "" Then
				$sErr &= $sLine & @CRLF
			EndIf
		Next
		If $iLastLf < BinaryLen($bBuf) Then
			$bBuf = BinaryMid($bBuf, $iLastLf + 1)
		Else
			$bBuf = Binary("")
		EndIf
	EndIf
	If BinaryLen($bBuf) > 16384 Then ; no line end for a long time - treat it as error output
		$sErr &= BinaryToString($bBuf, 4) & @CRLF
		$bBuf = Binary("")
	EndIf
	$g_oHelperLogPartial.Item($sKey) = $bBuf
	If $sErr <> "" Then
		Local $sTail = ""
		If $g_oHelperErrTail.Exists($sKey) Then $sTail = $g_oHelperErrTail.Item($sKey)
		$sTail &= $sErr
		If StringLen($sTail) > 2000 Then $sTail = StringRight($sTail, 2000)
		$g_oHelperErrTail.Item($sKey) = $sTail
	EndIf
	Return $sErr
EndFunc   ;==>_HelperStderrDrain

; Writes one helper log line into the log, with its context and the level
; that belongs to its kind ("ERR" always, "LOG"/"DBG" at LogLevel 6).
Func __HelperLogLine($sKey, $sKind, $sMessage)
	Local $sPrefix = "PID " & $sKey
	If $g_oHelperLogPrefix.Exists($sKey) Then $sPrefix = $g_oHelperLogPrefix.Item($sKey)
	If $sKind = "ERR" Then
		LogFile("Helper error [" & $sPrefix & "]: " & $sMessage)
	Else
		LogFile("Helper [" & $sPrefix & "]: " & $sMessage, 6)
	EndIf
EndFunc   ;==>__HelperLogLine

; ============================================================================
; _HelperLogRegister / _HelperLogForget
; ----------------------------------------------------------------------------
; Description : M1: registers the context shown in front of every log line
;               of a helper (see _HelperStderrDrain()), and removes all
;               state kept for it once it has ended (_Upstream_Kill()).
; Parameters  : $iPID    - PID of the helper process.
;               $sPrefix - Context, e.g. "socket 1752 | 192.168.1.5:50639".
;                          " | PID <n>" is appended automatically.
; ============================================================================
Func _HelperLogRegister($iPID, $sPrefix)
	If Not $iPID Then Return
	$g_oHelperLogPrefix.Item(String($iPID)) = $sPrefix & " | PID " & $iPID
EndFunc   ;==>_HelperLogRegister

; Counterpart of _HelperLogRegister() (same header): logs a last unfinished
; line and removes the prefix and buffer kept for the helper.
Func _HelperLogForget($iPID)
	Local $sKey = String($iPID)
	; an unfinished last line (the helper was ended mid-line) still goes to the log
	If $g_oHelperLogPartial.Exists($sKey) Then
		Local $sRest = StringStripWS(StringStripCR(BinaryToString($g_oHelperLogPartial.Item($sKey), 4)), 3)
		If StringRegExp($sRest, "^(LOG|ERR|DBG)\|") Then __HelperLogLine($sKey, StringLeft($sRest, 3), StringMid($sRest, 5))
		$g_oHelperLogPartial.Remove($sKey)
	EndIf
	If $g_oHelperLogPrefix.Exists($sKey) Then $g_oHelperLogPrefix.Remove($sKey)
	If $g_oHelperErrTail.Exists($sKey) Then $g_oHelperErrTail.Remove($sKey)
EndFunc   ;==>_HelperLogForget

; ============================================================================
; _CollectHelperStderr
; ----------------------------------------------------------------------------
; Description : F3: reads whatever the connection's helper process has written
;               to stderr and keeps the last 2000 characters in
;               $oConn.Item("StderrTail") (shown in the "Connection closed"
;               log line by _ConnectionSummary()). Called on every pump tick,
;               so it also does what the plain StderrRead() there did before:
;               keep the pipe from filling up and blocking the helper. Also
;               works right after the helper has ended - the pipe still holds
;               its last output until StdioClose().
; Parameters  : $oConn - Connection dictionary.
; Returns     : (nothing)
; ============================================================================
Func _CollectHelperStderr($oConn)
	; M1/N2: helper log lines (LOG|/ERR|/DBG|) go into the log, real error output is returned
	Local $sErrOut = _HelperStderrDrain($oConn.Item("UpstreamPID"))
	If $sErrOut = "" Then Return
	Local $sTail = $oConn.Item("StderrTail") & $sErrOut
	If StringLen($sTail) > 2000 Then $sTail = StringRight($sTail, 2000)
	$oConn.Item("StderrTail") = $sTail
EndFunc   ;==>_CollectHelperStderr

; ############################################################################
; #  CONNECTION PUMP (client <-> proxy <-> upstream helper process)
; ############################################################################

; ============================================================================
; _PumpConnection
; ----------------------------------------------------------------------------
; Description : Services one active connection for a single main-loop
;               tick. Performs a non-blocking read from the local client
;               socket and forwards the data either raw (once
;               authenticated - $STATE_AUTHENTICATED) or line-by-line into
;               the SMTP state machine (_OnClientLine) while still
;               negotiating. Then performs the same in the opposite
;               direction for data coming back from the upstream helper
;               process (_OnServerLine). Closes the connection automatically
;               if the client disconnects, a raw send to the client fails
;               (checked explicitly for the authenticated pass-through
;               case, since that TCPSend() has no other error-detection
;               path of its own), or the upstream helper process has
;               terminated. Also drains the helper process's stderr
;               pipe on every call to prevent it from filling up and
;               blocking the child process, keeping its last output for
;               the log (_CollectHelperStderr()).
;               Besides the two watchdog notes (StallWatchdogMs,
;               IdleWatchdogMs) it enforces two hard limits: a connection
;               that has not completed its login within PreAuthTimeoutMs, or
;               a signed-in connection without any data for IdleCloseMs, is
;               closed. Every _CloseConnection() call passes a reason that
;               ends up in the log.
; Parameters  : $oConn        - Connection dictionary for the connection to
;               service.
;               $bAnyActivity - ByRef: set to True (never reset to False
;               here) whenever real client<->server data was relayed this
;               call - see _ServiceConnections()'s own header comment for
;               why its caller needs to know that.
; Returns     : (nothing)
; ============================================================================
Func _PumpConnection($oConn, ByRef $bAnyActivity)
	Local $iPID = $oConn.Item("UpstreamPID")
	If Not ProcessExists($iPID) Then
		_CollectHelperStderr($oConn) ; F3: whatever the helper wrote to stderr before it ended
		LogFile("Upstream process has ended - closing connection.")
		_CloseConnection($oConn, "the upstream helper process (PowerShell) ended - the real mail server closed its connection or could not be reached (details: the ""Helper error"" lines above; all helper lines at LogLevel 6)")
		Return
	EndIf

	; Stall watchdog: a connection that has been open for a while without
	; ever reaching $STATE_AUTHENTICATED is exactly the "accepted, then
	; nothing" pattern that otherwise produces no further log output at
	; all - every other log line in this function only fires once actual
	; data arrives, so a connection stuck waiting for data that never
	; comes (upstream greeting never arriving, a hung TLS handshake in
	; the PowerShell helper, etc.) would otherwise be completely silent
	; from here on. Logs once per connection (StallWarned), not on every
	; tick, to avoid flooding the log for a connection that is simply
	; taking a while. Threshold is the "StallWatchdogMs" INI setting
	; (default 15000 - see _LoadGeneralSettings()).
	If Not $oConn.Item("StallWarned") And TimerDiff($oConn.Item("AcceptedAt")) > $g_iStallWatchdogMs And _
			$oConn.Item("State") <> $STATE_AUTHENTICATED Then
		$oConn.Item("StallWarned") = True
		; O1: name the state in words, and when the proxy is waiting for the
		; real server's answer to the sign-in, say so plainly with how long.
		Local $sStallWhat = _StateName($oConn.Item("State")) & " (state " & $oConn.Item("State") & ")"
		If ($oConn.Item("State") = $STATE_XOAUTH2_WAIT_334 Or $oConn.Item("State") = $STATE_XOAUTH2_WAIT_RESULT) And _
				$oConn.Item("AuthUpstreamAt") <> 0 Then $sStallWhat &= " - the real server has not answered the sign-in for " & _
				_FormatDurationMs(Round(TimerDiff($oConn.Item("AuthUpstreamAt"))))
		LogFile("Warning: connection (socket=" & $oConn.Item("ClientSocket") & ", upstream helper PID=" & $iPID & _
				") has been open for over " & Int($g_iStallWatchdogMs / 1000) & _
				" seconds without completing authentication - still " & _
				$sStallWhat & ". Client buffer=" & StringLen($oConn.Item("RecvBufClient")) & _
				" byte(s) unprocessed, server buffer=" & StringLen($oConn.Item("RecvBufServer")) & _
				" byte(s) unprocessed, upstream helper still running=" & ProcessExists($iPID) & ".")
	EndIf

	; Idle watchdog (post-authentication): the stall watchdog above only
	; covers a connection that never even finishes authenticating - once
	; authenticated, a client is expected to either keep using the
	; connection (further messages) or close it. One that instead goes
	; quiet for a long stretch after that point - no data in either
	; direction - would otherwise be invisible too, and could mean a
	; client that never sent QUIT and never disconnected, holding an
	; upstream helper process (and its real connection to the mail
	; server) open for no reason. Unlike the one-time stall warning
	; above, this is deliberately allowed to fire again every time
	; $iIdleWarnThresholdMs of silence has passed - LastActivity is
	; reset right here, immediately after logging, which alone is
	; enough to both suppress the very next few ticks (TimerDiff is
	; then close to zero) AND re-arm the check for the next interval of
	; continued silence, so a permanently idle connection is logged
	; about repeatedly rather than only once. (An earlier version of
	; this also gated on a separate "already warned" flag that was only
	; ever cleared by NEW activity - which meant a connection that
	; stayed silent forever, exactly the case this exists to catch,
	; could only ever be logged about once - that flag has been
	; removed; resetting LastActivity alone is both necessary and
	; sufficient.) A long idle period is not necessarily wrong by
	; itself (SMTP allows a client to keep a connection open and send
	; further messages on it later), so this is worded as a note to
	; investigate, not a definite error. Threshold is the "IdleWatchdogMs"
	; INI setting (default 120000 - see _LoadGeneralSettings()).
	If $oConn.Item("State") = $STATE_AUTHENTICATED And _
			TimerDiff($oConn.Item("LastActivity")) > $g_iIdleWatchdogMs Then
		$oConn.Item("LastActivity") = TimerInit()
		LogFile("Note: authenticated connection (socket=" & $oConn.Item("ClientSocket") & _
				", upstream helper PID=" & $iPID & ") has been idle for over " & _
				Int($g_iIdleWatchdogMs / 1000) & " seconds - no data in either direction since. This can " & _
				"be normal (the client is simply keeping the connection open for later use), or may indicate " & _
				"a client that never sent QUIT / never disconnected. Upstream helper still running=" & _
				(ProcessExists($iPID) <> 0) & ".")
	EndIf

	; Hard limits (INI: PreAuthTimeoutMs / IdleCloseMs; 0 = off). The two
	; watchdogs above only WRITE A NOTE about a connection that is stuck; these
	; actually end it, so that a client that connected and then never
	; completed (or never ended) its session cannot keep a helper process and
	; a connection slot alive forever.
	; O2: the real server does not answer the XOAUTH2 sign-in (seen 12.11.2026
	; during a Microsoft 365 disruption: no answer for over 30 s, the client
	; gave up with a timeout of its own). SMTP has no way to tell a waiting
	; client "still working", so instead of letting it run into its own
	; timeout, it gets a clear TEMPORARY error (4xx) - many clients and devices
	; then retry by themselves - and the log says what happened.
	If $g_iAuthResultTimeoutMs > 0 And $oConn.Item("AuthUpstreamAt") <> 0 And _
			($oConn.Item("State") = $STATE_XOAUTH2_WAIT_334 Or $oConn.Item("State") = $STATE_XOAUTH2_WAIT_RESULT) And _
			TimerDiff($oConn.Item("AuthUpstreamAt")) > $g_iAuthResultTimeoutMs Then
		LogFile("Warning: the real mail server did not answer the sign-in (XOAUTH2) of connection (socket=" & _
				$oConn.Item("ClientSocket") & ", upstream helper PID=" & $iPID & ") within " & _
				Int($g_iAuthResultTimeoutMs / 1000) & " seconds (AuthResultTimeoutMs) - the mail service is probably " & _
				"disrupted or very slow. The client gets a temporary error (454) so it can try again.")
		_StatsNoteError("mail server did not answer the sign-in") ; E8
		_NotifyCountError(__ConnAccountName($oConn), "the mail server did not answer the sign-in within " & Int($g_iAuthResultTimeoutMs / 1000) & " s") ; E1
		_ClientSend($oConn, "454 4.7.0 Temporary authentication failure - the mail server did not respond, please try again later" & @CRLF)
		_CloseConnection($oConn, "the real mail server did not answer the sign-in within " & Int($g_iAuthResultTimeoutMs / 1000) & _
				" s (AuthResultTimeoutMs) - the client was sent 454 (temporary failure)")
		Return
	EndIf

	If $g_iPreAuthTimeoutMs > 0 And $oConn.Item("State") <> $STATE_AUTHENTICATED And _
			TimerDiff($oConn.Item("AcceptedAt")) > $g_iPreAuthTimeoutMs Then
		LogFile("Warning: connection (socket=" & $oConn.Item("ClientSocket") & ", upstream helper PID=" & $iPID & _
				") did not complete the login within " & Int($g_iPreAuthTimeoutMs / 1000) & " seconds (it was " & _
				_StateName($oConn.Item("State")) & ") - closing it.")
		_ClientSend($oConn, "421 4.4.2 CCSMTPOAuth2Proxy closing connection (no login within the time limit)" & @CRLF)
		_CloseConnection($oConn, "no completed login within " & Int($g_iPreAuthTimeoutMs / 1000) & " s (PreAuthTimeoutMs)")
		Return
	EndIf
	If $g_iIdleCloseMs > 0 And $oConn.Item("State") = $STATE_AUTHENTICATED And _
			TimerDiff($oConn.Item("LastDataAt")) > $g_iIdleCloseMs Then
		LogFile("Warning: signed-in connection (socket=" & $oConn.Item("ClientSocket") & ", upstream helper PID=" & $iPID & _
				") had no data in either direction for " & Int($g_iIdleCloseMs / 1000) & " seconds - closing it.")
		_CloseConnection($oConn, "no data in either direction for " & Int($g_iIdleCloseMs / 1000) & " s (IdleCloseMs)")
		Return
	EndIf

	; --- Client -> upstream ---
	Local $bClientData = TCPRecv($oConn.Item("ClientSocket"), 65536, 1)
	Local $bClientErr = @error
	If $bClientErr Then
		LogFile("_PumpConnection PID=" & $iPID & ": client socket error/disconnect detected - closing connection.", 6)
		_CloseConnection($oConn, "the client closed the connection (or the TCP connection broke)")
		Return
	EndIf

	If $bClientData <> "" Then
		; Any activity resets the idle watchdog below, regardless of
		; direction or connection state.
		$oConn.Item("LastActivity") = TimerInit()
		$bAnyActivity = True
		$oConn.Item("LastDataAt") = TimerInit()   ; real data only - unlike LastActivity, never re-armed by the idle note

		LogFile("_PumpConnection PID=" & $iPID & ": " & BinaryLen($bClientData) & " byte(s) received from client (state=" & $oConn.Item("State") & ").", 6)
		If $oConn.Item("State") = $STATE_AUTHENTICATED Then
			_Upstream_WriteRaw($iPID, $bClientData)
			; Purely for the log entry described in _SniffClientData()'s
			; own header comment - never allowed to affect the actual
			; relay above, which already happened on the previous line
			; regardless of anything this does.
			_SniffClientData($oConn, $bClientData)
		Else
			Local $sBuf = $oConn.Item("RecvBufClient")
			Local $aLines = _ExtractLines($sBuf, $bClientData)
			Local $bOverflow = @error
			$oConn.Item("RecvBufClient") = $sBuf
			If $bOverflow Then
				LogFile("Client sent an unterminated line exceeding " & $MAX_LINE_BUFFER_BYTES & " bytes - closing connection.")
				_CloseConnection($oConn, "the client sent an unterminated line of more than " & $MAX_LINE_BUFFER_BYTES & " bytes")
				Return
			EndIf
			Local $i = 0
			For $i = 0 To UBound($aLines) - 1
				_OnClientLine($oConn, $aLines[$i])
			Next
		EndIf
	EndIf

	; The connection may already have been closed by the line processing above
	If Not $g_oActiveConnections.Exists(String($oConn.Item("ClientSocket"))) Then Return

	; --- Upstream -> client ---
	Local $bServerData = StdoutRead($iPID, False, True)
	If Not @error And $bServerData <> "" Then
		$oConn.Item("LastActivity") = TimerInit()
		$bAnyActivity = True
		$oConn.Item("LastDataAt") = TimerInit()

		LogFile("_PumpConnection PID=" & $iPID & ": " & BinaryLen($bServerData) & " byte(s) received from upstream helper process (state=" & $oConn.Item("State") & ").", 6)
		If $oConn.Item("State") = $STATE_AUTHENTICATED Then
			Local $hOpTimer = TimerInit()
			TCPSend($oConn.Item("ClientSocket"), $bServerData)
			Local $iSendErr = @error
			_OpEnd($hOpTimer, "TCPSend to the client, socket", $oConn.Item("ClientSocket"))
			If $iSendErr Then
				; Catches a broken/closed client socket immediately, rather
				; than only noticing on the NEXT tick's TCPRecv() check above
				; (which would otherwise be the sole place a dead client is
				; detected) - matters more here than for the client->upstream
				; direction, since this is the one send call in the whole
				; connection pump that has no other error-detection path of
				; its own to eventually fall back on.
				LogFile("_PumpConnection PID=" & $iPID & ": TCPSend to client failed (@error=" & $iSendErr & ") - closing connection.", 6)
				_CloseConnection($oConn, "sending data to the client failed (@error=" & $iSendErr & ")")
				Return
			EndIf
			; Purely for the log entry described in _SniffServerData()'s
			; own header comment - never allowed to affect the actual
			; relay above, which already happened on the previous lines
			; regardless of anything this does.
			_SniffServerData($oConn, $bServerData)
		Else
			Local $sBuf2 = $oConn.Item("RecvBufServer")
			Local $aLines2 = _ExtractLines($sBuf2, $bServerData)
			Local $bOverflow2 = @error
			$oConn.Item("RecvBufServer") = $sBuf2
			If $bOverflow2 Then
				LogFile("Upstream server sent an unterminated line exceeding " & $MAX_LINE_BUFFER_BYTES & " bytes - closing connection.")
				_CloseConnection($oConn, "the real server sent an unterminated line of more than " & $MAX_LINE_BUFFER_BYTES & " bytes")
				Return
			EndIf
			Local $j = 0
			For $j = 0 To UBound($aLines2) - 1
				_OnServerLine($oConn, $aLines2[$j])
				If Not $g_oActiveConnections.Exists(String($oConn.Item("ClientSocket"))) Then Return
			Next
		EndIf
	EndIf

	_CollectHelperStderr($oConn) ; F3: keeps the pipe from filling up AND remembers what the helper reported
EndFunc   ;==>_PumpConnection

; ============================================================================
; _ClientSend
; ----------------------------------------------------------------------------
; Description : Sends a text string to the local (proxy-facing) client
;               socket of a connection, encoded as ANSI bytes. Used for all
;               control-protocol replies sent to the client (SMTP status
;               lines are always plain ASCII, so ANSI encoding is safe
;               here).
; Parameters  : $oConn - Connection dictionary (must contain "ClientSocket").
;               $sText - Text to send (should already include any
;               necessary line terminator, e.g. @CRLF).
; Returns     : (nothing)
; ============================================================================
Func _ClientSend($oConn, $sText)
	TCPSend($oConn.Item("ClientSocket"), StringToBinary($sText, 1))
EndFunc   ;==>_ClientSend

; ============================================================================
; _UpstreamWriteLine
; ----------------------------------------------------------------------------
; Description : Convenience wrapper that appends @CRLF to $sLine and writes
;               it to the upstream helper process belonging to $oConn.
; Parameters  : $oConn - Connection dictionary (must contain "UpstreamPID").
;               $sLine - Line to send, without a trailing line terminator.
; Returns     : (nothing)
; ============================================================================
Func _UpstreamWriteLine($oConn, $sLine)
	_Upstream_Write($oConn.Item("UpstreamPID"), $sLine & @CRLF)
EndFunc   ;==>_UpstreamWriteLine

; ============================================================================
; _UpstreamStartTls
; ----------------------------------------------------------------------------
; Description : Tells the upstream helper process to upgrade its plain TCP
;               connection to TLS in place, by writing the special
;               $SENTINEL line to its stdin pipe (the helper script
;               recognises this exact line and performs the SslStream
;               handshake instead of forwarding it to the server - see
;               _EnsureRelayHelperScript for the PowerShell side of this).
; Parameters  : $oConn - Connection dictionary (must contain "UpstreamPID").
; Returns     : (nothing)
; ============================================================================
Func _UpstreamStartTls($oConn)
	_Upstream_Write($oConn.Item("UpstreamPID"), $SENTINEL & @CRLF)
EndFunc   ;==>_UpstreamStartTls

; ---------------------------------------------------------------------------
; SMTP state machine: lines coming from the local client
; ---------------------------------------------------------------------------

; ============================================================================
; _OnClientLine
; ----------------------------------------------------------------------------
; Description : Processes a single, complete line received from the local
;               (legacy) SMTP client, driving the client-facing half of the
;               SMTP/OAuth2 state machine. Answers EHLO/HELO by sending
;               EHLO to the server - also for a client that greeted with
;               HELO, since STARTTLS and AUTH only exist after EHLO,
;               and intercepts AUTH PLAIN / AUTH LOGIN: the credentials the
;               client sends are decoded and checked via
;               _CheckLocalCredentials() against the account's e-mail
;               address and its separately configured local SMTP password
;               (see the "Edit" action in _ShowSettingsDialog()) - the local
;               connection is unencrypted, so this is only a rough
;               deterrent against anything on the machine/network segment
;               connecting to the local port unauthenticated, not real
;               transport security. A mismatch is rejected immediately with
;               a 535, without ever contacting the upstream server. Only
;               once the local check passes does the connection switch to
;               sending a real "AUTH XOAUTH2" to the upstream server
;               instead (handled in _OnServerLine once the server's "334"
;               continuation arrives).
;               Every line is added to the connection's command trail as a
;               short label (_ClientCmdLabel() - command words only, never
;               credentials), and the level-6 log line masks the login data
;               (_MaskClientLine()).
; Parameters  : $oConn - Connection dictionary.
;               $sLine - One complete line received from the client
;               (without the trailing CRLF).
; Returns     : (nothing - mutates $oConn.Item("State") and writes replies
;               to the client and/or the upstream helper as a side effect)
; ============================================================================
Func _OnClientLine($oConn, $sLine)
	Local $iState = $oConn.Item("State")
	Local $sLower = StringLower($sLine)
	LogFile("_OnClientLine: state=" & $iState & " line from client: '" & _MaskClientLine($sLine, $iState) & "'", 6)
	_TrailAdd($oConn, _ClientCmdLabel($sLine, $iState))

	Switch $iState
		Case $STATE_READY
			If StringLeft($sLower, 4) = "ehlo" Or StringLeft($sLower, 4) = "helo" Then
				; A2: towards the mail server always EHLO - STARTTLS and AUTH only exist
				; after EHLO, so a client that greets with HELO would otherwise never get
				; through. The client still gets its answer in the form it asked for
				; (see "ClientUsedHelo" in _FinishEhlo()).
				$oConn.Item("ClientUsedHelo") = (StringLeft($sLower, 4) = "helo")
				Local $sHeloArg = StringStripWS(StringMid($sLine, 5), 3)
				If $sHeloArg = "" Then $sHeloArg = @ComputerName
				$oConn.Item("EhloCommand") = "EHLO " & $sHeloArg
				$oConn.Item("EhloAccum") = ""
				$oConn.Item("State") = $STATE_EHLO_WAIT
				_UpstreamWriteLine($oConn, $oConn.Item("EhloCommand"))

			ElseIf StringLeft($sLower, 10) = "auth plain" Then
				If StringLen($sLine) > 11 Then
					Local $sUser1 = "", $sPass1 = ""
					If _DecodeAuthPlainLine(StringMid($sLine, 12), $sUser1, $sPass1) And _
							_CheckLocalCredentials($oConn, $sUser1, $sPass1) Then
						$oConn.Item("State") = $STATE_XOAUTH2_WAIT_334
						$oConn.Item("AuthUpstreamAt") = TimerInit() ; O1/O2
						_UpstreamWriteLine($oConn, "AUTH XOAUTH2")
					Else
						_RejectLocalAuth($oConn, $sUser1)
						Return
					EndIf
				Else
					$oConn.Item("State") = $STATE_AUTH_PLAIN_WAIT_CREDS
					_ClientSend($oConn, "334 " & @CRLF)
				EndIf

			ElseIf StringLeft($sLower, 10) = "auth login" Then
				If StringLen($sLine) > 11 Then
					$oConn.Item("PendingAuthUser") = _Base64DecodeToString(StringMid($sLine, 12))
					$oConn.Item("State") = $STATE_AUTH_LOGIN_WAIT_PASS
					_ClientSend($oConn, "334 " & _Base64Encode(StringToBinary("Password:", 1)) & @CRLF)
				Else
					$oConn.Item("State") = $STATE_AUTH_LOGIN_WAIT_USER
					_ClientSend($oConn, "334 " & _Base64Encode(StringToBinary("Username:", 1)) & @CRLF)
				EndIf

			Else
				; Any other command before sign-in (rare) - forwarded unmodified
				_UpstreamWriteLine($oConn, $sLine)
			EndIf

		Case $STATE_AUTH_PLAIN_WAIT_CREDS
			Local $sUser2 = "", $sPass2 = ""
			If _DecodeAuthPlainLine($sLine, $sUser2, $sPass2) And _CheckLocalCredentials($oConn, $sUser2, $sPass2) Then
				$oConn.Item("State") = $STATE_XOAUTH2_WAIT_334
				$oConn.Item("AuthUpstreamAt") = TimerInit() ; O1/O2
				_UpstreamWriteLine($oConn, "AUTH XOAUTH2")
			Else
				_RejectLocalAuth($oConn, $sUser2)
				Return
			EndIf

		Case $STATE_AUTH_LOGIN_WAIT_USER
			$oConn.Item("PendingAuthUser") = _Base64DecodeToString($sLine)
			$oConn.Item("State") = $STATE_AUTH_LOGIN_WAIT_PASS
			_ClientSend($oConn, "334 " & _Base64Encode(StringToBinary("Password:", 1)) & @CRLF)

		Case $STATE_AUTH_LOGIN_WAIT_PASS
			Local $sPass3 = _Base64DecodeToString($sLine)
			Local $sPendingUser = $oConn.Item("PendingAuthUser")
			$oConn.Item("PendingAuthUser") = ""
			If _CheckLocalCredentials($oConn, $sPendingUser, $sPass3) Then
				$oConn.Item("State") = $STATE_XOAUTH2_WAIT_334
				$oConn.Item("AuthUpstreamAt") = TimerInit() ; O1/O2
				_UpstreamWriteLine($oConn, "AUTH XOAUTH2")
			Else
				_RejectLocalAuth($oConn, $sPendingUser)
				Return
			EndIf

		Case Else
			; Unexpected state - forward the line just to be safe
			_UpstreamWriteLine($oConn, $sLine)
	EndSwitch
EndFunc   ;==>_OnClientLine

; ============================================================================
; _CheckLocalCredentials
; ----------------------------------------------------------------------------
; Description : Validates the username/password a local SMTP client just
;               presented (via AUTH PLAIN or AUTH LOGIN) against the
;               listener's account: the username must match the account's
;               e-mail address (case-insensitively) and the password must
;               match the account's configured local SMTP password (see the
;               "Edit" action in _ShowSettingsDialog() / _SetLocalPassword()).
;               An account with no local password configured yet
;               (LocalPassword = "") rejects every local login attempt
;               rather than silently letting anything through - this is a
;               deliberate fail-closed default so an account can never end
;               up reachable without a locally-set password just because
;               nobody got around to setting one yet. Every outcome is
;               logged with the specific reason (not configured / wrong
;               username / wrong password); the client itself only ever
;               sees a generic 535, so failed attempts do not reveal which
;               part was wrong.
; Parameters  : $oConn     - Connection dictionary (used to reach the
;               listener's account via $oConn.Item("Account")).
;               $sUsername - Username presented by the client (decoded).
;               $sPassword - Password presented by the client (decoded).
; Returns     : True if both match, False otherwise.
; ============================================================================
Func _CheckLocalCredentials($oConn, $sUsername, $sPassword)
	Local $oAcc = $oConn.Item("Account")
	Local $sConfiguredPassword = $oAcc.Item("LocalPassword")

	If $sConfiguredPassword = "" Then
		LogFile("Local SMTP login rejected for " & $oAcc.Item("Username") & _
				": no local SMTP password is configured for this account yet " & _
				"(Settings -> select the account -> Edit).")
		Return False
	EndIf

	If StringLower($sUsername) <> StringLower($oAcc.Item("Username")) Then
		LogFile("Local SMTP login rejected for " & $oAcc.Item("Username") & _
				": submitted username '" & $sUsername & "' does not match.")
		Return False
	EndIf

	If $sPassword <> $sConfiguredPassword Then
		LogFile("Local SMTP login rejected for " & $oAcc.Item("Username") & ": wrong local SMTP password.")
		Return False
	EndIf

	Return True
EndFunc   ;==>_CheckLocalCredentials

; ============================================================================
; _RejectLocalAuth
; ----------------------------------------------------------------------------
; Description : Sends the "535 ... invalid" response for a failed local
;               SMTP login attempt (see _CheckLocalCredentials(), which
;               already logs the specific reason for the failure) and
;               then closes the connection immediately, rather than
;               resetting to $STATE_READY and relying on the client to
;               disconnect on its own - a wrong local password is an
;               unambiguous, final failure with nothing legitimate left
;               to do on this connection, so there is no reason to keep
;               it (and its already-running upstream helper process/TLS
;               connection to the real mail server) open and waiting; if
;               the client wants to retry, a fresh connection costs it
;               nothing. Logs a detailed snapshot of the connection's own
;               state at the moment of rejection (upstream PID, whether
;               that process is still alive, and how many connections are
;               active overall) specifically to help diagnose any future
;               report of the proxy becoming unresponsive after a failed
;               local login, by giving a concrete record of what the
;               connection/process state actually was at that moment
;               rather than having to guess afterwards.
; Parameters  : $oConn     - Connection dictionary for the connection to
;               reject and close.
;               $sUsername - The (locally submitted) username that failed
;               to authenticate, purely for the log entry - never the
;               password.
; Returns     : (nothing - the connection is closed as a side effect)
; ============================================================================
Func _RejectLocalAuth($oConn, $sUsername)
	_ClientSend($oConn, "535 5.7.8 Authentication credentials invalid." & @CRLF)

	Local $iPID = $oConn.Item("UpstreamPID")
	LogFile("Local SMTP authentication failed for '" & $sUsername & "' - closing this connection " & _
			"immediately (client socket=" & $oConn.Item("ClientSocket") & ", upstream helper PID=" & $iPID & _
			", upstream helper still running=" & ProcessExists($iPID) & _
			", other active connections at this moment=" & ($g_oActiveConnections.Count - 1) & ").")

	_CloseConnection($oConn, "the local login was rejected (535)")
EndFunc   ;==>_RejectLocalAuth

; ============================================================================
; _Base64DecodeToString
; ----------------------------------------------------------------------------
; Description : Decodes a base64 string (as sent by the client for a single
;               AUTH LOGIN "Username:"/"Password:" turn) to UTF-8 text.
;               Thin convenience wrapper around _Base64Decode() for the
;               (common) single-value case; see _DecodeAuthPlainLine() for
;               the NUL-separated AUTH PLAIN case.
; Parameters  : $sBase64 - Base64-encoded line received from the client.
; Returns     : The decoded text, or "" if it was empty or not valid base64.
; ============================================================================
Func _Base64DecodeToString($sBase64)
	Local $bData = _Base64Decode($sBase64)
	If BinaryLen($bData) = 0 Then Return ""
	Return BinaryToString($bData, 4)
EndFunc   ;==>_Base64DecodeToString

; ============================================================================
; _QuotedPrintableDecodeToString
; ----------------------------------------------------------------------------
; Description : Decodes RFC 2047's "Q" encoding (used inside a MIME
;               encoded-word - see _DecodeMimeHeader()) to text. This is a
;               MODIFIED form of standard MIME quoted-printable, not
;               identical to it: "_" represents a space (a literal
;               underscore in the original text is itself escaped as
;               "=5F"), which plain quoted-printable does not do. "=XX"
;               (two hex digits) represents one raw byte; every other
;               character is used as-is (RFC 2047 restricts "Q"-encoded
;               text to a safe subset of printable ASCII in the first
;               place, so no further translation is needed for those).
;               The resulting raw bytes are then interpreted using
;               $sCharset - only UTF-8 (the overwhelming majority of
;               real-world subject lines) gets its own path; anything
;               else falls back to the system ANSI codepage
;               (BinaryToString flag 1), which is correct for common
;               single-byte Western charsets (ISO-8859-1, Windows-1252)
;               but not for other encodings such as ISO-2022-JP - an
;               acceptable limitation for what this exists for (making a
;               log file readable), not a general-purpose MIME decoder.
; Parameters  : $sText    - The encoded-word's payload (between the third
;               and fourth "?").
;               $sCharset - The encoded-word's charset field (between the
;               first and second "?"), e.g. "UTF-8".
; Returns     : The decoded text.
; ============================================================================
Func _QuotedPrintableDecodeToString($sText, $sCharset)
	Local $sWithSpaces = StringReplace($sText, "_", " ")
	Local $sHex = ""
	Local $i = 1
	Local $iLen = StringLen($sWithSpaces)
	While $i <= $iLen
		Local $sChar = StringMid($sWithSpaces, $i, 1)
		If $sChar = "=" And $i + 2 <= $iLen Then
			$sHex &= StringMid($sWithSpaces, $i + 1, 2)
			$i += 3
		Else
			$sHex &= Hex(Asc($sChar), 2)
			$i += 1
		EndIf
	WEnd
	If $sHex = "" Then Return ""
	Local $bData = Binary("0x" & $sHex)
	If StringInStr($sCharset, "utf-8") Or StringInStr($sCharset, "utf8") Then
		Return BinaryToString($bData, 4)
	EndIf
	Return BinaryToString($bData, 1)
EndFunc   ;==>_QuotedPrintableDecodeToString

; ============================================================================
; _DecodeMimeHeader
; ----------------------------------------------------------------------------
; Description : Decodes RFC 2047 "encoded word(s)" in a header value (e.g.
;               a Subject line) for readability in the log file -
;               "=?UTF-8?B?...?=" (base64) and "=?UTF-8?Q?...?="
;               (a modified quoted-printable - see
;               _QuotedPrintableDecodeToString()) are the two forms an
;               e-mail client can use to fit non-ASCII text (accented
;               characters, non-Latin scripts, emoji, ...) into a header,
;               which per RFC 5322 is otherwise restricted to plain
;               ASCII. A long subject is often split into several
;               adjacent encoded-words; whitespace directly between two
;               of them is an artifact of that splitting and is removed
;               before decoding, rather than kept as a literal space
;               that was never actually part of the original text.
;               Returns the header unchanged if it contains no
;               recognisable encoded-word at all (the common case for a
;               plain-ASCII subject), and leaves any part of it besides
;               the encoded-word tokens themselves untouched.
;               This is a best-effort convenience for making the log
;               file's "E-mail relayed: ... Subject=..." line readable,
;               not a strict RFC 2047 implementation - see
;               _QuotedPrintableDecodeToString()'s own header comment for
;               its one real limitation (charsets other than UTF-8 and
;               the common single-byte Western ones).
; Parameters  : $sHeader - The raw header value, as received from the
;               client (e.g. _SniffClientData()'s own Subject capture).
; Returns     : The decoded text, or $sHeader unchanged if it contained no
;               encoded-word, or if anything about decoding one failed
;               (deliberately fails open to the original, still-encoded
;               text rather than risking a garbled or truncated result).
; ============================================================================
Func _DecodeMimeHeader($sHeader)
	If Not StringRegExp($sHeader, "=\?[^?]+\?[QqBb]\?[^?]*\?=") Then Return $sHeader

	Local $sCollapsed = StringRegExpReplace($sHeader, "(\?=)[ \t]+(=\?)", "$1$2")

	Local $aTokens = StringRegExp($sCollapsed, "=\?([^?]+)\?([QqBb])\?([^?]*)\?=", 3)
	If @error Then Return $sHeader

	Local $sResult = $sCollapsed
	Local $i = 0
	While $i + 2 < UBound($aTokens)
		Local $sCharset = $aTokens[$i]
		Local $sEncoding = $aTokens[$i + 1]
		Local $sEncodedText = $aTokens[$i + 2]
		Local $sOriginalToken = "=?" & $sCharset & "?" & $sEncoding & "?" & $sEncodedText & "?="

		Local $sDecoded
		If StringUpper($sEncoding) = "B" Then
			If StringInStr($sCharset, "utf-8") Or StringInStr($sCharset, "utf8") Then
				$sDecoded = _Base64DecodeToString($sEncodedText)
			Else
				$sDecoded = BinaryToString(_Base64Decode($sEncodedText), 1)
			EndIf
		Else
			$sDecoded = _QuotedPrintableDecodeToString($sEncodedText, $sCharset)
		EndIf

		$sResult = StringReplace($sResult, $sOriginalToken, $sDecoded, 1)
		$i += 3
	WEnd
	Return $sResult
EndFunc   ;==>_DecodeMimeHeader

; ============================================================================
; _DecodeAuthPlainLine
; ----------------------------------------------------------------------------
; Description : Decodes an SASL "AUTH PLAIN" response: per RFC 4616, the
;               base64 payload decodes to three NUL-separated fields -
;               "authzid" NUL "authcid" NUL "passwd". authzid (the
;               authorization identity) is normally empty and is ignored
;               here; authcid (the login name) and passwd are returned.
;               Works directly on the decoded bytes (rather than converting
;               to an AutoIt string first and splitting on Chr(0)) since
;               AutoIt string handling of embedded NUL bytes is unreliable.
; Parameters  : $sBase64   - Base64 payload as sent by the client (either
;               straight after "AUTH PLAIN ", or as the reply to the "334 "
;               continuation prompt).
;               $sUserOut  - ByRef: receives the decoded authcid (username),
;               or "" on failure.
;               $sPassOut  - ByRef: receives the decoded password, or "" on
;               failure.
; Returns     : True if the payload decoded and contained exactly the
;               expected two NUL separators, False otherwise (malformed
;               input - $sUserOut/$sPassOut are left at "").
; ============================================================================
Func _DecodeAuthPlainLine($sBase64, ByRef $sUserOut, ByRef $sPassOut)
	$sUserOut = ""
	$sPassOut = ""

	Local $bData = _Base64Decode($sBase64)
	Local $iLen = BinaryLen($bData)
	If $iLen = 0 Then Return False

	Local $iFirstNul = 0, $iSecondNul = 0, $i = 1
	For $i = 1 To $iLen
		If BinaryMid($bData, $i, 1) = "0x00" Then
			If $iFirstNul = 0 Then
				$iFirstNul = $i
			Else
				$iSecondNul = $i
				ExitLoop
			EndIf
		EndIf
	Next
	If $iFirstNul = 0 Or $iSecondNul = 0 Then Return False

	$sUserOut = BinaryToString(BinaryMid($bData, $iFirstNul + 1, $iSecondNul - $iFirstNul - 1), 4)
	$sPassOut = BinaryToString(BinaryMid($bData, $iSecondNul + 1, $iLen - $iSecondNul), 4)
	Return True
EndFunc   ;==>_DecodeAuthPlainLine

; ---------------------------------------------------------------------------
; SMTP state machine: lines coming from the upstream helper process
; (i.e. from the real server)
; ---------------------------------------------------------------------------

; ============================================================================
; _OnServerLine
; ----------------------------------------------------------------------------
; Description : Processes a single, complete line received from the
;               upstream helper process (the real SMTP server), driving
;               the server-facing half of the state machine: passes the
;               initial greeting straight through, accumulates and
;               rewrites the multi-line EHLO capability response
;               (_FinishEhlo), negotiates STARTTLS with the server when
;               required, and completes the AUTH XOAUTH2 exchange -
;               fetching/refreshing the OAuth2 access token as needed and
;               reporting success (235, switches to $STATE_AUTHENTICATED)
;               or failure (translated into a 535 sent to the client) back
;               to the local client.
;               Every line also goes through _NoteServerLine(), which keeps
;               it as the "last server reply" and logs any 4xx/5xx error
;               together with the state it arrived in. STARTTLS is sent only
;               once per connection (UpstreamTlsActive), so a second EHLO
;               from the client does not trigger it again. If the server
;               rejects the XOAUTH2 sign-in with a "334" carrying error
;               details, those (base64 JSON) are decoded and logged.
; Parameters  : $oConn - Connection dictionary.
;               $sLine - One complete line received from the upstream
;               helper process (without the trailing CRLF).
; Returns     : (nothing - mutates $oConn.Item("State") and writes replies
;               to the client and/or the upstream helper as a side effect)
; ============================================================================
Func _OnServerLine($oConn, $sLine)
	Local $iState = $oConn.Item("State")
	LogFile("_OnServerLine: state=" & $iState & " line from server: '" & $sLine & "'", 6)
	_NoteServerLine($oConn, $sLine, $iState)

	Switch $iState
		Case $STATE_GREETING
			_ClientSend($oConn, $sLine & @CRLF)
			$oConn.Item("State") = $STATE_READY
			$oConn.Item("T_Greeting") = Round(TimerDiff($oConn.Item("AcceptedAt")))

		Case $STATE_EHLO_WAIT, $STATE_EHLO_WAIT_POST_TLS
			If StringLeft($sLine, 3) <> "250" Then
				_ClientSend($oConn, $sLine & @CRLF)
				Return
			EndIf

			Local $bLast = (StringMid($sLine, 4, 1) = " ")
			$oConn.Item("EhloAccum") = $oConn.Item("EhloAccum") & $sLine & @CRLF
			If Not $bLast Then Return

			If $iState = $STATE_EHLO_WAIT Then
				; ServerSTARTTLS belongs to the listener, not the account - the choice
				; between implicit TLS and STARTTLS was already made when the upstream
				; connection was opened; here we check the mode we remembered for it
				; A1: only once per connection - after STARTTLS the connection is
				; already encrypted, and a second STARTTLS (triggered by a second EHLO
				; from the client) would be refused by the server and end the session.
				If $oConn.Item("NeedsUpstreamStartTls") And Not $oConn.Item("UpstreamTlsActive") Then
					_UpstreamWriteLine($oConn, "STARTTLS")
					$oConn.Item("State") = $STATE_STARTTLS_WAIT
				Else
					_FinishEhlo($oConn)
				EndIf
			Else
				_FinishEhlo($oConn)
			EndIf

		Case $STATE_STARTTLS_WAIT
			If StringLeft($sLine, 3) = "220" Then
				_UpstreamStartTls($oConn)
				$oConn.Item("UpstreamTlsActive") = True
				$oConn.Item("EhloAccum") = ""
				$oConn.Item("State") = $STATE_EHLO_WAIT_POST_TLS
				_UpstreamWriteLine($oConn, $oConn.Item("EhloCommand"))
			Else
				_ClientSend($oConn, $sLine & @CRLF)
				_CloseConnection($oConn, "the real server refused STARTTLS: " & StringLeft($sLine, 100))
			EndIf

		Case $STATE_XOAUTH2_WAIT_334
			If StringLeft($sLine, 3) = "334" Then
				Local $oAcc2 = $oConn.Item("Account")
				Local $iTokenTimer = TimerInit()
				Local $sAccessToken = _Auth_GetValidAccessToken($oAcc2)
				; Level 8: isolates whether a slow send is caused by
				; having to obtain/refresh the OAuth2 access token itself
				; (a blocking HTTPS call to Microsoft/Google - see
				; _Auth_GetValidAccessToken()/_Auth_RefreshToken()) as
				; opposed to anything happening further down the line.
				; Near-instant (a fraction of a millisecond) when a
				; still-valid cached token is simply reused.
				LogFile("Timing: obtaining a valid access token for " & $oAcc2.Item("Username") & _
						" took " & _FormatDurationMs(Round(TimerDiff($iTokenTimer))) & ".", 8)
				If $sAccessToken = "" Then
					; The server is already waiting for our SASL continuation
					; line at this point (it sent "334") - resetting our own
					; state to $STATE_READY without telling it anything would
					; leave that upstream AUTH exchange stuck mid-flight
					; (any next AUTH attempt we start would arrive out of
					; sequence). Since a client retry would fail again anyway
					; (the token is either transiently unavailable or the
					; account genuinely needs re-authentication), close the
					; whole connection instead - the same "send the error,
					; then _CloseConnection()" pattern already used above for
					; a rejected STARTTLS.
					_ClientSend($oConn, "535 5.7.8 Authentication credentials invalid (no token available)." & @CRLF)
					_CloseConnection($oConn, "no OAuth2 access token available (refresh failed or a new sign-in is required)")
					Return
				EndIf
				Local $sXOAuth = _BuildXOAuth2String($oAcc2.Item("Username"), $sAccessToken)
				; Timestamp right before sending, to measure the round
				; trip to the real server for the XOAUTH2 exchange itself
				; (network latency + the server's own auth processing) -
				; see the matching level-8 log line in
				; $STATE_XOAUTH2_WAIT_RESULT below, once its response
				; arrives.
				$oConn.Item("XOAuth2SentAt") = TimerInit()
				$oConn.Item("State") = $STATE_XOAUTH2_WAIT_RESULT
				_UpstreamWriteLine($oConn, $sXOAuth)
			Else
				_ClientSend($oConn, "535 5.7.8 Authentication credentials invalid." & @CRLF)
				$oConn.Item("State") = $STATE_READY
			EndIf

		Case $STATE_XOAUTH2_WAIT_RESULT
			If StringLeft($sLine, 3) = "235" Then
				_ClientSend($oConn, $sLine & @CRLF)
				$oConn.Item("State") = $STATE_AUTHENTICATED
				LogFile("Account " & $oConn.Item("Account").Item("Username") & ": SMTP authentication succeeded.")
				$oConn.Item("T_Auth") = Round(TimerDiff($oConn.Item("AcceptedAt")))
				LogFile("Timing: server confirmed XOAUTH2 sign-in " & _
						_FormatDurationMs(Round(TimerDiff($oConn.Item("XOAuth2SentAt")))) & _
						" after the credentials were sent - this account's SMTP session is now ready to relay.", 8)
			ElseIf StringLeft($sLine, 3) = "334" Then
				; RFC 4954: additional error details requested - acknowledge with an empty line
				; The "334" after the credentials carries the server's own explanation of
				; why it refuses the token (base64 of a short JSON text) - log it.
				Local $sXOAuthErrDetail = _Base64DecodeToString(StringMid($sLine, 5))
				LogFile("Warning: the real server rejected the XOAUTH2 sign-in and sent these details: " & StringLeft($sXOAuthErrDetail, 300))
				_UpstreamWriteLine($oConn, "")
			Else
				_ClientSend($oConn, "535 5.7.8 Authentication credentials invalid." & @CRLF)
				$oConn.Item("State") = $STATE_READY
			EndIf

		Case Else
			_ClientSend($oConn, $sLine & @CRLF)
	EndSwitch
EndFunc   ;==>_OnServerLine

; ============================================================================
; _FinishEhlo
; ----------------------------------------------------------------------------
; Description : Builds the final EHLO capability response that is sent
;               back to the local client, from the accumulated (possibly
;               multi-line) "250" response gathered in
;               $oConn.Item("EhloAccum"). Any "AUTH ..." capability line is
;               rewritten to "AUTH PLAIN LOGIN" (since that is the only
;               mechanism this proxy intercepts), any "STARTTLS" line is
;               removed entirely (local STARTTLS is not offered by this
;               simplified proxy), "CHUNKING" and "BINARYMIME" are
;               removed too (the message sniffing only understands DATA,
;               not BDAT), and - if the server did not advertise
;               AUTH at all - a synthetic "AUTH PLAIN LOGIN" line is
;               appended. Also makes sure exactly one line ends with
;               "250 " (space, not dash) as required by the SMTP
;               multi-line reply format. Finally sends the rewritten
;               response to the client and resets the connection to
;               $STATE_READY.
;               A client that greeted with HELO (ClientUsedHelo) gets a
;               single "250 <name>" line instead, as RFC 5321 expects for
;               HELO.
; Parameters  : $oConn - Connection dictionary (reads and clears
;               "EhloAccum" / "EhloCommand").
; Returns     : (nothing - sends data to the client as a side effect)
; ============================================================================
Func _FinishEhlo($oConn)
	; A2: a client that greeted with HELO expects a single "250 <name>" line
	; and no capability list.
	If $oConn.Item("ClientUsedHelo") Then
		Local $aHeloLines = _SplitCRLF($oConn.Item("EhloAccum"))
		Local $sHeloReply = "250 " & $g_sAppName
		If UBound($aHeloLines) > 0 And StringLen($aHeloLines[0]) > 4 Then $sHeloReply = "250 " & StringMid($aHeloLines[0], 5)
		If $oConn.Item("T_Ehlo") < 0 Then $oConn.Item("T_Ehlo") = Round(TimerDiff($oConn.Item("AcceptedAt")))
		_ClientSend($oConn, $sHeloReply & @CRLF)
		$oConn.Item("EhloAccum") = ""
		$oConn.Item("EhloCommand") = ""
		$oConn.Item("State") = $STATE_READY
		Return
	EndIf

	Local $aLines = _SplitCRLF($oConn.Item("EhloAccum"))
	Local $sOut = ""
	Local $bHaveAuth = False
	Local $i = 0

	For $i = 0 To UBound($aLines) - 1
		Local $sLn = $aLines[$i]
		If StringLen($sLn) >= 4 And StringLeft($sLn, 3) = "250" Then
			Local $sSep = StringMid($sLn, 4, 1)
			Local $sRest = StringMid($sLn, 5)
			Local $sRestUpper = StringUpper($sRest)
			If StringLeft($sRestUpper, 4) = "AUTH" Then
				$sLn = "250" & $sSep & "AUTH PLAIN LOGIN"
				$bHaveAuth = True
			; A3: CHUNKING (BDAT) and BINARYMIME are not passed on either - the
			; message sniffing (log line, timing, fast mode) only understands DATA,
			; and every client can send everything it needs via DATA.
			ElseIf $sRestUpper = "STARTTLS" Or $sRestUpper = "CHUNKING" Or $sRestUpper = "BINARYMIME" Then
				$sLn = ""
			EndIf
		EndIf
		If $sLn <> "" Then
			If $sOut <> "" Then $sOut &= @CRLF
			$sOut &= $sLn
		EndIf
	Next

	Local $aOutLines = _SplitCRLF($sOut)
	Local $iOutCount = UBound($aOutLines)

	If Not $bHaveAuth Then
		If $iOutCount > 0 Then
			Local $sLast = $aOutLines[$iOutCount - 1]
			If StringLeft($sLast, 4) = "250 " Then $aOutLines[$iOutCount - 1] = "250-" & StringMid($sLast, 5)
		EndIf
		_ArrayAdd($aOutLines, "250 AUTH PLAIN LOGIN")
	Else
		If $iOutCount > 0 Then
			Local $sLast2 = $aOutLines[$iOutCount - 1]
			If StringLeft($sLast2, 4) = "250-" Then $aOutLines[$iOutCount - 1] = "250 " & StringMid($sLast2, 5)
		EndIf
	EndIf

	Local $sFinal = ""
	For $i = 0 To UBound($aOutLines) - 1
		$sFinal &= $aOutLines[$i] & @CRLF
	Next

	If $oConn.Item("T_Ehlo") < 0 Then $oConn.Item("T_Ehlo") = Round(TimerDiff($oConn.Item("AcceptedAt")))
	_ClientSend($oConn, $sFinal)
	$oConn.Item("EhloAccum") = ""
	$oConn.Item("EhloCommand") = ""
	$oConn.Item("State") = $STATE_READY
EndFunc   ;==>_FinishEhlo

; ############################################################################
; #  UPSTREAM HELPER PROCESS (PowerShell / .NET SslStream)
; ############################################################################

; ============================================================================
; _Upstream_Start
; ----------------------------------------------------------------------------
; Description : Launches a new instance of the PowerShell TLS relay helper
;               script (see _EnsureRelayHelperScript) as a hidden child
;               process, connected via pipes (stdin/stdout/stderr). Each
;               proxy connection - and each test e-mail - gets its own,
;               independent helper process and thus its own independent
;               TCP/TLS connection to the real server. Checks that
;               powershell.exe actually exists at the expected path first,
;               falling back to PowerShell 7+ (pwsh.exe, located via
;               _FindPowerShell7()) if it does not, so a missing/removed
;               Windows PowerShell 5.1 installation does not, by itself,
;               make the whole proxy unusable. Either way, a total
;               failure to find any PowerShell at all is reported clearly
;               and immediately via LogFile() instead of only surfacing later
;               as a generic "process does not exist" failure once
;               _PumpConnection()/_SendTestEmail() try to use the (never
;               started) helper process.
;               Also passes -VerboseLog (the RelayDebugLog INI setting),
;               which decides whether the helper also sends a line per data
;               chunk (written into the log at LogLevel 6 by
;               _HelperStderrDrain()). The Run() call is timed with _OpEnd() for
;               the main-loop watchdog.
; Parameters  : $sServerAddress - Hostname of the real SMTP server.
;               $iServerPort    - Port of the real SMTP server.
;               $bImplicitTLS   - True to wrap the connection in TLS
;               immediately after connecting (e.g. port 465); False to
;               start in plain text and upgrade later via
;               _UpstreamStartTls() (e.g. port 587 with STARTTLS).
; Returns     : The PID of the newly started helper process (usable with
;               ProcessExists/ProcessClose/StdinWrite/StdoutRead), or 0 if
;               no PowerShell executable could be found (nothing was
;               started).
; ============================================================================
Func _Upstream_Start($sServerAddress, $iServerPort, $bImplicitTLS)
	Local $sImplicit = "0"
	If $bImplicitTLS Then $sImplicit = "1"

	Local $sPowershell = @SystemDir & "\WindowsPowerShell\v1.0\powershell.exe"
	If Not FileExists($sPowershell) Then
		Local $sPwsh7 = _FindPowerShell7()
		If $sPwsh7 <> "" Then
			LogFile("Windows PowerShell was not found at '" & $sPowershell & "' - using PowerShell 7+ instead: " & $sPwsh7)
			$sPowershell = $sPwsh7
		Else
			LogFile("Error: neither Windows PowerShell ('" & $sPowershell & "') nor PowerShell 7+ (pwsh.exe, " & _
					"searched for via PATH) could be found - cannot start the TLS relay helper. Connection to " & _
					$sServerAddress & ":" & $iServerPort & " will fail.")
			Return 0
		EndIf
	EndIf

	Local $sCmd = '"' & $sPowershell & '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' & _
			$g_sRelayScriptPath & '" -ServerAddress "' & $sServerAddress & '" -ServerPort ' & $iServerPort & _
			' -ImplicitTls ' & $sImplicit & ' -VerboseLog ' & $g_iRelayDebugLog

	Local $hOpTimer = TimerInit()
	Local $iPID = Run($sCmd, @ScriptDir, @SW_HIDE, BitOR($STDIN_CHILD, $STDOUT_CHILD, $STDERR_CHILD))
	_OpEnd($hOpTimer, "starting the PowerShell helper (Run)")
	LogFile("_Upstream_Start: PID=" & $iPID & " Server=" & $sServerAddress & ":" & $iServerPort & _
			" ImplicitTLS=" & $sImplicit & " Skript=" & $g_sRelayScriptPath, 6)
	Return $iPID
EndFunc   ;==>_Upstream_Start

; ============================================================================
; _FindPowerShell7
; ----------------------------------------------------------------------------
; Description : Looks for pwsh.exe (PowerShell 7+) via a plain PATH search
;               (the "Path" environment variable, checked directory by
;               directory) - used by _Upstream_Start() as a fallback when
;               the classic Windows PowerShell 5.1 install this script
;               otherwise assumes is missing. A PATH search was chosen
;               over checking a single hardcoded install location (e.g.
;               "Program Files\PowerShell\7") deliberately: pwsh.exe's
;               install location varies by install method (MSI, winget,
;               a portable copy, ...), and any "Program Files"-based guess
;               would be vulnerable to the exact same 32-bit-process/WOW64
;               folder redirection mix-up that once caused the tray icon
;               extraction code to look in the wrong "Program Files" - see
;               @SystemDir's own WOW64 redirection for the same reason.
;               A plain PATH search sidesteps that entirely, and also
;               matches what the PowerShell 7 installer already does by
;               default (adds its own folder to PATH).
; Parameters  : (none)
; Returns     : Full path to pwsh.exe if found somewhere on PATH, or "" if
;               not.
; ============================================================================
Func _FindPowerShell7()
	Local $sPath = EnvGet("Path")
	If $sPath = "" Then Return ""

	Local $aDirs = StringSplit($sPath, ";")
	Local $i = 0
	For $i = 1 To $aDirs[0]
		Local $sDir = StringStripWS($aDirs[$i], 3)
		If $sDir = "" Then ContinueLoop
		Local $sCandidate = $sDir & "\pwsh.exe"
		If FileExists($sCandidate) Then Return $sCandidate
	Next
	Return ""
EndFunc   ;==>_FindPowerShell7

; ============================================================================
; _Upstream_Write
; ----------------------------------------------------------------------------
; Description : Writes a text string to the stdin pipe of an upstream
;               helper process, ANSI-encoded. Used for SMTP control lines
;               (always plain ASCII, so ANSI encoding is safe and
;               correct here) and, from _SendTestEmail(), the (possibly
;               large - a "large" test e-mail or one with an attachment
;               can run to several megabytes) message content. Does
;               nothing if the process is no longer running. Logs the
;               byte count and a length-capped preview of the text via
;               LogFile(), including the @error StdinWrite reports,
;               so the live console shows precisely what was (attempted
;               to be) sent to the upstream helper at each step - the
;               preview is capped to a fixed length up front, before any
;               further string work, so building it stays cheap even for
;               a very large $sData: AutoIt evaluates a function's own
;               arguments (including this one's eventual LogFile()
;               call) before that function gets a chance to check
;               anything, so an uncapped StringStripWS() over the full
;               text would otherwise do wasted, potentially expensive
;               work on every single call regardless of the log level.
;               An XOAUTH2 sign-in string (base64 of "user=...", which
;               contains the access token) is never shown in the preview.
; Parameters  : $iPID  - PID of the target upstream helper process.
;               $sData - Text to send (include any needed line terminator
;               yourself, e.g. via @CRLF).
; Returns     : (nothing)
; ============================================================================
Func _Upstream_Write($iPID, $sData)
	Local $sPreview = $sData
	If StringLen($sPreview) > 200 Then
		$sPreview = StringLeft($sPreview, 200) & "... (" & StringLen($sData) & " chars total)"
	EndIf
	$sPreview = StringStripWS($sPreview, 3)
	; Never write the XOAUTH2 sign-in string (base64 of "user=...", contains the access token) to the log.
	If StringLeft($sPreview, 7) = "dXNlcj0" Then $sPreview = "(XOAUTH2 sign-in string - hidden)"

	If Not ProcessExists($iPID) Then
		LogFile("_Upstream_Write PID=" & $iPID & ": process no longer exists - nothing sent. Text was: '" & $sPreview & "'", 6)
		Return
	EndIf
	Local $bBin = StringToBinary($sData, 1)
	Local $hOpTimer = TimerInit()
	Local $iRet = StdinWrite($iPID, $bBin)
	Local $iErr = @error
	_OpEnd($hOpTimer, "StdinWrite to the helper, PID", $iPID)
	LogFile("_Upstream_Write PID=" & $iPID & ": " & BinaryLen($bBin) & " byte(s) sent to stdin " & _
			"(StdinWrite return value=" & $iRet & ", @error=" & $iErr & "): '" & $sPreview & "'", 6)
EndFunc   ;==>_Upstream_Write

; ============================================================================
; _Upstream_WriteRaw
; ----------------------------------------------------------------------------
; Description : Writes raw binary data to the stdin pipe of an upstream
;               helper process, unmodified. Used once a connection is
;               $STATE_AUTHENTICATED, to relay the message body
;               byte-for-byte without any text decoding (important for
;               8-bit/binary MIME content). Does nothing if the process is
;               no longer running. Logs the byte count (not the content,
;               which may be arbitrary binary message data) and the
;               StdinWrite result via LogFile().
; Parameters  : $iPID   - PID of the target upstream helper process.
;               $bData  - Binary data to send, exactly as received from
;               the client.
; Returns     : (nothing)
; ============================================================================
Func _Upstream_WriteRaw($iPID, $bData)
	If Not ProcessExists($iPID) Then
		LogFile("_Upstream_WriteRaw PID=" & $iPID & ": process no longer exists - " & BinaryLen($bData) & " byte(s) NOT sent.", 6)
		Return
	EndIf
	Local $hOpTimer = TimerInit()
	Local $iRet = StdinWrite($iPID, $bData)
	Local $iErr = @error
	_OpEnd($hOpTimer, "StdinWrite to the helper, PID", $iPID)
	LogFile("_Upstream_WriteRaw PID=" & $iPID & ": " & BinaryLen($bData) & " byte(s) (raw) sent to stdin " & _
			"(StdinWrite return value=" & $iRet & ", @error=" & $iErr & ").", 6)
EndFunc   ;==>_Upstream_WriteRaw

; ============================================================================
; _RotateLogFile
; ----------------------------------------------------------------------------
; Description : E3: log rotation. If the file has reached MaxLogSizeMB, the
;               older generations are shifted (Name.1.log -> Name.2.log ...,
;               the oldest - Name.<LogGenerations>.log - is deleted) and the
;               current file becomes Name.1.log; the next line written then
;               starts a new, empty file. If the current file cannot be
;               renamed at that moment (e.g. it is open in an editor that
;               locks it), nothing is lost - it is simply tried again on
;               the next check.
; Parameters  : $sPath - Full path of the current log file (ending in .log).
; Returns     : True if the file was rotated, False otherwise.
; ============================================================================
Func _RotateLogFile($sPath)
	If $g_iMaxLogSizeMB <= 0 Then Return False
	If Not FileExists($sPath) Then Return False
	If FileGetSize($sPath) < $g_iMaxLogSizeMB * 1048576 Then Return False

	Local $sBase = StringRegExpReplace($sPath, "(?i)\.log$", "")
	Local $i = 0
	If FileExists($sBase & "." & $g_iLogGenerations & ".log") Then FileDelete($sBase & "." & $g_iLogGenerations & ".log")
	For $i = $g_iLogGenerations - 1 To 1 Step -1
		If FileExists($sBase & "." & $i & ".log") Then FileMove($sBase & "." & $i & ".log", $sBase & "." & ($i + 1) & ".log", 1)
	Next
	Return (FileMove($sPath, $sBase & ".1.log", 1) = 1)
EndFunc   ;==>_RotateLogFile

; ============================================================================
; _LogRotationTick
; ----------------------------------------------------------------------------
; Description : E3: called from _ServiceConnections(); at most once a minute
;               (and right after the start) checks the log file against
;               MaxLogSizeMB and rotates it (_RotateLogFile()). Checking once a minute instead of on
;               every log line keeps LogFile() itself as cheap as before;
;               a file can therefore grow a little beyond the limit.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _LogRotationTick()
	If $g_iMaxLogSizeMB <= 0 Then Return
	If $g_hLastLogRotateCheck <> 0 And TimerDiff($g_hLastLogRotateCheck) < 60000 Then Return
	$g_hLastLogRotateCheck = TimerInit()
	If _RotateLogFile($g_sLogPath) Then
		LogFile("Log file rotated - it had reached " & $g_iMaxLogSizeMB & " MB (MaxLogSizeMB); the previous part is " & _
				StringRegExpReplace($g_sLogPath, "(?i)\.log$", "") & ".1.log (" & $g_iLogGenerations & " older parts are kept).")
	EndIf
EndFunc   ;==>_LogRotationTick

; ============================================================================
; _ClearLogsOnStartIfConfigured
; ----------------------------------------------------------------------------
; Description : Optionally deletes the log file ($g_sLogPath) once at
;               startup, so each session begins with a fresh log instead of
;               an ever-growing file - controlled by the ClearLogOnStart
;               INI setting ($g_bClearLogOnStart, default 1 = clear; read
;               by _LoadGeneralSettings()). Older rotated parts
;               (Name.1.log ...) are never deleted here. Must be called
;               AFTER _LoadGeneralSettings() and BEFORE the first LogFile()
;               call of the session.
;               (Up to v70 there was a second log for the PowerShell
;               helpers with its own ClearRelayLogOnStart setting; since
;               v71 their lines are part of this log - N2.)
; Parameters  : (none)
; Returns     : (nothing - deletes the file as a side effect)
; ============================================================================
Func _ClearLogsOnStartIfConfigured()
	If $g_bClearLogOnStart Then
		If FileExists($g_sLogPath) Then FileDelete($g_sLogPath)
	EndIf
EndFunc   ;==>_ClearLogsOnStartIfConfigured

; ============================================================================
; _EnsureRelayHelperScript
; ----------------------------------------------------------------------------
; Description : (Re-)writes the PowerShell TLS relay helper script to disk
;               (<AppName>-RelayHelper.ps1, i.e. CCSMTPOAuth2Proxy-RelayHelper.ps1, directly next to this program) every time
;               the program starts, so that an updated version of this
;               AutoIt script always ships with a matching, up-to-date
;               helper file. The helper script, once started by
;               _Upstream_Start(), connects to the real SMTP server (with
;               immediate TLS if $ImplicitTls = 1), then relays raw bytes
;               between its own stdin/stdout and the (possibly still
;               plain-text) server connection. While the connection is
;               still plain text, it also watches for a special sentinel
;               line ("##PROXY_STARTTLS##") on stdin; on seeing it, it
;               performs an in-place .NET SslStream TLS handshake over the
;               existing socket and continues relaying - this is how
;               _UpstreamStartTls() triggers the STARTTLS upgrade. Its own
;               internal poll loop delay is baked in from $g_iRelayPollMs
;               (the "RelayPollMs" INI setting under [General], read by
;               _LoadGeneralSettings() before this function runs) - a
;               changed value only takes effect on the next call to this
;               function (i.e. the next program start), since it is
;               written into the generated script text, not read by the
;               helper at its own runtime. (RelayDebugLog, by contrast, is
;               passed on every start as -VerboseLog.) The helper requests
;               TLS 1.2 explicitly (plus TLS 1.3 on Windows 11 / Server
;               2022 and later, see Get-TlsProtocols), logs the TLS version
;               negotiated, and logs byte totals when it ends. The helper
;               writes no file itself: its log lines go over stderr to the
;               proxy (see _HelperStderrDrain()). Sets the module-level
;               $g_sRelayScriptPath to the path of the file it wrote.
;               Checks both FileOpen() and
;               FileWrite() for failure (e.g. the file locked by another
;               process, or a permissions problem) and logs a clear error
;               via LogFile() if either fails, rather than leaving a missing
;               or stale helper script to only surface later as a
;               confusing, unexplained connection failure.
; Parameters  : (none)
; Returns     : (nothing - writes the helper script to disk and sets
;               $g_sRelayScriptPath as a side effect)
; ============================================================================
Func _EnsureRelayHelperScript()
	; One script file next to the program; every connection starts its own
	; PowerShell process with this same file (they only read it). Its trace
	; log lines go over stderr to the proxy, which writes them into the log
	; (_HelperStderrDrain(), M1/N2).
	If Not FileExists($g_sLogDir) Then DirCreate($g_sLogDir)
	$g_sRelayScriptPath = @ScriptDir & "\" & $g_sAppName & "-RelayHelper.ps1" ; named after the program (follows $g_sAppName)

	Local $sPS = ""
	$sPS &= "<#" & @CRLF
	$sPS &= "    " & $g_sAppName & "-RelayHelper.ps1" & @CRLF
	$sPS &= "    ----------------------------------------------------------------------" & @CRLF
	$sPS &= "    Auto-generated by _EnsureRelayHelperScript() in " & $g_sAppName & "." & @CRLF
	$sPS &= "    Do not edit this file directly - it is overwritten every time the" & @CRLF
	$sPS &= "    proxy starts." & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    PURPOSE" & @CRLF
	$sPS &= "    AutoIt has no built-in TLS sockets. This small PowerShell script is" & @CRLF
	$sPS &= "    launched as a child process (via Run(), with piped stdin/stdout/" & @CRLF
	$sPS &= "    stderr) to provide the TLS connection to the real SMTP server, using" & @CRLF
	$sPS &= "    .NET's SslStream. AutoIt itself owns all SMTP/OAuth2 protocol logic;" & @CRLF
	$sPS &= "    this script's only job is to be a transparent byte relay between:" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "        AutoIt (stdin/stdout of this process)  <-->  real SMTP server (TCP/TLS)" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    It supports two TLS modes:" & @CRLF
	$sPS &= "      - ""Implicit TLS"" ($ImplicitTls = 1): wrap the connection in TLS" & @CRLF
	$sPS &= "        immediately after connecting (e.g. SMTP port 465)." & @CRLF
	$sPS &= "      - ""STARTTLS"" ($ImplicitTls = 0): start in plain text; AutoIt performs" & @CRLF
	$sPS &= "        the plain-text EHLO/STARTTLS command exchange itself (relayed" & @CRLF
	$sPS &= "        through this script like any other data), and later tells this" & @CRLF
	$sPS &= "        script to upgrade the existing socket to TLS in place by sending" & @CRLF
	$sPS &= "        a special sentinel line on stdin (see the ""Sentinel"" handling" & @CRLF
	$sPS &= "        below) - this mirrors how STARTTLS works in the real SMTP" & @CRLF
	$sPS &= "        protocol (RFC 3207)." & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    WHY THIS VERSION LOOKS DIFFERENT FROM EARLIER ONES (stdin reading)" & @CRLF
	$sPS &= "    An earlier version of this script read stdin on a background" & @CRLF
	$sPS &= "    .NET Task, created by casting a PowerShell scriptblock to an" & @CRLF
	$sPS &= "    [Action] delegate and running it via [Task]::Run() (a common-looking" & @CRLF
	$sPS &= "    but unreliable pattern). That delegate runs on a raw .NET ThreadPool" & @CRLF
	$sPS &= "    thread with NO PowerShell Runspace attached to it; accessing the" & @CRLF
	$sPS &= "    outer-scope PowerShell variables it captured could fail there in a" & @CRLF
	$sPS &= "    way that PowerShell's own try/catch inside that same scriptblock does" & @CRLF
	$sPS &= "    not reliably observe. In practice this meant the reader thread could" & @CRLF
	$sPS &= "    die silently at start-up: the main loop kept running fine (so the" & @CRLF
	$sPS &= "    server's greeting was still relayed correctly), but nothing typed" & @CRLF
	$sPS &= "    into stdin afterwards (e.g. the client's first ""EHLO ..."") was ever" & @CRLF
	$sPS &= "    picked up again - with no error anywhere to explain why." & @CRLF
	$sPS &= "    This version avoids background threads (and therefore this whole" & @CRLF
	$sPS &= "    class of problem) entirely: it uses .NET's asynchronous" & @CRLF
	$sPS &= "    Stream.ReadAsync() on stdin, and simply polls the resulting Task's" & @CRLF
	$sPS &= "    IsCompleted/IsFaulted/Result properties from the SAME thread as the" & @CRLF
	$sPS &= "    main loop below. Inspecting a Task's properties is plain .NET and" & @CRLF
	$sPS &= "    perfectly safe from any thread; only actually EXECUTING PowerShell" & @CRLF
	$sPS &= "    script code on a foreign thread is the problematic part, and this" & @CRLF
	$sPS &= "    version never does that." & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    DIAGNOSTICS" & @CRLF
	$sPS &= "    This script writes no log file. It sends short trace lines over its" & @CRLF
	$sPS &= "    stderr, one per line and UTF-8, each with a marker in front:" & @CRLF
	$sPS &= "      LOG|  normal trace (connect, TLS, end with byte totals)" & @CRLF
	$sPS &= "      ERR|  an error (connection failed, read/send error)" & @CRLF
	$sPS &= "      DBG|  one line per data chunk - only with -VerboseLog 1" & @CRLF
	$sPS &= "    The AutoIt proxy reads stderr and writes these lines into its own" & @CRLF
	$sPS &= "    log, with the connection (socket, client address, PID) in front:" & @CRLF
	$sPS &= "    ERR| always, LOG| and DBG| at LogLevel 6. Anything else on stderr" & @CRLF
	$sPS &= "    (e.g. PowerShell's own error messages) is treated as error output." & @CRLF
	$sPS &= "    Logging failures are always swallowed (try/catch), so a logging" & @CRLF
	$sPS &= "    problem itself can never break the relay." & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    PARAMETERS (passed as command-line arguments by _Upstream_Start())" & @CRLF
	$sPS &= "      -ServerAddress  Hostname of the real SMTP server to connect to." & @CRLF
	$sPS &= "      -ServerPort     Port of the real SMTP server to connect to." & @CRLF
	$sPS &= "      -ImplicitTls    1 = wrap in TLS immediately; 0 = start in plain text" & @CRLF
	$sPS &= "                      and wait for the sentinel line to upgrade later." & @CRLF
	$sPS &= "      -VerboseLog     1 = log every data chunk (see DIAGNOSTICS); default 0." & @CRLF
	$sPS &= "#>" & @CRLF
	$sPS &= "param(" & @CRLF
	$sPS &= "    [Parameter(Mandatory=$true)][string]$ServerAddress," & @CRLF
	$sPS &= "    [Parameter(Mandatory=$true)][int]$ServerPort," & @CRLF
	$sPS &= "    [Parameter(Mandatory=$true)][int]$ImplicitTls," & @CRLF
	$sPS &= "    [int]$VerboseLog = 0   # 1 = log every data chunk (RelayDebugLog in the INI) - slow, only for troubleshooting" & @CRLF
	$sPS &= ")" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# Abort the whole script on any unhandled .NET exception instead of" & @CRLF
	$sPS &= "# silently continuing in a broken state." & @CRLF
	$sPS &= "$ErrorActionPreference = 'Stop'" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# Special marker line that AutoIt sends on stdin (only ever while the" & @CRLF
	$sPS &= "# connection is still plain text) to request the STARTTLS-style in-place" & @CRLF
	$sPS &= "# TLS upgrade. Chosen to be extremely unlikely to collide with real SMTP" & @CRLF
	$sPS &= "# command text." & @CRLF
	$sPS &= "$Sentinel = '##PROXY_STARTTLS##'" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 0) Minimal diagnostic logger (M1/N2): one line per message over stderr," & @CRLF
	$sPS &= "#    UTF-8, marked LOG| / ERR| / DBG| (see DIAGNOSTICS) - the AutoIt proxy" & @CRLF
	$sPS &= "#    writes it into its log. Never allowed to throw." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "$LogOut = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), (New-Object System.Text.UTF8Encoding($false)))" & @CRLF
	$sPS &= "$LogOut.AutoFlush = $true" & @CRLF
	$sPS &= "function Write-RelayLogLine([string]$Kind, [string]$Message) {" & @CRLF
	$sPS &= "    try { $LogOut.WriteLine($Kind + '|' + ($Message -replace '[\r\n]+', ' ')) } catch {}" & @CRLF
	$sPS &= "}" & @CRLF
	$sPS &= "function Write-RelayLog([string]$Message) { Write-RelayLogLine 'LOG' $Message }" & @CRLF
	$sPS &= "function Write-RelayLogError([string]$Message) { Write-RelayLogLine 'ERR' $Message }" & @CRLF
	$sPS &= "# Per-chunk details only when VerboseLog=1 (one line per data chunk)." & @CRLF
	$sPS &= "# TLS versions to offer (F4): always TLS 1.2 - the minimum Microsoft and Google" & @CRLF
	$sPS &= "# accept - plus TLS 1.3 where both .NET and Windows support it (Windows Server" & @CRLF
	$sPS &= "# 2022 / Windows 11, build 20348 and later). Stated explicitly so an older system" & @CRLF
	$sPS &= "# without the SchUseStrongCrypto registry setting cannot fall back to TLS 1.0." & @CRLF
	$sPS &= "function Get-TlsProtocols {" & @CRLF
	$sPS &= "    $p = [System.Security.Authentication.SslProtocols]::Tls12" & @CRLF
	$sPS &= "    if (([Enum]::GetNames([System.Security.Authentication.SslProtocols]) -contains 'Tls13') -and ([Environment]::OSVersion.Version.Build -ge 20348)) {" & @CRLF
	$sPS &= "        $p = $p -bor [System.Security.Authentication.SslProtocols]'Tls13'" & @CRLF
	$sPS &= "    }" & @CRLF
	$sPS &= "    return $p" & @CRLF
	$sPS &= "}" & @CRLF
	$sPS &= "function Write-RelayLogVerbose([string]$Message) {" & @CRLF
	$sPS &= "    if ($VerboseLog -eq 1) { Write-RelayLogLine 'DBG' $Message }" & @CRLF
	$sPS &= "}" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "Write-RelayLog ""Start: ServerAddress=$ServerAddress ServerPort=$ServerPort ImplicitTls=$ImplicitTls VerboseLog=$VerboseLog""" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 1) Open the underlying TCP connection to the real SMTP server." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "try {" & @CRLF
	$sPS &= "    $client = New-Object System.Net.Sockets.TcpClient" & @CRLF
	$sPS &= "    $client.Connect($ServerAddress, $ServerPort)" & @CRLF
	$sPS &= "    Write-RelayLog ""TCP connected.""" & @CRLF
	$sPS &= "} catch {" & @CRLF
	$sPS &= "    # Could not even establish the TCP connection - nothing more to do." & @CRLF
	$sPS &= "    # AutoIt detects this because the process exits without ever" & @CRLF
	$sPS &= "    # producing a server greeting, and the corresponding proxy" & @CRLF
	$sPS &= "    # connection will time out / be closed." & @CRLF
	$sPS &= "    Write-RelayLogError ""TCP connection failed: $($_.Exception.Message)""" & @CRLF
	$sPS &= "    exit 1" & @CRLF
	$sPS &= "}" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "$netStream = $client.GetStream()   # the raw (always unencrypted at the socket level) NetworkStream" & @CRLF
	$sPS &= "$stream = $netStream               # the stream currently used for reading/writing application data;" & @CRLF
	$sPS &= "                                    # starts out equal to $netStream, and is replaced with an SslStream" & @CRLF
	$sPS &= "                                    # instance once TLS becomes active (either immediately below, or" & @CRLF
	$sPS &= "                                    # later via the Sentinel line)" & @CRLF
	$sPS &= "$tlsActive = $false" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 2) Implicit TLS mode: wrap the socket in TLS right away (e.g. port 465)." & @CRLF
	$sPS &= "#    AuthenticateAsClient performs the full TLS handshake and validates" & @CRLF
	$sPS &= "#    the server's certificate against the Windows trust store, using" & @CRLF
	$sPS &= "#    $ServerAddress as the expected certificate host name." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "if ($ImplicitTls -eq 1) {" & @CRLF
	$sPS &= "    try {" & @CRLF
	$sPS &= "        $ssl = New-Object System.Net.Security.SslStream($netStream, $false)" & @CRLF
	$sPS &= "        $ssl.AuthenticateAsClient($ServerAddress, $null, (Get-TlsProtocols), $false)" & @CRLF
	$sPS &= "        $stream = $ssl" & @CRLF
	$sPS &= "        $tlsActive = $true" & @CRLF
	$sPS &= "        Write-RelayLog ""Implicit TLS negotiated successfully ($($ssl.SslProtocol)).""" & @CRLF
	$sPS &= "    } catch {" & @CRLF
	$sPS &= "        Write-RelayLogError ""Implicit TLS failed: $($_.Exception.Message)""" & @CRLF
	$sPS &= "        exit 1" & @CRLF
	$sPS &= "    }" & @CRLF
	$sPS &= "}" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 3) Wire up this process's own standard input/output. AutoIt writes" & @CRLF
	$sPS &= "#    SMTP command bytes to our stdin and reads server response bytes" & @CRLF
	$sPS &= "#    from our stdout (see _Upstream_Write / StdoutRead in the AutoIt" & @CRLF
	$sPS &= "#    script)." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "$stdin  = [Console]::OpenStandardInput()" & @CRLF
	$sPS &= "$stdout = [Console]::OpenStandardOutput()" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 4) Asynchronous stdin reading (no background thread/runspace needed)." & @CRLF
	$sPS &= "#    Stream.ReadAsync() starts a read operation and immediately returns" & @CRLF
	$sPS &= "#    a Task we can poll for completion from the SAME thread/runspace as" & @CRLF
	$sPS &= "#    the main loop below - see the big comment near the top of this file" & @CRLF
	$sPS &= "#    for why this replaced an earlier Task.Run()/[Action]-delegate based" & @CRLF
	$sPS &= "#    background-thread design." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "$stdinBuffer = New-Object byte[] 65536" & @CRLF
	$sPS &= "$stdinReadTask = $stdin.ReadAsync($stdinBuffer, 0, $stdinBuffer.Length)" & @CRLF
	$sPS &= "$stdinDone = $false" & @CRLF
	$sPS &= "Write-RelayLogVerbose ""First asynchronous stdin read started.""" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# Accumulates plain-text bytes received from AutoIt that have not yet" & @CRLF
	$sPS &= "# been split into complete lines. Only used BEFORE the TLS upgrade, to" & @CRLF
	$sPS &= "# scan for the Sentinel line - see below. Once TLS is active, raw bytes" & @CRLF
	$sPS &= "# are forwarded to the server immediately without any line buffering" & @CRLF
	$sPS &= "# (needed for binary-safe message body relay)." & @CRLF
	$sPS &= "$pendingText = ''" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# Server -> AutoIt reading uses two different strategies depending on" & @CRLF
	$sPS &= "# $tlsActive - see the ""direction 1"" section of the main loop below for" & @CRLF
	$sPS &= "# why. $serverReadTask stays `$null until the TLS-active strategy starts" & @CRLF
	$sPS &= "# it for the first time." & @CRLF
	$sPS &= "$serverReadTask = $null" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 5) Main relay loop: runs until the TCP connection closes." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "$totalToServer = 0     # byte totals for the final log line" & @CRLF
	$sPS &= "$totalFromServer = 0" & @CRLF
	$sPS &= "while ($client.Connected) {" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    # Tracks whether EITHER direction made real progress this iteration -" & @CRLF
	$sPS &= "    # see the conditional Start-Sleep at the end of the loop for why:" & @CRLF
	$sPS &= "    # sleeping unconditionally on every iteration, even ones that just" & @CRLF
	$sPS &= "    # drained data that was already fully available, was found to add up" & @CRLF
	$sPS &= "    # to a real, measurable slowdown for larger messages - see the" & @CRLF
	$sPS &= "    # RelayPollMs INI setting's own comment in " & $g_sAppName & ".au3." & @CRLF
	$sPS &= "    $anyActivity = $false" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    # --- direction 1: server -> stdout (-> AutoIt) ---" & @CRLF
	$sPS &= "    try {" & @CRLF
	$sPS &= "        if (-not $tlsActive) {" & @CRLF
	$sPS &= "            # Before the TLS upgrade, $stream IS $netStream (the plain" & @CRLF
	$sPS &= "            # TCP stream), so DataAvailable correctly reflects whether" & @CRLF
	$sPS &= "            # $stream.Read() has data ready." & @CRLF
	$sPS &= "            if ($netStream.DataAvailable) {" & @CRLF
	$sPS &= "                $buf2 = New-Object byte[] 16384" & @CRLF
	$sPS &= "                $n2 = $stream.Read($buf2, 0, $buf2.Length)" & @CRLF
	$sPS &= "                if ($n2 -gt 0) {" & @CRLF
	$sPS &= "                    Write-RelayLogVerbose ""Server -> AutoIt: $n2 byte(s).""" & @CRLF
	$sPS &= "                    $stdout.Write($buf2, 0, $n2)" & @CRLF
	$sPS &= "                    $totalFromServer += $n2" & @CRLF
	$sPS &= "                    $stdout.Flush()" & @CRLF
	$sPS &= "                    $anyActivity = $true" & @CRLF
	$sPS &= "                } elseif ($n2 -eq 0) {" & @CRLF
	$sPS &= "                    # 0 bytes read = the remote end closed the connection." & @CRLF
	$sPS &= "                    Write-RelayLog ""Server closed the connection (0 bytes read).""" & @CRLF
	$sPS &= "                    break" & @CRLF
	$sPS &= "                }" & @CRLF
	$sPS &= "            }" & @CRLF
	$sPS &= "        } else {" & @CRLF
	$sPS &= "            # Once TLS is active, $stream is the SslStream, and" & @CRLF
	$sPS &= "            # $netStream.DataAvailable no longer reliably predicts" & @CRLF
	$sPS &= "            # whether a read on it has data ready - SslStream does its" & @CRLF
	$sPS &= "            # own internal buffering/decryption of TLS records that" & @CRLF
	$sPS &= "            # DataAvailable (which only sees the raw, still-encrypted" & @CRLF
	$sPS &= "            # socket buffer) cannot see, so a read can have data ready" & @CRLF
	$sPS &= "            # even when DataAvailable reports false - this was the bug" & @CRLF
	$sPS &= "            # that made a connection go silent forever right after" & @CRLF
	$sPS &= "            # ""TLS upgrade successful."" appeared in this log with" & @CRLF
	$sPS &= "            # nothing after it. Poll via ReadAsync instead, started" & @CRLF
	$sPS &= "            # fresh here the first time this branch runs after the" & @CRLF
	$sPS &= "            # upgrade ($serverReadTask stays $null until then - see" & @CRLF
	$sPS &= "            # its own initialisation further up - so nothing else is" & @CRLF
	$sPS &= "            # reading from $stream yet at that point, since the" & @CRLF
	$sPS &= "            # upgrade itself, including the AuthenticateAsClient()" & @CRLF
	$sPS &= "            # handshake, already fully completed by the time control" & @CRLF
	$sPS &= "            # gets back here on a later loop iteration - a NetworkStream" & @CRLF
	$sPS &= "            # does not support a second, concurrent read while one is" & @CRLF
	$sPS &= "            # already outstanding, which is exactly why this waits" & @CRLF
	$sPS &= "            # until then rather than trying to keep an async read" & @CRLF
	$sPS &= "            # running continuously across the upgrade itself)." & @CRLF
	$sPS &= "            if (-not $serverReadTask) {" & @CRLF
	$sPS &= "                $serverBuffer = New-Object byte[] 16384" & @CRLF
	$sPS &= "                $serverReadTask = $stream.ReadAsync($serverBuffer, 0, $serverBuffer.Length)" & @CRLF
	$sPS &= "            } elseif ($serverReadTask.IsCompleted) {" & @CRLF
	$sPS &= "                if ($serverReadTask.IsFaulted) {" & @CRLF
	$sPS &= "                    $exMsg = $serverReadTask.Exception.InnerException.Message" & @CRLF
	$sPS &= "                    Write-RelayLogError ""Error reading from server (async): $exMsg""" & @CRLF
	$sPS &= "                    break" & @CRLF
	$sPS &= "                }" & @CRLF
	$sPS &= "                $n2 = $serverReadTask.Result" & @CRLF
	$sPS &= "                if ($n2 -gt 0) {" & @CRLF
	$sPS &= "                    Write-RelayLogVerbose ""Server -> AutoIt: $n2 byte(s).""" & @CRLF
	$sPS &= "                    $stdout.Write($serverBuffer, 0, $n2)" & @CRLF
	$sPS &= "                    $totalFromServer += $n2" & @CRLF
	$sPS &= "                    $stdout.Flush()" & @CRLF
	$sPS &= "                    $anyActivity = $true" & @CRLF
	$sPS &= "                } elseif ($n2 -eq 0) {" & @CRLF
	$sPS &= "                    Write-RelayLog ""Server closed the connection (0 bytes read).""" & @CRLF
	$sPS &= "                    break" & @CRLF
	$sPS &= "                }" & @CRLF
	$sPS &= "                $serverBuffer = New-Object byte[] 16384" & @CRLF
	$sPS &= "                $serverReadTask = $stream.ReadAsync($serverBuffer, 0, $serverBuffer.Length)" & @CRLF
	$sPS &= "            }" & @CRLF
	$sPS &= "        }" & @CRLF
	$sPS &= "    } catch {" & @CRLF
	$sPS &= "        # Any read/TLS error on this side - treat as connection lost." & @CRLF
	$sPS &= "        Write-RelayLogError ""Error reading from server: $($_.Exception.Message)""" & @CRLF
	$sPS &= "        break" & @CRLF
	$sPS &= "    }" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    # --- direction 2: AutoIt (stdin) -> server ---" & @CRLF
	$sPS &= "    if (-not $stdinDone -and $stdinReadTask.IsCompleted) {" & @CRLF
	$sPS &= "        if ($stdinReadTask.IsFaulted) {" & @CRLF
	$sPS &= "            $exMsg = $stdinReadTask.Exception.InnerException.Message" & @CRLF
	$sPS &= "            Write-RelayLogError ""Error during asynchronous stdin read: $exMsg""" & @CRLF
	$sPS &= "            $stdinDone = $true" & @CRLF
	$sPS &= "        } else {" & @CRLF
	$sPS &= "            $n = $stdinReadTask.Result" & @CRLF
	$sPS &= "            if ($n -le 0) {" & @CRLF
	$sPS &= "                Write-RelayLog ""stdin returned 0 bytes - AutoIt closed the pipe.""" & @CRLF
	$sPS &= "                $stdinDone = $true" & @CRLF
	$sPS &= "            } else {" & @CRLF
	$sPS &= "                $chunk2 = New-Object byte[] $n" & @CRLF
	$sPS &= "                [Array]::Copy($stdinBuffer, 0, $chunk2, 0, $n)" & @CRLF
	$sPS &= "                Write-RelayLogVerbose ""AutoIt -> Relay: $n byte(s) received via ReadAsync.""" & @CRLF
	$sPS &= "                $anyActivity = $true" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "                try {" & @CRLF
	$sPS &= "                    if (-not $tlsActive) {" & @CRLF
	$sPS &= "                        # Still plain text (pre-STARTTLS): decode as ASCII (SMTP" & @CRLF
	$sPS &= "                        # commands are always 7-bit ASCII at this stage) and scan" & @CRLF
	$sPS &= "                        # line-by-line for the Sentinel marker." & @CRLF
	$sPS &= "                        $pendingText += [System.Text.Encoding]::ASCII.GetString($chunk2)" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "                        while ($pendingText.IndexOf([char]10) -ge 0) {" & @CRLF
	$sPS &= "                            # [char]10 = LF; AutoIt always terminates lines with" & @CRLF
	$sPS &= "                            # CRLF, so the extracted line still ends with a" & @CRLF
	$sPS &= "                            # trailing CR, which is fine for SMTP." & @CRLF
	$sPS &= "                            $idx = $pendingText.IndexOf([char]10)" & @CRLF
	$sPS &= "                            $line = $pendingText.Substring(0, $idx + 1)" & @CRLF
	$sPS &= "                            $pendingText = $pendingText.Substring($idx + 1)" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "                            if ($line.Trim() -eq $Sentinel) {" & @CRLF
	$sPS &= "                                # This is not real SMTP traffic - it is AutoIt's" & @CRLF
	$sPS &= "                                # request to upgrade the connection to TLS now" & @CRLF
	$sPS &= "                                # (equivalent to the client side of STARTTLS)." & @CRLF
	$sPS &= "                                # Wrap the EXISTING TCP socket ($netStream) in a" & @CRLF
	$sPS &= "                                # new SslStream and perform the handshake; from" & @CRLF
	$sPS &= "                                # this point on, $stream (and both directions of" & @CRLF
	$sPS &= "                                # this loop) operate on the encrypted stream." & @CRLF
	$sPS &= "                                Write-RelayLog ""Sentinel received - starting TLS upgrade (STARTTLS).""" & @CRLF
	$sPS &= "                                $ssl = New-Object System.Net.Security.SslStream($netStream, $false)" & @CRLF
	$sPS &= "                                $ssl.AuthenticateAsClient($ServerAddress, $null, (Get-TlsProtocols), $false)" & @CRLF
	$sPS &= "                                $stream = $ssl" & @CRLF
	$sPS &= "                                $tlsActive = $true" & @CRLF
	$sPS &= "                                Write-RelayLog ""TLS upgrade successful ($($ssl.SslProtocol)).""" & @CRLF
	$sPS &= "                            } else {" & @CRLF
	$sPS &= "                                # Ordinary SMTP command line - forward it to the" & @CRLF
	$sPS &= "                                # server unchanged." & @CRLF
	$sPS &= "                                Write-RelayLog ""Sending plain-text line to server: $($line.Trim())""" & @CRLF
	$sPS &= "                                $lineBytes = [System.Text.Encoding]::ASCII.GetBytes($line)" & @CRLF
	$sPS &= "                                $stream.Write($lineBytes, 0, $lineBytes.Length)" & @CRLF
	$sPS &= "                                $totalToServer += $lineBytes.Length" & @CRLF
	$sPS &= "                                $stream.Flush()" & @CRLF
	$sPS &= "                                Write-RelayLogVerbose ""Line sent ($($lineBytes.Length) bytes).""" & @CRLF
	$sPS &= "                            }" & @CRLF
	$sPS &= "                        }" & @CRLF
	$sPS &= "                    } else {" & @CRLF
	$sPS &= "                        # TLS already active: relay raw bytes straight through," & @CRLF
	$sPS &= "                        # with NO text/line parsing at all. This is essential once" & @CRLF
	$sPS &= "                        # the SMTP DATA phase begins, since the message body can" & @CRLF
	$sPS &= "                        # contain arbitrary 8-bit/binary MIME content that must" & @CRLF
	$sPS &= "                        # not be interpreted as text." & @CRLF
	$sPS &= "                        $stream.Write($chunk2, 0, $chunk2.Length)" & @CRLF
	$sPS &= "                        $totalToServer += $chunk2.Length" & @CRLF
	$sPS &= "                        $stream.Flush()" & @CRLF
	$sPS &= "                        Write-RelayLogVerbose ""Raw data sent ($($chunk2.Length) bytes, TLS active).""" & @CRLF
	$sPS &= "                    }" & @CRLF
	$sPS &= "                } catch {" & @CRLF
	$sPS &= "                    Write-RelayLogError ""Error sending to server: $($_.Exception.Message)""" & @CRLF
	$sPS &= "                    break" & @CRLF
	$sPS &= "                }" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "                # Start the next asynchronous read so the following chunk (if" & @CRLF
	$sPS &= "                # any) is picked up on a later loop iteration. 65536 to match" & @CRLF
	$sPS &= "                # AutoIt's own TCPRecv() buffer size on the client side (see" & @CRLF
	$sPS &= "                # _PumpConnection()) - this used to be a much smaller 8192," & @CRLF
	$sPS &= "                # meaning a single large write from AutoIt could take 8+" & @CRLF
	$sPS &= "                # separate reads (and, before $anyActivity existed above, 8+" & @CRLF
	$sPS &= "                # full RelayPollMs sleeps) to fully drain here, even though" & @CRLF
	$sPS &= "                # the rest of it was already sitting in the pipe the whole time." & @CRLF
	$sPS &= "                $stdinBuffer = New-Object byte[] 65536" & @CRLF
	$sPS &= "                $stdinReadTask = $stdin.ReadAsync($stdinBuffer, 0, $stdinBuffer.Length)" & @CRLF
	$sPS &= "            }" & @CRLF
	$sPS &= "        }" & @CRLF
	$sPS &= "    }" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    if ($stdinDone) {" & @CRLF
	$sPS &= "        Write-RelayLog ""stdin closed - stopping relay.""" & @CRLF
	$sPS &= "        break" & @CRLF
	$sPS &= "    }" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "    # Only sleep when this iteration genuinely found nothing to do on" & @CRLF
	$sPS &= "    # either side ($anyActivity, set above) - a message actively being" & @CRLF
	$sPS &= "    # relayed keeps this loop spinning at full speed for as long as data" & @CRLF
	$sPS &= "    # keeps arriving, rather than adding a fixed RelayPollMs delay after" & @CRLF
	$sPS &= "    # every single chunk regardless of whether more was already waiting." & @CRLF
	$sPS &= "    # Tunable via the 'RelayPollMs' INI setting under [General] (see" & @CRLF
	$sPS &= "    # _LoadGeneralSettings() in " & $g_sAppName & ".au3) - baked into this" & @CRLF
	$sPS &= "    # generated script at startup, so a changed value only takes effect" & @CRLF
	$sPS &= "    # after a restart. Trade-off worth knowing: this process can now use a" & @CRLF
	$sPS &= "    # full CPU core for the whole duration of an actively relayed transfer" & @CRLF
	$sPS &= "    # instead of yielding periodically - acceptable here since it is a" & @CRLF
	$sPS &= "    # short-lived, one-per-connection helper, not a persistent service." & @CRLF
	$sPS &= "    if (-not $anyActivity) {" & @CRLF
	$sPS &= "        Start-Sleep -Milliseconds " & $g_iRelayPollMs & @CRLF
	$sPS &= "    }" & @CRLF
	$sPS &= "}" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "Write-RelayLog ""Main loop ended (sent to server: $totalToServer bytes, received from server: $totalFromServer bytes).""" & @CRLF
	$sPS &= "" & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "# 6) Clean up. AutoIt is responsible for terminating this process" & @CRLF
	$sPS &= "#    (ProcessClose) if it is still alive at this point for any reason;" & @CRLF
	$sPS &= "#    this just makes sure the socket itself is released promptly." & @CRLF
	$sPS &= "# ---------------------------------------------------------------------" & @CRLF
	$sPS &= "try { $client.Close() } catch {}" & @CRLF

	Local $hFile = FileOpen($g_sRelayScriptPath, 2)
	If $hFile = -1 Then
		LogFile("Error: could not open '" & $g_sRelayScriptPath & "' for writing (locked by another process? " & _
				"missing folder permissions?) - proxied connections will fail or use a stale/outdated version " & _
				"of this file until the problem is fixed and " & $g_sAppName & " is restarted.")
		Return
	EndIf

	Local $bWriteOk = FileWrite($hFile, $sPS)
	FileClose($hFile)

	If Not $bWriteOk Then
		LogFile("Error: writing '" & $g_sRelayScriptPath & "' failed (FileWrite reported failure) - the file may " & _
				"now be incomplete or corrupt; proxied connections may fail until this is fixed and " & _
				$g_sAppName & " is restarted.")
	EndIf
EndFunc   ;==>_EnsureRelayHelperScript

; ############################################################################
; #  OAUTH2
; ############################################################################

; ============================================================================
; _BuildXOAuth2String
; ----------------------------------------------------------------------------
; Description : Builds the base64-encoded SASL XOAUTH2 credential string, in
;               the exact format expected by IMAP/POP/SMTP servers:
;               "user=<user>\x01auth=Bearer <token>\x01\x01", base64-encoded.
; Parameters  : $sUsername    - Mailbox username (usually the e-mail address).
;               $sAccessToken - Valid OAuth2 access (bearer) token.
; Returns     : The base64-encoded XOAUTH2 string, ready to be sent as-is
;               after the server's "334" continuation prompt.
; ============================================================================
Func _BuildXOAuth2String($sUsername, $sAccessToken)
	Local $sRaw = "user=" & $sUsername & Chr(1) & "auth=Bearer " & $sAccessToken & Chr(1) & Chr(1)
	Return _Base64Encode(StringToBinary($sRaw, 4))
EndFunc   ;==>_BuildXOAuth2String

; ============================================================================
; _GetProviderPreset
; ----------------------------------------------------------------------------
; Description : Returns the well-known OAuth2 endpoint / SMTP server
;               defaults for a given provider, used to pre-fill the "Add
;               account" dialog. For an unknown/"custom" provider, returns
;               empty endpoint URLs and generic STARTTLS-on-587 defaults
;               that the user has to fill in themselves. For Microsoft, the
;               PermissionURL/TokenURL use the multi-tenant "/common/" path
;               segment by default; _ShowAddAccountDialog() replaces
;               "/common/" with the specific tenant ID/domain the user
;               entered, if any (see its "Directory (tenant) ID" field) - this
;               function itself always returns the generic "/common/" form.
; Parameters  : $sProvider - One of "microsoft", "google", or anything else
;               (treated as "custom").
; Returns     : A 7-element array:
;                 [0] PermissionURL (OAuth2 authorization endpoint)
;                 [1] TokenURL      (OAuth2 token endpoint)
;                 [2] Scope         (space-separated OAuth2 scopes)
;                 [3] ServerAddress (default SMTP server hostname)
;                 [4] ServerPort    (default SMTP server port)
;                 [5] ServerSTARTTLS (1 = use STARTTLS, 0 = implicit TLS)
;                 [6] UsePKCE       (1 = use PKCE code_challenge, else 0) -
;                 both providers default to 1: PKCE is the current
;                 recommended practice for public/native clients with
;                 both Microsoft Entra ID and Google (which deprecated its
;                 old copy-paste "out-of-band" flow in favour of PKCE for
;                 installed apps around 2022) - it works the same way for
;                 either provider in this script, since PKCE itself is
;                 provider-agnostic (see _Auth_BuildPermissionUrl() /
;                 _Auth_ExchangeCode()).
; ============================================================================
Func _GetProviderPreset($sProvider)
	Local $a[7]
	Switch $sProvider
		Case "microsoft"
			$a[0] = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
			$a[1] = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
			$a[2] = "https://outlook.office.com/SMTP.Send offline_access"
			$a[3] = "smtp-mail.outlook.com"
			$a[4] = 587
			$a[5] = 1
			$a[6] = 1
		Case "google"
			$a[0] = "https://accounts.google.com/o/oauth2/auth"
			$a[1] = "https://oauth2.googleapis.com/token"
			$a[2] = "https://mail.google.com/"
			$a[3] = "smtp.gmail.com"
			$a[4] = 465
			$a[5] = 0
			$a[6] = 1
		Case Else
			$a[0] = ""
			$a[1] = ""
			$a[2] = ""
			$a[3] = ""
			$a[4] = 587
			$a[5] = 1
			$a[6] = 0
	EndSwitch
	Return $a
EndFunc   ;==>_GetProviderPreset

; ============================================================================
; _Auth_BuildPermissionUrl
; ----------------------------------------------------------------------------
; Description : Builds the full OAuth2 "authorize" URL to open in the
;               user's browser for the interactive sign-in/consent step
;               (authorization-code grant), including the PKCE
;               code_challenge when applicable.
;               For Google, "prompt=consent" is added, because Google only
;               issues a new refresh token when the consent is given again.
; Parameters  : $oAcc           - Account dictionary (must contain
;               "PermissionURL", "ClientID", "RedirectURI", "Scope",
;               "Username").
;               $sState         - Random, unguessable state value used to
;               validate the redirect callback (CSRF protection).
;               $sCodeChallenge - PKCE code_challenge (S256), or "" to
;               disable PKCE for this request.
; Returns     : The complete authorization URL, ready to pass to
;               ShellExecute().
; ============================================================================
Func _Auth_BuildPermissionUrl($oAcc, $sState, $sCodeChallenge)
	Local $sUrl = $oAcc.Item("PermissionURL")
	$sUrl &= "?client_id=" & _URLEncode($oAcc.Item("ClientID"))
	$sUrl &= "&redirect_uri=" & _URLEncode($oAcc.Item("RedirectURI"))
	$sUrl &= "&scope=" & _URLEncode($oAcc.Item("Scope"))
	$sUrl &= "&response_type=code"
	$sUrl &= "&access_type=offline"
	$sUrl &= "&login_hint=" & _URLEncode($oAcc.Item("Username"))
	$sUrl &= "&state=" & _URLEncode($sState)
	; C4: Google only issues a new refresh token when consent is given again
	If $oAcc.Item("Provider") = "google" Then $sUrl &= "&prompt=consent"
	If $sCodeChallenge <> "" Then
		$sUrl &= "&code_challenge=" & _URLEncode($sCodeChallenge)
		$sUrl &= "&code_challenge_method=S256"
	EndIf
	Return $sUrl
EndFunc   ;==>_Auth_BuildPermissionUrl

; ============================================================================
; _Auth_WaitForRedirect
; ----------------------------------------------------------------------------
; Description : Blocking (with a 180-second overall timeout), self-contained
;               local mini HTTP server that waits for the browser to
;               redirect back after the user has signed in / consented.
;               Only ever used from the interactive sign-in wizard (never
;               from the main loop) - calls _ServiceConnections() once per
;               poll iteration (roughly every 50ms) so a sign-in attempt
;               left sitting at the browser does not stop the proxy from
;               accepting or relaying mail for however long that takes;
;               see _ServiceConnections()'s header comment for why that
;               matters. Parses "code" and "state" from the redirect's
;               query string, validates the state against
;               $sExpectedState, and replies to the browser with a small
;               HTML page. If the provider instead redirected back with
;               "error"/"error_description" (e.g. AADSTS50194,
;               access_denied, ...), that is parsed too, shown to the user
;               directly in the browser instead of the generic success
;               message, and returned via $sErrorOut so the caller can
;               show/log the real reason instead of a generic "no
;               response received" message.
; Parameters  : $iPort          - Local TCP port to listen on (must match
;               the port encoded in the account's RedirectURI).
;               $sExpectedState - The state value that must match for the
;               code to be accepted (pass "" to skip this check).
;               $sErrorOut      - ByRef: set to "" on success/timeout, or to
;               "<error>: <error_description>" (URL-decoded) if the provider
;               redirected back with an error instead of a code.
; Returns     : The received (and URL-decoded) authorization code, or "" if
;               no valid redirect was received before the timeout expired,
;               the port could not be opened, or the provider reported an
;               error (see $sErrorOut in that case).
; ============================================================================
Func _Auth_WaitForRedirect($iPort, $sExpectedState, ByRef $sErrorOut)
	$sErrorOut = ""
	Local $iListenSocket = TCPListen("127.0.0.1", $iPort, 5)
	If $iListenSocket = -1 Then Return ""

	Local $iTimeoutAt = _UnixTimeNow() + $g_iAuthRedirectTimeoutSec
	Local $sCode = ""

	While _UnixTimeNow() < $iTimeoutAt And $sCode = "" And $sErrorOut = ""
		Local $iClient = TCPAccept($iListenSocket)
		If $iClient <> -1 Then
			Local $sRequest = ""
			Local $iWait = 0
			While $iWait < 100
				Local $sChunk = TCPRecv($iClient, 8192)
				If $sChunk <> "" Then $sRequest &= $sChunk
				If StringInStr($sRequest, @CRLF & @CRLF) Then ExitLoop
				Sleep(20)
				$iWait += 1
			WEnd

			Local $sReceivedCode = ""
			Local $sReceivedState = ""
			Local $sReceivedError = ""
			Local $sReceivedErrorDesc = ""

			Local $aMatch = StringRegExp($sRequest, "^GET\s+\S*[?&]code=([^&\s]+)", 1)
			If Not @error Then $sReceivedCode = $aMatch[0]
			$aMatch = StringRegExp($sRequest, "[?&]state=([^&\s]+)", 1)
			If Not @error Then $sReceivedState = $aMatch[0]
			$aMatch = StringRegExp($sRequest, "[?&]error=([^&\s]+)", 1)
			If Not @error Then $sReceivedError = _URLDecode($aMatch[0])
			$aMatch = StringRegExp($sRequest, "[?&]error_description=([^&\s]+)", 1)
			If Not @error Then $sReceivedErrorDesc = _URLDecode($aMatch[0])

			Local $sHtml = ""
			If $sReceivedError <> "" Then
				Local $sSafeDesc = StringReplace($sReceivedErrorDesc, "<", "&lt;")
				$sSafeDesc = StringReplace($sSafeDesc, ">", "&gt;")
				Local $sSafeError = StringReplace($sReceivedError, "<", "&lt;")
				$sSafeError = StringReplace($sSafeError, ">", "&gt;")
				$sHtml = "<html><head><meta charset='utf-8'><title>Sign-in failed</title></head>" & _
						"<body style='font-family:sans-serif'><p><b>Sign-in failed:</b> " & $sSafeError & _
						"</p><p style='white-space:pre-wrap'>" & $sSafeDesc & "</p>" & _
						"<p>You can close this window now and try again in the tool.</p></body></html>"
			Else
				$sHtml = "<html><head><meta charset='utf-8'><title>Sign-in complete</title></head>" & _
						"<body style='font-family:sans-serif'><p>Sign-in complete. You can close this window " & _
						"now.</p></body></html>"
			EndIf

			; Content-Length must be the UTF-8 BYTE length, not the AutoIt
			; character count (StringLen), since umlauts encode to 2 bytes
			Local $sHttpResp = "HTTP/1.1 200 OK" & @CRLF & "Content-Type: text/html; charset=utf-8" & @CRLF & _
					"Content-Length: " & BinaryLen(StringToBinary($sHtml, 4)) & @CRLF & "Connection: close" & @CRLF & @CRLF & $sHtml
			TCPSend($iClient, StringToBinary($sHttpResp, 4))
			Sleep(50)
			TCPCloseSocket($iClient)

			If $sReceivedCode <> "" Then
				If $sExpectedState = "" Or $sReceivedState = $sExpectedState Then
					$sCode = _URLDecode($sReceivedCode)
				EndIf
			ElseIf $sReceivedError <> "" Then
				$sErrorOut = $sReceivedError
				If $sReceivedErrorDesc <> "" Then $sErrorOut &= ": " & $sReceivedErrorDesc
			EndIf
		EndIf
		If Not _ServiceConnections() Then Sleep(50)
	WEnd

	TCPCloseSocket($iListenSocket)
	Return $sCode
EndFunc   ;==>_Auth_WaitForRedirect

; ============================================================================
; _Auth_ExchangeCode
; ----------------------------------------------------------------------------
; Description : Exchanges an OAuth2 authorization code for an access token
;               and (usually) a refresh token, via an
;               "authorization_code" grant POST to the token endpoint. On
;               success, stores the tokens (DPAPI-encrypted) via
;               _SaveTokens().
;               If the response contains no refresh token, a warning is
;               logged (the sign-in then only lasts as long as the access
;               token, about an hour); a previously stored refresh token is
;               kept in that case.
; Parameters  : $oAcc          - Account dictionary (must contain
;               "ClientID", "RedirectURI", "ClientSecret", "TokenURL").
;               $sCode         - Authorization code received from
;               _Auth_WaitForRedirect().
;               $sCodeVerifier - PKCE code_verifier matching the
;               code_challenge sent earlier, or "" if PKCE was not used.
; Returns     : True on success (tokens saved), False on failure (details
;               written to the log file).
; ============================================================================
Func _Auth_ExchangeCode($oAcc, $sCode, $sCodeVerifier)
	Local $aParams[6][2]
	$aParams[0][0] = "client_id"
	$aParams[0][1] = $oAcc.Item("ClientID")
	$aParams[1][0] = "code"
	$aParams[1][1] = $sCode
	$aParams[2][0] = "redirect_uri"
	$aParams[2][1] = $oAcc.Item("RedirectURI")
	$aParams[3][0] = "grant_type"
	$aParams[3][1] = "authorization_code"
	$aParams[4][0] = "client_secret"
	$aParams[4][1] = $oAcc.Item("ClientSecret")
	$aParams[5][0] = "code_verifier"
	$aParams[5][1] = $sCodeVerifier

	Local $sBody = _BuildFormBody($aParams)
	Local $iStatus = 0
	Local $sResp = _HttpPostForm($oAcc.Item("TokenURL"), $sBody, $iStatus)

	If $iStatus <> 200 Then
		LogFile("Error fetching token (" & $oAcc.Item("Username") & "): HTTP " & $iStatus & " - " & $sResp)
		Return False
	EndIf

	Local $sAccessToken = _JsonGetString($sResp, "access_token")
	Local $sRefreshToken = _JsonGetString($sResp, "refresh_token")
	Local $iExpiresIn = _JsonGetNumber($sResp, "expires_in")
	If $iExpiresIn <= 0 Then $iExpiresIn = 3600

	If $sAccessToken = "" Then
		LogFile("Error: no access token received in response for " & $oAcc.Item("Username"))
		Return False
	EndIf

	; C5: without a refresh token the sign-in only lasts as long as this
	; access token (about an hour).
	If $sRefreshToken = "" Then
		If $oAcc.Item("RefreshToken") <> "" Then
			LogFile("Warning: the sign-in for " & $oAcc.Item("Username") & " returned no new refresh token - the previously stored one is kept.")
		Else
			LogFile("Warning: the sign-in for " & $oAcc.Item("Username") & " returned no refresh token - sending will stop working when " & _
					"the access token expires (about " & Round($iExpiresIn / 60) & " min). Check the scope (Microsoft: offline_access) " & _
					"or grant the consent again (Google).")
		EndIf
	EndIf
	_SaveTokens($oAcc, $sAccessToken, $sRefreshToken, _UnixTimeNow() + $iExpiresIn)
	Return True
EndFunc   ;==>_Auth_ExchangeCode

; ============================================================================
; _Auth_RefreshToken
; ----------------------------------------------------------------------------
; Description : Obtains a fresh access token using the stored refresh
;               token, via a "refresh_token" grant POST to the token
;               endpoint. Some providers rotate the refresh token on every
;               use; if a new one is present in the response it is saved
;               as well. Only when the provider answers with the error
;               "invalid_grant" (refresh token invalid, revoked or
;               expired) does this flag the account as needing
;               re-authentication AND clears the now-invalid tokens both
;               in memory and in the INI file (RefreshTokenEnc/
;               AccessTokenEnc) - clearing RefreshTokenEnc specifically
;               matters because _LoadAllListeners() derives NeedsReauth
;               purely from whether that key exists, so leaving it behind
;               would make the "needs re-authentication" state silently
;               revert to "signed in" the next time anything reloads the
;               configuration (which happens on almost every Settings
;               action), even though the token is provably dead.
;               Every refresh is logged at any log level - a start line
;               (with what triggered it and how long the old token was
;               still valid) and a result line (with the duration) - so
;               refreshes can be matched in time against other events in
;               the log (e.g. a client that got no answer): the HTTPS call
;               blocks the whole program while it runs.
;               Other errors - e.g. "invalid_client" (client secret expired)
;               or a temporary problem - keep the stored sign-in, so it works
;               again once the cause is fixed; they are only logged (with a
;               hint for invalid_client). A success resets the retry backoff
;               of _ProactiveTokenRefresh().
; Parameters  : $oAcc     - Account dictionary (must contain "RefreshToken",
;               "ClientID", "ClientSecret", "TokenURL").
;               $sTrigger - What caused the refresh, for the log
;               ("proactive" or "on demand").
; Returns     : True on success (new tokens saved via _SaveTokens), False
;               on failure (details written to the log file).
; ============================================================================
Func _Auth_RefreshToken($oAcc, $sTrigger = "on demand")
	Local $sRefreshToken = $oAcc.Item("RefreshToken")
	If $sRefreshToken = "" Then Return False

	Local $iOldValidSec = Number($oAcc.Item("AccessTokenExpiry")) - _UnixTimeNow()
	Local $sOldValid = "old access token still valid for " & $iOldValidSec & " s"
	If Number($oAcc.Item("AccessTokenExpiry")) <= 0 Then
		$sOldValid = "no access token known yet"
	ElseIf $iOldValidSec <= 0 Then
		$sOldValid = "old access token expired " & (-$iOldValidSec) & " s ago"
	EndIf
	LogFile("Token refresh for " & $oAcc.Item("Username") & " started (" & $sTrigger & ", " & $sOldValid & ").")
	Local $hRefreshTimer = TimerInit()

	Local $aParams[4][2]
	$aParams[0][0] = "client_id"
	$aParams[0][1] = $oAcc.Item("ClientID")
	$aParams[1][0] = "client_secret"
	$aParams[1][1] = $oAcc.Item("ClientSecret")
	$aParams[2][0] = "refresh_token"
	$aParams[2][1] = $sRefreshToken
	$aParams[3][0] = "grant_type"
	$aParams[3][1] = "refresh_token"

	Local $sBody = _BuildFormBody($aParams)
	Local $iStatus = 0
	Local $sResp = _HttpPostForm($oAcc.Item("TokenURL"), $sBody, $iStatus)

	If $iStatus <> 200 Then
		LogFile("Token refresh failed (" & $oAcc.Item("Username") & ") after " & _FormatDurationMs(Round(TimerDiff($hRefreshTimer))) & _
				": HTTP " & $iStatus & " - " & $sResp)
				_StatsNoteError("token refresh failed (HTTP " & $iStatus & ")") ; E8
		; C1: only "invalid_grant" means the refresh token itself is dead
		; (revoked, expired, password changed, ...) - only then are the stored
		; tokens deleted and a new interactive sign-in required. Other errors,
		; such as "invalid_client" (e.g. an expired client secret) or a temporary
		; problem on the provider's side, leave the sign-in in place, so it works
		; again as soon as the cause is fixed.
		Local $sErrCode = _JsonGetString($sResp, "error")
		If $sErrCode = "invalid_grant" Then
			$oAcc.Item("NeedsReauth") = True
			$oAcc.Item("RefreshToken") = ""
			$oAcc.Item("AccessToken") = ""
			IniDelete($g_sIniPath, $oAcc.Item("IniSection"), "RefreshTokenEnc")
			IniDelete($g_sIniPath, $oAcc.Item("IniSection"), "AccessTokenEnc")
			LogFile("Account " & $oAcc.Item("Username") & ": stored tokens cleared - re-authentication required.")
		Else
			If $sErrCode = "invalid_client" Then
				LogFile("Account " & $oAcc.Item("Username") & ": the provider no longer accepts this app registration's client ID or " & _
						"client secret (e.g. the client secret has expired) - correct it via Settings -> Edit. The stored sign-in is kept.")
			ElseIf $sErrCode <> "" Then
				LogFile("Account " & $oAcc.Item("Username") & ": error """ & $sErrCode & """ does not mean the sign-in itself is invalid - " & _
						"the stored tokens are kept and the refresh will be tried again.")
			EndIf
		EndIf
		; E1: "invalid_grant" = a new sign-in is needed; anything else is
		; reported from the second failure in a row on (one failure alone is
		; often only a short hiccup at the provider).
		If $sErrCode = "invalid_grant" Then
			_NotifyEvent("reauth", $oAcc.Item("Username"), "The sign-in is no longer valid (the provider answered ""invalid_grant"" - " & _
					"e.g. revoked, expired or the password was changed). Devices using this account cannot send e-mail until " & _
					"someone signs in again via the tray menu.")
		Else
			__NotifyRefreshFailed($oAcc, "HTTP " & $iStatus & StringStripWS(" " & $sErrCode, 2))
		EndIf
		Return False
	EndIf

	Local $sAccessToken = _JsonGetString($sResp, "access_token")
	Local $sNewRefresh = _JsonGetString($sResp, "refresh_token")
	Local $iExpiresIn = _JsonGetNumber($sResp, "expires_in")
	If $iExpiresIn <= 0 Then $iExpiresIn = 3600
	If $sAccessToken = "" Then
		LogFile("Token refresh failed (" & $oAcc.Item("Username") & ") after " & _FormatDurationMs(Round(TimerDiff($hRefreshTimer))) & _
				": HTTP 200, but the response contained no access token.")
		__NotifyRefreshFailed($oAcc, "HTTP 200 without an access token") ; E1
		Return False
	EndIf

	_SaveTokens($oAcc, $sAccessToken, $sNewRefresh, _UnixTimeNow() + $iExpiresIn)
	$oAcc.Item("RefreshFailCount") = 0 ; C3: reset the backoff after a success
	$oAcc.Item("RefreshRetryAt") = 0
	$oAcc.Item("NotifyRefreshFails") = 0 ; E1
	_NotifyResolved("refreshfail", $oAcc.Item("Username"), "The access token was renewed successfully.")
	Local $sRotated = ""
	If $sNewRefresh <> "" Then $sRotated = ", refresh token renewed as well"
	LogFile("Token refresh for " & $oAcc.Item("Username") & " succeeded after " & _FormatDurationMs(Round(TimerDiff($hRefreshTimer))) & _
			" - new access token valid for " & $iExpiresIn & " s" & $sRotated & ".")
	Return True
EndFunc   ;==>_Auth_RefreshToken

; E1: counts failed token renewals in a row and reports the second one.
Func __NotifyRefreshFailed($oAcc, $sWhy)
	Local $iFails = Number($oAcc.Item("NotifyRefreshFails")) + 1
	$oAcc.Item("NotifyRefreshFails") = $iFails
	If $iFails >= 2 Then _NotifyEvent("refreshfail", $oAcc.Item("Username"), "The access token could not be renewed " & $iFails & _
			" times in a row (last: " & $sWhy & "). E-mail from this account fails as soon as the current token runs out; " & _
			"the proxy keeps trying.")
EndFunc   ;==>__NotifyRefreshFailed

; ============================================================================
; _Auth_GetValidAccessToken
; ----------------------------------------------------------------------------
; Description : Returns a currently valid OAuth2 access token for the given
;               account, refreshing it first if necessary. Lazily decrypts
;               the refresh/access token from the INI file (via DPAPI) into
;               the in-memory account dictionary on first use. Triggers a
;               refresh via _Auth_RefreshToken() whenever no access token is
;               cached yet, or the cached one expires within the next 120
;               seconds.
;               If the refresh fails but the current access token is still
;               valid (and the sign-in was not invalidated), that token is
;               used for this connection instead of turning the client away.
; Parameters  : $oAcc - Account dictionary (must contain "IniSection",
;               "RefreshToken", "AccessToken", "AccessTokenExpiry").
; Returns     : A valid access token string, or "" if no valid token could
;               be obtained (e.g. the refresh token is invalid/revoked).
; ============================================================================
Func _Auth_GetValidAccessToken($oAcc)
	If $oAcc.Item("RefreshToken") = "" Then
		Local $sEnc = IniRead($g_sIniPath, $oAcc.Item("IniSection"), "RefreshTokenEnc", "")
		If $sEnc <> "" Then $oAcc.Item("RefreshToken") = _DPAPI_Unprotect($sEnc, "refresh token of " & $oAcc.Item("Username"))
	EndIf

	Local $sAccessToken = $oAcc.Item("AccessToken")
	If $sAccessToken = "" Then
		Local $sEnc2 = IniRead($g_sIniPath, $oAcc.Item("IniSection"), "AccessTokenEnc", "")
		If $sEnc2 <> "" Then
			$sAccessToken = _DPAPI_Unprotect($sEnc2, "access token of " & $oAcc.Item("Username"))
			$oAcc.Item("AccessToken") = $sAccessToken
		EndIf
	EndIf

	Local $iExpiry = Number($oAcc.Item("AccessTokenExpiry"))

	If $sAccessToken = "" Or ($iExpiry - _UnixTimeNow()) < 120 Then
		If Not _Auth_RefreshToken($oAcc) Then
			; C2: the refresh failed, but the current access token may still be
			; valid for a little while - use it rather than turning the client
			; away (but not after "invalid_grant", which removes the stored
			; sign-in and sets NeedsReauth).
			If $sAccessToken <> "" And Not $oAcc.Item("NeedsReauth") And ($iExpiry - _UnixTimeNow()) > 5 Then
				LogFile("Account " & $oAcc.Item("Username") & ": token refresh failed, but the current access token is still valid for " & _
						($iExpiry - _UnixTimeNow()) & " s - using it for this connection.")
				Return $sAccessToken
			EndIf
			Return ""
		EndIf
		$sAccessToken = $oAcc.Item("AccessToken")
	EndIf

	Return $sAccessToken
EndFunc   ;==>_Auth_GetValidAccessToken

; ============================================================================
; _SaveTokens
; ----------------------------------------------------------------------------
; Description : Persists a new access token (and, if provided, a new
;               refresh token) for an account: encrypts both via DPAPI and
;               writes them into the account's INI section, and updates the
;               in-memory account dictionary to match (including clearing
;               "NeedsReauth" once a refresh token is available again).
; Parameters  : $oAcc          - Account dictionary (must contain
;               "IniSection").
;               $sAccessToken  - New access token to store.
;               $sRefreshToken - New refresh token to store, or "" to leave
;               the previously stored refresh token untouched.
;               $iExpiry       - Unix timestamp (UTC) at which
;               $sAccessToken expires.
; Returns     : (nothing - writes to the INI file and mutates $oAcc as a
;               side effect)
; ============================================================================
Func _SaveTokens($oAcc, $sAccessToken, $sRefreshToken, $iExpiry)
	Local $sSection = $oAcc.Item("IniSection")
	IniWrite($g_sIniPath, $sSection, "AccessTokenEnc", _DPAPI_Protect($sAccessToken))
	IniWrite($g_sIniPath, $sSection, "AccessTokenExpiry", $iExpiry)
	If $sRefreshToken <> "" Then
		IniWrite($g_sIniPath, $sSection, "RefreshTokenEnc", _DPAPI_Protect($sRefreshToken))
		$oAcc.Item("RefreshToken") = $sRefreshToken
		$oAcc.Item("NeedsReauth") = False
		_NotifyResolved("reauth", $oAcc.Item("Username"), "The account is signed in again - e-mail can be sent.") ; E1
	EndIf
	$oAcc.Item("AccessToken") = $sAccessToken
	$oAcc.Item("AccessTokenExpiry") = $iExpiry
EndFunc   ;==>_SaveTokens

; ============================================================================
; _RunInteractiveAuth
; ----------------------------------------------------------------------------
; Description : Runs the full interactive OAuth2 sign-in flow for one
;               account: picks a fresh, currently free local port (starting
;               at $g_iAuthPortStart) for the OAuth2 redirect callback and
;               builds the matching "http://localhost:<port>/" redirect URI
;               into $oAcc.Item("RedirectURI") - a NEW port is picked on
;               every call, it is never reused/persisted across sign-in
;               attempts. This relies on the account's OAuth2 app
;               registration having "http://localhost/" (no port) registered
;               as a Public client/native redirect URI - Microsoft Entra ID
;               (and most other providers using the same "loopback"
;               convention, see RFC 8252 section 7.3) ignores the port
;               when matching this kind of redirect URI, so any free local
;               port is accepted without needing to update the app
;               registration. Then generates a random state value (and a
;               PKCE code_verifier/code_challenge pair if the account uses
;               PKCE), builds and opens the authorization URL in the
;               user's default browser, blocks while waiting for the
;               redirect callback (_Auth_WaitForRedirect), and - if a code
;               was received - exchanges it for tokens
;               (_Auth_ExchangeCode). Shows a _ProxyMsgBox() with the
;               outcome either way (not a native MsgBox() - see its own
;               header comment for why). Used both from the "Add account"
;               wizard and from clicking an existing account in the tray
;               menu to re-authenticate it.
;               If the sign-in succeeded but the provider returned no refresh
;               token (account still NeedsReauth), a warning is shown instead
;               of "Success".
; Parameters  : $oAcc - Account dictionary to authenticate.
; Returns     : True if sign-in and token exchange both succeeded, False
;               otherwise.
; ============================================================================
Func _RunInteractiveAuth($oAcc)
	Local $iAuthPort = _FindFreePort($g_iAuthPortStart)
	$oAcc.Item("RedirectURI") = _BuildLocalRedirectUri($iAuthPort)

	Local $sState = _RandomToken(16)
	Local $sVerifier = ""
	Local $sChallenge = ""

	If Number($oAcc.Item("UsePKCE")) = 1 Then
		$sVerifier = _PKCE_NewVerifier()
		$sChallenge = _PKCE_Challenge($sVerifier)
	EndIf

	Local $sUrl = _Auth_BuildPermissionUrl($oAcc, $sState, $sChallenge)

	TrayTip($g_sAppName, "Please sign in for " & $oAcc.Item("Username") & " in the browser window that just opened ...", 6)
	ShellExecute($sUrl)

	Local $sAuthError = ""
	Local $sCode = _Auth_WaitForRedirect($iAuthPort, $sState, $sAuthError)

	If $sCode = "" Then
		If $sAuthError <> "" Then
			LogFile("OAuth2 sign-in failed (" & $oAcc.Item("Username") & "): " & $sAuthError)
			_ProxyMsgBox(16, "Sign-in failed", "The provider rejected the sign-in:" & @CRLF & @CRLF & $sAuthError)
		Else
			_ProxyMsgBox(48, "Sign-in cancelled", "No valid response was received (timeout or cancelled)." & @CRLF & _
					"You can try again via the tray menu.")
		EndIf
		Return False
	EndIf

	If _Auth_ExchangeCode($oAcc, $sCode, $sVerifier) Then
		; Record the redirect URI that was actually used for this successful
		; sign-in, purely for informational/troubleshooting purposes when
		; inspecting the INI file - it is never read back authoritatively,
		; since a fresh one is picked on every call (see header comment).
		IniWrite($g_sIniPath, $oAcc.Item("IniSection"), "RedirectURI", $oAcc.Item("RedirectURI"))
		If $oAcc.Item("NeedsReauth") Then
			; C5: signed in, but no refresh token - say so instead of "Success"
			_ProxyMsgBox(48, "Signed in - no refresh token", "Account " & $oAcc.Item("Username") & " was signed in, but the provider " & _
					"did not return a refresh token." & @CRLF & @CRLF & "Sending works for about an hour; after that a new sign-in " & _
					"is required. See the log file for details:" & @CRLF & $g_sLogPath)
		Else
			_ProxyMsgBox(64, "Success", "Account " & $oAcc.Item("Username") & " was connected successfully.")
		EndIf
		Return True
	Else
		_ProxyMsgBox(16, "Error", "The token exchange failed. See the log file for details:" & @CRLF & $g_sLogPath)
		Return False
	EndIf
EndFunc   ;==>_RunInteractiveAuth

; ============================================================================
; _BuildLocalRedirectUri
; ----------------------------------------------------------------------------
; Description : Builds the "http://localhost:<port>/" redirect URI used for
;               the local OAuth2 callback listener (see _RunInteractiveAuth
;               and _Auth_WaitForRedirect). Factored out into its own
;               function so the exact format is defined in exactly one
;               place.
; Parameters  : $iPort - Local port the callback listener will use.
; Returns     : The redirect URI string.
; ============================================================================
Func _BuildLocalRedirectUri($iPort)
	Return "http://localhost:" & $iPort & "/"
EndFunc   ;==>_BuildLocalRedirectUri

; ############################################################################
; #  NOTIFICATIONS (E1, v76): engine, /notify sender process, settings dialog
; ############################################################################
;
; How it fits together:
;   1. The ENGINE (this process) notices an event - e.g. an account needs a
;      new sign-in - and calls _NotifyEvent(). That only DECIDES: is the
;      event switched on, is a channel configured, was the same message sent
;      less than MinIntervalMin minutes ago (rate limit)? This takes
;      microseconds; nothing is sent here.
;   2. __NotifyQueue() writes a small job file (event, texts and the channel
;      settings, secrets still DPAPI-encrypted) to %TEMP% and starts THIS
;      PROGRAM a second time with "/notify <job file>". Run() returns at
;      once, so a slow or unreachable notification server can never hold up
;      the relaying of e-mail (AutoIt is single-threaded).
;   3. The SENDER process (_NotifyProcessMain()) reads and deletes the job,
;      sends it over every channel listed in it (ntfy, webhook, command,
;      heartbeat) and writes one result line per channel to stderr
;      ("INF|...", "LOG|...", "ERR|...") - exactly like the PowerShell
;      helpers do (N2). It never writes into the log file itself.
;   4. _NotifyTick() (called from _ServiceConnections()) reads those lines
;      and writes them into the one log ("Notification [...]: ..."). It also
;      starts the heartbeat ping every HeartbeatIntervalMin minutes - only
;      while the main loop really runs, so a hanging proxy stops pinging.
;   5. _NotifyResolved() sends an "OK again" message when a problem that
;      was reported earlier is gone (switchable: AllClear).
; Events and where they come from:
;   reauth      - _Auth_RefreshToken() ("invalid_grant"), and at the start for
;                 every active account without a stored sign-in
;   refreshfail - _Auth_RefreshToken(): renewal failed twice in a row (one
;                 failure alone is often just a short hiccup at the provider)
;   refused     - _SniffServerData(): the real server did not accept an e-mail
;   errors      - _NotifyCountError(): 3 server errors for one account within
;                 15 minutes (_NoteServerLine(), _SniffServerData(), sign-in
;                 not answered)
;   loopblock   - _CheckLoopGap(): nothing relayed for at least LoopBlockSec
;                 seconds (not for a standby of the PC)
;   start/stop  - _Main() / _Shutdown() (one switch for both: StartStop)

; ============================================================================
; _NotifyLoadSettings
; ----------------------------------------------------------------------------
; Description : Reads the [Notify] section of the INI into the globals
;               declared near the top of the script. Missing keys get their
;               defaults (all channels off, all events on); invalid numbers
;               are replaced by the default with a warning in the log.
;               Called by _Main() at the start and by the Notifications
;               dialog after "Save".
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _NotifyLoadSettings()
	$g_bNtfyEnabled = (__NotifyIniInt("NtfyEnabled", 0, 0, 1) = 1)
	$g_sNtfyServer = StringStripWS(IniRead($g_sIniPath, "Notify", "NtfyServer", "https://ntfy.sh"), 3)
	If $g_sNtfyServer = "" Then $g_sNtfyServer = "https://ntfy.sh"
	$g_sNtfyTopic = StringStripWS(IniRead($g_sIniPath, "Notify", "NtfyTopic", ""), 3)
	$g_sNtfyTokenEnc = IniRead($g_sIniPath, "Notify", "NtfyTokenEnc", "")
	$g_bWebhookEnabled = (__NotifyIniInt("WebhookEnabled", 0, 0, 1) = 1)
	$g_sWebhookUrlEnc = IniRead($g_sIniPath, "Notify", "WebhookUrlEnc", "")
	$g_sWebhookTemplate = StringStripWS(IniRead($g_sIniPath, "Notify", "WebhookTemplate", $NOTIFY_TPL_ALL), 3)
	If $g_sWebhookTemplate = "" Then $g_sWebhookTemplate = $NOTIFY_TPL_ALL
	$g_bCommandEnabled = (__NotifyIniInt("CommandEnabled", 0, 0, 1) = 1)
	$g_sNotifyCommand = StringStripWS(IniRead($g_sIniPath, "Notify", "Command", ""), 3)
	$g_bHeartbeatEnabled = (__NotifyIniInt("HeartbeatEnabled", 0, 0, 1) = 1)
	$g_sHeartbeatUrlEnc = IniRead($g_sIniPath, "Notify", "HeartbeatUrlEnc", "")
	$g_iHeartbeatIntervalMin = __NotifyIniInt("HeartbeatIntervalMin", 5, 1, 1440)
	$g_iNotifyMinIntervalMin = __NotifyIniInt("MinIntervalMin", 60, 0, 1440)
	$g_iNotifyLoopBlockSec = __NotifyIniInt("LoopBlockSec", 60, 10, 3600)
	$g_bNotifyAllClear = (__NotifyIniInt("AllClear", 1, 0, 1) = 1)
	Local $aEv = StringSplit($g_sNotifyEventNames, "|")
	Local $i = 0
	For $i = 1 To $aEv[0]
		$g_oNotifyEventOn.Item(StringLower($aEv[$i])) = (__NotifyIniInt("Event" & $aEv[$i], 1, 0, 1) = 1)
	Next
EndFunc   ;==>_NotifyLoadSettings

; Reads a whole number from [Notify]; default (with a log warning) if it is
; not a number or outside $iMin..$iMax.
Func __NotifyIniInt($sKey, $iDefault, $iMin, $iMax)
	Local $sRaw = StringStripWS(IniRead($g_sIniPath, "Notify", $sKey, String($iDefault)), 3)
	If Not StringRegExp($sRaw, "^-?[0-9]+$") Or Number($sRaw) < $iMin Or Number($sRaw) > $iMax Then
		LogFile("Warning: INI setting [Notify] " & $sKey & "=" & $sRaw & " is not a whole number from " & $iMin & " to " & _
				$iMax & " - using the default " & $iDefault & " instead.")
		Return $iDefault
	EndIf
	Return Number($sRaw)
EndFunc   ;==>__NotifyIniInt

; Comma-separated list of the message channels that are switched on AND
; configured ("" = none). The heartbeat is not a message channel.
Func __NotifyChannelList()
	Local $s = ""
	If $g_bNtfyEnabled And $g_sNtfyTopic <> "" Then $s &= ",ntfy"
	If $g_bWebhookEnabled And $g_sWebhookUrlEnc <> "" Then $s &= ",webhook"
	If $g_bCommandEnabled And $g_sNotifyCommand <> "" Then $s &= ",command"
	Return StringTrimLeft($s, 1)
EndFunc   ;==>__NotifyChannelList

; Human-readable title of an event code (also used as {title}).
Func __NotifyTitle($sEvent)
	Switch $sEvent
		Case "reauth"
			Return "Sign-in required"
		Case "refreshfail"
			Return "Token renewal failed"
		Case "refused"
			Return "E-mail refused by the mail server"
		Case "errors"
			Return "Repeated errors"
		Case "loopblock"
			Return "Proxy was blocked"
		Case "start"
			Return "Proxy started"
		Case "stop"
			Return "Proxy stopped"
		Case "test"
			Return "Test notification"
		Case "heartbeat"
			Return "Heartbeat"
	EndSwitch
	Return $sEvent
EndFunc   ;==>__NotifyTitle

; True for events that describe a problem which can be resolved later (and
; then get an all-clear message).
Func __NotifyIsProblem($sEvent)
	Switch $sEvent
		Case "reauth", "refreshfail", "refused", "errors"
			Return True
	EndSwitch
	Return False
EndFunc   ;==>__NotifyIsProblem

; ============================================================================
; _NotifyEvent
; ----------------------------------------------------------------------------
; Description : Reports an event. Decides whether a message goes out (event
;               switched on, at least one channel configured, rate limit:
;               the same event for the same account at most every
;               MinIntervalMin minutes) and, if so, hands it to a /notify
;               process (__NotifyQueue()). Never waits for the sending.
;               For problem events (__NotifyIsProblem()) it also remembers
;               the problem, so _NotifyResolved() can send the all-clear -
;               even if this particular message fell under the rate limit.
; Parameters  : $sEvent   - Event code (see the section comment above).
;               $sAccount - Account the event belongs to ("" = none).
;               $sText    - Description for the message.
; Returns     : True if a message was handed over for sending.
; ============================================================================
Func _NotifyEvent($sEvent, $sAccount, $sText)
	Local $sFlag = $sEvent
	If $sEvent = "start" Or $sEvent = "stop" Then $sFlag = "startstop"
	If Not $g_oNotifyEventOn.Exists($sFlag) Then Return False
	If Not $g_oNotifyEventOn.Item($sFlag) Then Return False
	Local $sChannels = __NotifyChannelList()
	If $sChannels = "" Then Return False

	Local $sKey = $sEvent & "|" & $sAccount
	Local $bProblem = __NotifyIsProblem($sEvent)
	If $bProblem Then $g_oNotifyActive.Item($sKey) = __NotifyTitle($sEvent)
	If $g_iNotifyMinIntervalMin > 0 And $g_oNotifyLastSent.Exists($sKey) Then
		If TimerDiff($g_oNotifyLastSent.Item($sKey)) < $g_iNotifyMinIntervalMin * 60000 Then
			LogFile("Notification not sent (the same one went out less than " & $g_iNotifyMinIntervalMin & " min ago): " & _
					__NotifyTitle($sEvent) & __NotifyAccountSuffix($sAccount) & " - " & $sText, 6)
			Return False
		EndIf
	EndIf
	$g_oNotifyLastSent.Item($sKey) = TimerInit()

	Local $sPriority = "default"
	If $bProblem Or $sEvent = "loopblock" Then $sPriority = "high"
	Return (__NotifyQueue($sEvent, __NotifyTitle($sEvent), $sAccount, $sText, $sChannels, $sPriority, False) > 0)
EndFunc   ;==>_NotifyEvent

; ============================================================================
; _NotifyResolved
; ----------------------------------------------------------------------------
; Description : Called wherever something WORKS again (sign-in saved, token
;               renewed, e-mail accepted). If that problem had been reported
;               for this account, it is forgotten (the next occurrence is
;               reported at once again, without the rate limit) and - if
;               AllClear is on - an "OK again: ..." message is sent. If no
;               such problem was open, nothing happens (cheap: one lookup).
; Parameters  : $sEvent   - The problem's event code.
;               $sAccount - Account ("" = none).
;               $sDetail  - Text of the all-clear message.
; Returns     : (nothing)
; ============================================================================
Func _NotifyResolved($sEvent, $sAccount, $sDetail)
	Local $sKey = $sEvent & "|" & $sAccount
	If Not $g_oNotifyActive.Exists($sKey) Then Return
	Local $sTitle = $g_oNotifyActive.Item($sKey)
	$g_oNotifyActive.Remove($sKey)
	If $g_oNotifyLastSent.Exists($sKey) Then $g_oNotifyLastSent.Remove($sKey)
	If Not $g_bNotifyAllClear Then Return
	Local $sChannels = __NotifyChannelList()
	If $sChannels = "" Then Return
	__NotifyQueue("clear_" & $sEvent, "OK again: " & $sTitle, $sAccount, $sDetail, $sChannels, "default", False)
EndFunc   ;==>_NotifyResolved

; ============================================================================
; _NotifyCountError
; ----------------------------------------------------------------------------
; Description : Counts a server error for an account. Three within 15
;               minutes trigger the "errors" event (and the count starts
;               again). A single error is normal now and then and is not
;               reported on its own.
; Parameters  : $sAccount - Account ("" = unknown).
;               $sText    - Short description of this error.
; Returns     : (nothing)
; ============================================================================
Func _NotifyCountError($sAccount, $sText)
	Local Const $iWindowSec = 900, $iThreshold = 3
	Local $iNow = _UnixTimeNow()
	Local $sKept = ""
	Local $iCount = 1
	If $g_oNotifyErrTimes.Exists($sAccount) Then
		Local $aT = StringSplit($g_oNotifyErrTimes.Item($sAccount), "|")
		Local $i = 0
		For $i = 1 To $aT[0]
			If $aT[$i] <> "" And $iNow - Number($aT[$i]) < $iWindowSec Then
				$sKept &= $aT[$i] & "|"
				$iCount += 1
			EndIf
		Next
	EndIf
	If $iCount >= $iThreshold Then
		$g_oNotifyErrTimes.Item($sAccount) = ""
		_NotifyEvent("errors", $sAccount, $iCount & " errors within 15 minutes - the last one: " & $sText)
	Else
		$g_oNotifyErrTimes.Item($sAccount) = $sKept & $iNow
	EndIf
EndFunc   ;==>_NotifyCountError

; Account name of a connection ("" if it has none).
Func __ConnAccountName($oConn)
	If Not IsObj($oConn) Then Return ""
	If Not $oConn.Exists("Account") Then Return ""
	If Not IsObj($oConn.Item("Account")) Then Return ""
	Return $oConn.Item("Account").Item("Username")
EndFunc   ;==>__ConnAccountName

Func __NotifyAccountSuffix($sAccount)
	If $sAccount = "" Then Return ""
	Return " (" & $sAccount & ")"
EndFunc   ;==>__NotifyAccountSuffix

; The channel settings currently in effect, as a dictionary with the keys a
; job file uses (secrets stay DPAPI-encrypted).
Func __NotifyCurrentConfig()
	Local $o = ObjCreate("Scripting.Dictionary")
	$o.Item("NtfyServer") = $g_sNtfyServer
	$o.Item("NtfyTopic") = $g_sNtfyTopic
	$o.Item("NtfyTokenEnc") = $g_sNtfyTokenEnc
	$o.Item("WebhookUrlEnc") = $g_sWebhookUrlEnc
	$o.Item("WebhookTemplate") = $g_sWebhookTemplate
	$o.Item("Command") = $g_sNotifyCommand
	$o.Item("HeartbeatUrlEnc") = $g_sHeartbeatUrlEnc
	Return $o
EndFunc   ;==>__NotifyCurrentConfig

; One line for a job file: line breaks become spaces.
Func __NotifyOneLine($s)
	Return StringStripWS(StringRegExpReplace(String($s), "[\r\n]+", " "), 3)
EndFunc   ;==>__NotifyOneLine

; ============================================================================
; __NotifyQueue
; ----------------------------------------------------------------------------
; Description : Writes a job file and starts the sender process
;               ("<this program> /notify <job file>", hidden, stderr
;               redirected). Returns immediately. At most 10 sender
;               processes run at the same time (protection against a
;               flood if something goes badly wrong).
; Parameters  : $sEvent, $sTitle, $sAccount, $sText - content of the message.
;               $sChannels   - Comma-separated channels (ntfy,webhook,
;                              command,heartbeat).
;               $sPriority   - "high" or "default".
;               $bKeepOutput - True: keep the process's result lines for
;                              the caller (test buttons, $g_oNotifyDone).
;               $oCfg        - Channel settings (0 = the saved ones; the
;                              dialog passes the values being edited).
; Returns     : PID of the sender process, 0 if it could not be started.
; ============================================================================
Func __NotifyQueue($sEvent, $sTitle, $sAccount, $sText, $sChannels, $sPriority, $bKeepOutput, $oCfg = 0)
	If $g_oNotifyProcs.Count >= 10 Then
		LogFile("Notification error: " & $g_oNotifyProcs.Count & " notification processes are still running - """ & _
				$sTitle & """ was not sent.")
		Return 0
	EndIf
	If Not IsObj($oCfg) Then $oCfg = __NotifyCurrentConfig()

	Local $sJob = ""
	$sJob &= "Event=" & $sEvent & @CRLF
	$sJob &= "Title=" & __NotifyOneLine($sTitle) & @CRLF
	$sJob &= "Account=" & __NotifyOneLine($sAccount) & @CRLF
	$sJob &= "Text=" & __NotifyOneLine($sText) & @CRLF
	$sJob &= "Time=" & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & @CRLF
	$sJob &= "Host=" & @ComputerName & @CRLF
	$sJob &= "App=" & $g_sAppName & @CRLF
	$sJob &= "Priority=" & $sPriority & @CRLF
	$sJob &= "Channels=" & $sChannels & @CRLF
	Local $aKeys = $oCfg.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		$sJob &= $aKeys[$i] & "=" & __NotifyOneLine($oCfg.Item($aKeys[$i])) & @CRLF
	Next

	Local $sJobFile = @TempDir & "\" & $g_sAppName & "-notify-" & @YEAR & @MON & @MDAY & @HOUR & @MIN & @SEC & @MSEC & _
			"-" & Random(1000, 9999, 1) & ".job"
	Local $hFile = FileOpen($sJobFile, 2 + 128) ; overwrite, UTF-8 with BOM
	If $hFile = -1 Then
		LogFile("Notification error: the job file " & $sJobFile & " could not be written - """ & $sTitle & """ was not sent.")
		Return 0
	EndIf
	FileWrite($hFile, $sJob)
	FileClose($hFile)

	Local $sCmd = '"' & @ScriptFullPath & '" /notify "' & $sJobFile & '"'
	If Not @Compiled Then $sCmd = '"' & @AutoItExe & '" "' & @ScriptFullPath & '" /notify "' & $sJobFile & '"'
	Local $iPID = Run($sCmd, @ScriptDir, @SW_HIDE, $STDERR_CHILD)
	If $iPID = 0 Then
		FileDelete($sJobFile)
		LogFile("Notification error: the sending process could not be started (" & $sCmd & ") - """ & $sTitle & """ was not sent.")
		Return 0
	EndIf

	Local $oP = ObjCreate("Scripting.Dictionary")
	$oP.Item("Event") = $sEvent
	$oP.Item("Prefix") = $sEvent & __NotifyAccountSuffix($sAccount) & " | PID " & $iPID
	$oP.Item("Started") = TimerInit()
	$oP.Item("Buf") = ""
	$oP.Item("Out") = ""
	$oP.Item("Keep") = $bKeepOutput
	$g_oNotifyProcs.Item(String($iPID)) = $oP

	Local $iLevel = 0
	If $sEvent = "heartbeat" Then $iLevel = 6
	Local $sWhat = $sTitle & __NotifyAccountSuffix($sAccount)
	If $sText <> "" Then $sWhat &= " - " & $sText
	LogFile("Notification queued (" & $sChannels & ", PID " & $iPID & "): " & $sWhat, $iLevel)
	Return $iPID
EndFunc   ;==>__NotifyQueue

; ============================================================================
; _NotifyTick
; ----------------------------------------------------------------------------
; Description : Called on every _ServiceConnections() pass (does real work
;               at most every 250 ms): starts the heartbeat ping when it is
;               due, and collects the result lines of running sender
;               processes into the log (__NotifyDrainProc()).
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _NotifyTick()
	If $g_hNotifyLastTick <> 0 And TimerDiff($g_hNotifyLastTick) < 250 Then Return
	$g_hNotifyLastTick = TimerInit()

	If $g_bHeartbeatEnabled And $g_sHeartbeatUrlEnc <> "" Then
		If $g_hHeartbeatTimer = 0 Or TimerDiff($g_hHeartbeatTimer) >= $g_iHeartbeatIntervalMin * 60000 Then
			$g_hHeartbeatTimer = TimerInit()
			If Not __NotifyHeartbeatRunning() Then __NotifyQueue("heartbeat", "Heartbeat", "", "", "heartbeat", "default", False)
		EndIf
	EndIf

	If $g_oNotifyProcs.Count = 0 Then Return
	Local $aPids = $g_oNotifyProcs.Keys()
	Local $i = 0
	For $i = 0 To UBound($aPids) - 1
		__NotifyDrainProc($aPids[$i])
	Next
EndFunc   ;==>_NotifyTick

; True if a heartbeat ping is still on its way (then no second one is started).
Func __NotifyHeartbeatRunning()
	Local $aPids = $g_oNotifyProcs.Keys()
	Local $i = 0
	For $i = 0 To UBound($aPids) - 1
		If $g_oNotifyProcs.Item($aPids[$i]).Item("Event") = "heartbeat" Then Return True
	Next
	Return False
EndFunc   ;==>__NotifyHeartbeatRunning

; ============================================================================
; __NotifyDrainProc
; ----------------------------------------------------------------------------
; Description : Reads what a sender process has written to stderr, writes
;               every complete line into the log (__NotifyLogLine()) and
;               cleans up once the process has ended. A process still
;               running after 180 s is ended (every channel has its own
;               timeouts - at most 50 s per HTTP channel, 30 s for the
;               command - so this only catches the unexpected).
; Parameters  : $sPid - PID (String) - a key of $g_oNotifyProcs.
; Returns     : (nothing)
; ============================================================================
Func __NotifyDrainProc($sPid)
	Local $oP = $g_oNotifyProcs.Item($sPid)
	Local $iPID = Number($sPid)
	Local $bRunning = (ProcessExists($iPID) <> 0)
	Local $sNew = ""
	; After the end of the process the pipe may still hold data - read all of it
	While 1
		$sNew = StderrRead($iPID)
		If @error Or $sNew = "" Then ExitLoop
		$oP.Item("Buf") = $oP.Item("Buf") & $sNew
		If $bRunning Then ExitLoop
	WEnd

	Local $bTimeout = ($bRunning And TimerDiff($oP.Item("Started")) > 180000)
	Local $sBuf = StringReplace($oP.Item("Buf"), @CR, "")
	Local $iLastLf = StringInStr($sBuf, @LF, 0, -1)
	If $iLastLf > 0 Then
		Local $aLines = StringSplit(StringLeft($sBuf, $iLastLf - 1), @LF)
		Local $i = 0
		For $i = 1 To $aLines[0]
			__NotifyLogLine($oP, $aLines[$i])
		Next
		$sBuf = StringMid($sBuf, $iLastLf + 1)
	EndIf
	$oP.Item("Buf") = $sBuf
	If $bRunning And Not $bTimeout Then Return

	If $sBuf <> "" Then __NotifyLogLine($oP, $sBuf)
	If $bTimeout Then
		ProcessClose($iPID)
		__NotifyLogLine($oP, "ERR|the sending process did not finish within 180 s and was ended.")
	EndIf
	StdioClose($iPID)
	If $oP.Item("Keep") Then $g_oNotifyDone.Item($sPid) = $oP.Item("Out")
	$g_oNotifyProcs.Remove($sPid)
EndFunc   ;==>__NotifyDrainProc

; Writes one result line of a sender process into the log: "INF|" at every
; log level, "LOG|" at level 6 (e.g. a successful heartbeat ping),
; "ERR|" (and anything without a marker) as an error. Also collects it for
; a test button ($oP "Out").
Func __NotifyLogLine($oP, $sLine)
	$sLine = StringStripWS($sLine, 3)
	If $sLine = "" Then Return
	Local $sKind = "ERR", $sMsg = $sLine
	If StringRegExp($sLine, "^(INF|LOG|ERR)\|") Then
		$sKind = StringLeft($sLine, 3)
		$sMsg = StringMid($sLine, 5)
	EndIf
	Switch $sKind
		Case "INF"
			LogFile("Notification [" & $oP.Item("Prefix") & "]: " & $sMsg)
			$oP.Item("Out") = $oP.Item("Out") & "OK - " & $sMsg & @CRLF
		Case "LOG"
			LogFile("Notification [" & $oP.Item("Prefix") & "]: " & $sMsg, 6)
			$oP.Item("Out") = $oP.Item("Out") & "OK - " & $sMsg & @CRLF
		Case Else
			LogFile("Notification error [" & $oP.Item("Prefix") & "]: " & $sMsg)
			_StatsNoteError("notification failed")
			$oP.Item("Out") = $oP.Item("Out") & "ERROR - " & $sMsg & @CRLF
	EndSwitch
EndFunc   ;==>__NotifyLogLine

; ============================================================================
; _NotifyWaitAll
; ----------------------------------------------------------------------------
; Description : At the end of the program (_Shutdown()): waits at most
;               $iMaxMs for the sender processes still running (normally
;               just the "Proxy stopped" message), so their results still
;               reach the log. Whatever is not finished by then keeps
;               running on its own and is sent anyway - only its result
;               line is missing from the log.
; Parameters  : $iMaxMs - Longest wait in milliseconds.
; Returns     : (nothing)
; ============================================================================
Func _NotifyWaitAll($iMaxMs)
	Local $hTimer = TimerInit()
	Local $aPids, $i = 0
	While $g_oNotifyProcs.Count > 0 And TimerDiff($hTimer) < $iMaxMs
		$aPids = $g_oNotifyProcs.Keys()
		For $i = 0 To UBound($aPids) - 1
			__NotifyDrainProc($aPids[$i])
		Next
		If $g_oNotifyProcs.Count > 0 Then Sleep(50)
	WEnd
	If $g_oNotifyProcs.Count > 0 Then
		LogFile("Note: " & $g_oNotifyProcs.Count & " notification(s) were still being sent when the program ended - they are " & _
				"sent anyway, but their result is not in the log.")
	EndIf
EndFunc   ;==>_NotifyWaitAll

; ============================================================================
; __NotifyRunTest
; ----------------------------------------------------------------------------
; Description : For the test buttons of the Notifications dialog: sends a
;               test message over ONE channel with the values currently in
;               the dialog (saved or not), waits for the result (the proxy
;               keeps working meanwhile - _ServiceConnections()) and
;               returns the result lines.
; Parameters  : $sChannel - "ntfy", "webhook", "command" or "heartbeat".
;               $oCfg     - Channel settings from the dialog.
;               $hGui     - The dialog (disabled while the test runs).
; Returns     : Result text for the dialog.
; ============================================================================
Func __NotifyRunTest($sChannel, $oCfg, $hGui)
	GUISetCursor(15, 1, $hGui)
	GUISetState(@SW_DISABLE, $hGui)
	Local $iPID = __NotifyQueue("test", "Test notification", "", "This is a test notification from " & $g_sAppName & " on " & _
			@ComputerName & ". If you can read this, the channel works.", $sChannel, "default", True, $oCfg)
	Local $sOut = ""
	If $iPID = 0 Then
		$sOut = "ERROR - the sending process could not be started (see the log)."
	Else
		Local $hTimer = TimerInit()
		While Not $g_oNotifyDone.Exists(String($iPID)) And TimerDiff($hTimer) < 190000
			If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
		WEnd
		If $g_oNotifyDone.Exists(String($iPID)) Then
			$sOut = $g_oNotifyDone.Item(String($iPID))
			$g_oNotifyDone.Remove(String($iPID))
		EndIf
		If StringStripWS($sOut, 3) = "" Then $sOut = "ERROR - no result from the sending process (see the log)."
	EndIf
	GUISetState(@SW_ENABLE, $hGui)
	GUISetCursor(2, 0, $hGui)
	WinActivate($hGui)
	Return $sChannel & " test, " & @HOUR & ":" & @MIN & ":" & @SEC & ":" & @CRLF & StringStripWS($sOut, 2)
EndFunc   ;==>__NotifyRunTest

; ============================================================================
; _NotifyProcessMain
; ----------------------------------------------------------------------------
; Description : Entry point of the SENDER process ("/notify <job file>",
;               see the section comment). Runs instead of the whole normal
;               program: no single-instance check, no tray icon, no
;               listeners, and no writing into the log file (the result
;               lines go to stderr and are logged by the main program,
;               _NotifyTick()). Reads and deletes the job file, sends over
;               every channel listed in it and exits with the number of
;               channels that failed.
; Parameters  : $sJobFile - Path of the job file.
; Returns     : (does not return - Exit)
; ============================================================================
Func _NotifyProcessMain($sJobFile)
	$g_bUseLogSetting = False ; never write into the log file from this process (helpers like _DPAPI_Unprotect() call LogFile())
	Local $oComErrorHandler = ObjEvent("AutoIt.Error", "_ComErrorHandler")
	Local $oJob = __NotifyReadJob($sJobFile)
	FileDelete($sJobFile)
	If Not IsObj($oJob) Then
		__NotifyOut("ERR", "the job file could not be read: " & $sJobFile)
		Exit 99
	EndIf
	Local $aCh = StringSplit(__NotifyJ($oJob, "Channels"), ",")
	Local $iFailed = 0, $i = 0
	For $i = 1 To $aCh[0]
		Local $sCh = StringStripWS($aCh[$i], 3)
		If $sCh = "" Then ContinueLoop
		If Not __NotifySendChannel($sCh, $oJob) Then $iFailed += 1
	Next
	$oComErrorHandler = 0
	Exit $iFailed
EndFunc   ;==>_NotifyProcessMain

; Reads a job file (UTF-8, "Key=Value" per line) into a dictionary; 0 on error.
Func __NotifyReadJob($sPath)
	Local $hFile = FileOpen($sPath, 0) ; read, encoding detected from the BOM
	If $hFile = -1 Then Return 0
	Local $sAll = FileRead($hFile)
	FileClose($hFile)
	Local $o = ObjCreate("Scripting.Dictionary")
	Local $aLines = StringSplit(StringReplace($sAll, @CR, ""), @LF)
	Local $i = 0
	For $i = 1 To $aLines[0]
		Local $iEq = StringInStr($aLines[$i], "=")
		If $iEq > 1 Then $o.Item(StringLeft($aLines[$i], $iEq - 1)) = StringMid($aLines[$i], $iEq + 1)
	Next
	If Not $o.Exists("Channels") Then Return 0
	Return $o
EndFunc   ;==>__NotifyReadJob

; Value of a job key ("" if missing).
Func __NotifyJ($oJob, $sKey)
	If $oJob.Exists($sKey) Then Return $oJob.Item($sKey)
	Return ""
EndFunc   ;==>__NotifyJ

; Result line of the sender process for the main program (stderr, one line,
; marker "INF|", "LOG|" or "ERR|" - see __NotifyLogLine()).
Func __NotifyOut($sKind, $sMsg)
	ConsoleWriteError($sKind & "|" & StringRegExpReplace($sMsg, "[\x00-\x1F]+", " ") & @LF)
EndFunc   ;==>__NotifyOut

Func __NotifySendChannel($sCh, $oJob)
	Switch $sCh
		Case "ntfy"
			Return __NotifySendNtfy($oJob)
		Case "webhook"
			Return __NotifySendWebhook($oJob)
		Case "command"
			Return __NotifySendCommand($oJob)
		Case "heartbeat"
			Return __NotifySendHeartbeat($oJob)
	EndSwitch
	__NotifyOut("ERR", "unknown channel """ & $sCh & """")
	Return False
EndFunc   ;==>__NotifySendChannel

; ============================================================================
; __NotifyPlaceholder / __NotifyFill
; ----------------------------------------------------------------------------
; Description : Placeholders for the webhook template and the command line:
;               {event}    event code (reauth, refreshfail, refused, errors,
;                          loopblock, start, stop, clear_<code>, test)
;               {title}    short title, e.g. "Sign-in required"
;               {headline} "<program> (<PC name>): <title>"
;               {text}     the description
;               {message}  "<account>: <description>" (only the description
;                          if no account is involved)
;               {account}  the account, or empty
;               {time}     local time, "YYYY-MM-DD hh:mm:ss"
;               {host}     the PC's name
;               {app}      the program's name
;               __NotifyFill() inserts them. $sMode "json" escapes the
;               values for use inside a JSON string; "cmd" removes the
;               characters the Windows command line would interpret
;               (< > | & ^ % and " -> '), so a value can never become a
;               command of its own - the unchanged values are available to
;               the command as environment variables (CCSMTP_EVENT, ...).
; ============================================================================
Func __NotifyPlaceholder($oJob, $sName)
	Switch $sName
		Case "headline"
			Return __NotifyJ($oJob, "App") & " (" & __NotifyJ($oJob, "Host") & "): " & __NotifyJ($oJob, "Title")
		Case "message"
			If __NotifyJ($oJob, "Account") = "" Then Return __NotifyJ($oJob, "Text")
			Return __NotifyJ($oJob, "Account") & ": " & __NotifyJ($oJob, "Text")
	EndSwitch
	Return __NotifyJ($oJob, StringUpper(StringLeft($sName, 1)) & StringMid($sName, 2))
EndFunc   ;==>__NotifyPlaceholder

Func __NotifyFill($sTemplate, $oJob, $sMode)
	Local $aNames = StringSplit("event|title|headline|text|message|account|time|host|app", "|")
	Local $i = 0
	For $i = 1 To $aNames[0]
		Local $sVal = __NotifyPlaceholder($oJob, $aNames[$i])
		If $sMode = "json" Then
			$sVal = __NotifyJsonEsc($sVal)
		ElseIf $sMode = "cmd" Then
			$sVal = StringReplace(StringRegExpReplace($sVal, "[<>|&^%]", " "), '"', "'")
		EndIf
		$sTemplate = StringReplace($sTemplate, "{" & $aNames[$i] & "}", $sVal)
	Next
	Return $sTemplate
EndFunc   ;==>__NotifyFill

; Escapes a value for use inside a JSON string.
Func __NotifyJsonEsc($s)
	$s = StringReplace($s, "\", "\\")
	$s = StringReplace($s, '"', '\"')
	$s = StringReplace($s, @CRLF, "\n")
	$s = StringReplace($s, @CR, "\n")
	$s = StringReplace($s, @LF, "\n")
	$s = StringReplace($s, @TAB, "\t")
	Return StringRegExpReplace($s, "[\x00-\x1F]", " ")
EndFunc   ;==>__NotifyJsonEsc

; Host part of a URL, for result lines (the rest of a webhook/ping URL is
; secret and is never written to the log).
Func __NotifyUrlHost($sUrl)
	Local $a = StringRegExp($sUrl, "(?i)^https?://([^/?#]+)", 1)
	If @error Then Return "(invalid URL)"
	Return $a[0]
EndFunc   ;==>__NotifyUrlHost

; ============================================================================
; __NotifyHttp
; ----------------------------------------------------------------------------
; Description : One HTTP(S) request via WinHTTP for the sender process.
;               Timeouts: 10 s to resolve and connect, 15 s to send and to
;               receive - the process has no hurry, it only must not hang
;               forever (the main program ends it after 180 s anyway).
; Parameters  : $sMethod      - "POST" or "GET".
;               $sUrl         - Full URL.
;               $vBody        - Binary body (UTF-8), or "" for none.
;               $sContentType - Content-Type header ("" = none).
;               $sAuth        - Authorization header ("" = none).
;               $iStatus      - [ByRef] HTTP status (0 if there was no answer).
;               $sErr         - [ByRef] Error text if there was no answer.
; Returns     : The response text.
; ============================================================================
Func __NotifyHttp($sMethod, $sUrl, $vBody, $sContentType, $sAuth, ByRef $iStatus, ByRef $sErr)
	$iStatus = 0
	$sErr = ""
	Local $oHttp = ObjCreate("WinHttp.WinHttpRequest.5.1")
	If Not IsObj($oHttp) Then
		$sErr = "WinHTTP is not available"
		Return ""
	EndIf
	$g_sLastComError = ""
	$oHttp.Open($sMethod, $sUrl, False)
	If @error Then
		$sErr = "invalid URL (" & StringStripWS($g_sLastComError, 3) & ")"
		Return ""
	EndIf
	If $sContentType <> "" Then $oHttp.SetRequestHeader("Content-Type", $sContentType)
	$oHttp.SetRequestHeader("User-Agent", $g_sAppName)
	If $sAuth <> "" Then $oHttp.SetRequestHeader("Authorization", $sAuth)
	$oHttp.SetTimeouts(10000, 10000, 15000, 15000)
	If IsBinary($vBody) Then
		$oHttp.Send($vBody)
	Else
		$oHttp.Send()
	EndIf
	If @error Then
		$sErr = StringStripWS($g_sLastComError, 3)
		If $sErr = "" Then $sErr = "no connection to the server"
		Return ""
	EndIf
	$iStatus = $oHttp.Status
	Return $oHttp.ResponseText
EndFunc   ;==>__NotifyHttp

; Writes the result of an HTTP channel and returns True for a 2xx answer.
; $bQuiet: success only at log level 6 (heartbeat every few minutes).
Func __NotifyReport($sChannel, $sTarget, $iStatus, $sErr, $sResp, $bQuiet = False)
	If $sErr <> "" Then
		__NotifyOut("ERR", $sChannel & ": sending to " & $sTarget & " failed - " & $sErr)
		Return False
	EndIf
	If $iStatus >= 200 And $iStatus < 300 Then
		Local $sKind = "INF"
		If $bQuiet Then $sKind = "LOG"
		__NotifyOut($sKind, $sChannel & ": sent to " & $sTarget & " (HTTP " & $iStatus & ")")
		Return True
	EndIf
	__NotifyOut("ERR", $sChannel & ": " & $sTarget & " answered HTTP " & $iStatus & " - " & StringLeft(StringStripWS($sResp, 3), 200))
	Return False
EndFunc   ;==>__NotifyReport

; ntfy: JSON publish to the server root (topic, title, message, priority 4
; for problems / 3 otherwise, a tag that the app shows as an emoji), with
; "Authorization: Bearer <token>" if an access token is set.
Func __NotifySendNtfy($oJob)
	Local $sServer = __NotifyJ($oJob, "NtfyServer")
	If $sServer = "" Then $sServer = "https://ntfy.sh"
	While StringRight($sServer, 1) = "/"
		$sServer = StringTrimRight($sServer, 1)
	WEnd
	Local $sTopic = __NotifyJ($oJob, "NtfyTopic")
	If $sTopic = "" Then
		__NotifyOut("ERR", "ntfy: no topic configured")
		Return False
	EndIf
	Local $iPrio = 3
	Local $sTag = "information_source"
	If __NotifyJ($oJob, "Priority") = "high" Then
		$iPrio = 4
		$sTag = "warning"
	EndIf
	If StringLeft(__NotifyJ($oJob, "Event"), 6) = "clear_" Then $sTag = "white_check_mark"
	Local $sBody = '{"topic":"' & __NotifyJsonEsc($sTopic) & '","title":"' & __NotifyJsonEsc(__NotifyPlaceholder($oJob, "headline")) & _
			'","message":"' & __NotifyJsonEsc(__NotifyPlaceholder($oJob, "message")) & '","priority":' & $iPrio & _
			',"tags":["' & $sTag & '"]}'
	Local $sAuth = ""
	Local $sToken = _DPAPI_Unprotect(__NotifyJ($oJob, "NtfyTokenEnc"), "ntfy access token")
	If $sToken <> "" Then $sAuth = "Bearer " & $sToken
	Local $iStatus = 0, $sErr = ""
	Local $sResp = __NotifyHttp("POST", $sServer, StringToBinary($sBody, 4), "application/json", $sAuth, $iStatus, $sErr)
	Return __NotifyReport("ntfy", __NotifyUrlHost($sServer), $iStatus, $sErr, $sResp)
EndFunc   ;==>__NotifySendNtfy

; Webhook: POST of the filled-in JSON template.
Func __NotifySendWebhook($oJob)
	Local $sUrl = _DPAPI_Unprotect(__NotifyJ($oJob, "WebhookUrlEnc"), "webhook URL")
	If $sUrl = "" Then
		__NotifyOut("ERR", "webhook: no URL configured (or it could not be decrypted)")
		Return False
	EndIf
	Local $sTpl = __NotifyJ($oJob, "WebhookTemplate")
	If $sTpl = "" Then $sTpl = $NOTIFY_TPL_ALL
	Local $sBody = __NotifyFill($sTpl, $oJob, "json")
	Local $iStatus = 0, $sErr = ""
	Local $sResp = __NotifyHttp("POST", $sUrl, StringToBinary($sBody, 4), "application/json", "", $iStatus, $sErr)
	Return __NotifyReport("webhook", __NotifyUrlHost($sUrl), $iStatus, $sErr, $sResp)
EndFunc   ;==>__NotifySendWebhook

; Heartbeat: a GET of the ping URL (healthchecks.io, Uptime Kuma push
; monitor, Better Stack, ...). The test button sends exactly the same ping.
Func __NotifySendHeartbeat($oJob)
	Local $sUrl = _DPAPI_Unprotect(__NotifyJ($oJob, "HeartbeatUrlEnc"), "heartbeat URL")
	If $sUrl = "" Then
		__NotifyOut("ERR", "heartbeat: no ping URL configured (or it could not be decrypted)")
		Return False
	EndIf
	Local $iStatus = 0, $sErr = ""
	Local $sResp = __NotifyHttp("GET", $sUrl, "", "", "", $iStatus, $sErr)
	Return __NotifyReport("heartbeat", __NotifyUrlHost($sUrl), $iStatus, $sErr, $sResp, (__NotifyJ($oJob, "Event") = "heartbeat"))
EndFunc   ;==>__NotifySendHeartbeat

; Command: run via "cmd /s /c", hidden, with the placeholders filled in
; ("cmd" mode, see __NotifyFill()) and all values as environment variables
; CCSMTP_EVENT, CCSMTP_TITLE, CCSMTP_HEADLINE, CCSMTP_TEXT, CCSMTP_MESSAGE,
; CCSMTP_ACCOUNT, CCSMTP_TIME, CCSMTP_HOST. Waits up to 30 s for the exit
; code (0 = success); a command still running after that is left alone.
Func __NotifySendCommand($oJob)
	Local $sCmd = __NotifyJ($oJob, "Command")
	If $sCmd = "" Then
		__NotifyOut("ERR", "command: no command configured")
		Return False
	EndIf
	Local $aNames = StringSplit("event|title|headline|text|message|account|time|host", "|")
	Local $i = 0
	For $i = 1 To $aNames[0]
		EnvSet("CCSMTP_" & StringUpper($aNames[$i]), __NotifyPlaceholder($oJob, $aNames[$i]))
	Next
	$sCmd = __NotifyFill($sCmd, $oJob, "cmd")
	Local $iPID = Run(@ComSpec & ' /s /c "' & $sCmd & '"', @ScriptDir, @SW_HIDE)
	If $iPID = 0 Then
		__NotifyOut("ERR", "command: could not be started")
		Return False
	EndIf
	If Not ProcessWaitClose($iPID, 30) Then
		__NotifyOut("ERR", "command: still running after 30 s - left running, result unknown")
		Return False
	EndIf
	Local $iExit = @extended
	If $iExit = 0 Then
		__NotifyOut("INF", "command: finished (exit code 0)")
		Return True
	EndIf
	__NotifyOut("ERR", "command: finished with exit code " & $iExit)
	Return False
EndFunc   ;==>__NotifySendCommand

; ############################################################################
; #  NOTIFICATION SETTINGS DIALOG (tray menu: Settings > Notifications)
; ############################################################################

; ============================================================================
; _ShowNotificationSettingsDialog
; ----------------------------------------------------------------------------
; Description : E1: dialog for the [Notify] INI section - the four channels
;               (ntfy, webhook, command, heartbeat), each with its own
;               "Test" button, and which events are reported. Every field
;               has a tooltip. "Test" sends a test message over that one
;               channel with the values currently in the window (saving is
;               not needed first) and shows the result at the bottom.
;               "Save" checks the input (e.g. a switched-on channel needs
;               its URL/topic/command), writes the [Notify] section
;               (webhook URL, heartbeat URL and ntfy token DPAPI-encrypted,
;               like every other secret of this program) and takes the
;               values over at once (_NotifyLoadSettings()); a newly
;               switched-on heartbeat pings right away. "Cancel" / X / Esc
;               discard all changes. The proxy keeps working while the
;               window is open (_ServiceConnections()).
; Parameters  : $hParent - Optional owner window (0 from the tray menu).
; Returns     : True if the settings were saved, False otherwise.
; ============================================================================
Func _ShowNotificationSettingsDialog($hParent = 0)
	Local Const $iW = 640
	; Y1 (v80): 606 px high (was 712 px, which did not fit above the taskbar
	; on a 768 px high work area): Command and Heartbeat side by side, a
	; slightly smaller template field and result field.
	Local $hGui = GUICreate("Notifications - " & $g_sAppName, $iW, 606, -1, -1, -1, -1, $hParent)
	_SetDialogIcon($hGui)
	Local Const $xL = 28, $xI = 120, $wI = 492, $xT = 517

	; ---- ntfy ------------------------------------------------------------
	GUICtrlCreateGroup("ntfy - push messages to the phone (ntfy.sh or your own ntfy server)", 15, 10, $iW - 30, 112)
	Local $idNtfyOn = GUICtrlCreateCheckbox("Send notifications via ntfy", $xL, 30, 300, 20)
	GUICtrlSetTip($idNtfyOn, "Push messages to the ntfy app (Android, iPhone) or the ntfy web page." & @CRLF & _
			"No account is needed on ntfy.sh: subscribe to the topic below in the app - done." & @CRLF & _
			"INI: [Notify] NtfyEnabled, default: off")
	Local $idNtfyTest = GUICtrlCreateButton("Test", $xT, 27, 95, 25)
	GUICtrlSetTip($idNtfyTest, "Send a test message via ntfy with the values in this window now" & @CRLF & "(no need to save first).")
	GUICtrlCreateLabel("Server:", $xL, 61, 85, 18)
	Local $idNtfyServer = GUICtrlCreateInput($g_sNtfyServer, $xI, 58, 205, 21)
	GUICtrlSetTip($idNtfyServer, "https://ntfy.sh (free public server) or the address of your own ntfy server." & @CRLF & _
			"INI: [Notify] NtfyServer, default: https://ntfy.sh")
	GUICtrlCreateLabel("Topic:", 340, 61, 45, 18)
	; X1 (v78): no topic saved yet -> a suggestion that nobody can guess
	; (__NotifyTopicSuggestion()), so it only has to be entered in the app.
	Local $sTopicShown = $g_sNtfyTopic
	If $sTopicShown = "" Then $sTopicShown = __NotifyTopicSuggestion()
	Local $idNtfyTopic = GUICtrlCreateInput($sTopicShown, 390, 58, 222, 21)
	GUICtrlSetTip($idNtfyTopic, "Name of the topic (letters, digits, - and _). On ntfy.sh anyone who knows the" & @CRLF & _
			"name can read the messages - so choose a long name nobody can guess," & @CRLF & _
			"e.g. citro-proxy-7Hq2xK9mPw. The same name is entered in the ntfy app." & @CRLF & _
			"As long as no topic is saved, a random suggestion is filled in" & @CRLF & _
			"(" & $g_sAppName & "- plus 8 random letters and digits)." & @CRLF & _
			"INI: [Notify] NtfyTopic")
	GUICtrlCreateLabel("Access token:", $xL, 91, 85, 18)
	Local $idNtfyToken = GUICtrlCreateInput(_DPAPI_Unprotect($g_sNtfyTokenEnc, "ntfy access token"), $xI, 88, 205, 21, _
			BitOR($GUI_SS_DEFAULT_INPUT, $ES_PASSWORD))
	GUICtrlSetTip($idNtfyToken, "Optional - only for a protected topic (own server with user accounts, or a" & @CRLF & _
			"reserved topic on ntfy.sh): an access token (tk_...) created in the ntfy web app" & @CRLF & _
			"under Account -> Access tokens. Empty = no sign-in." & @CRLF & _
			"Stored encrypted. INI: [Notify] NtfyTokenEnc")
	Local $idNtfyHint = GUICtrlCreateLabel("(optional, only for protected topics)", 340, 91, 270, 18)
	GUICtrlSetColor($idNtfyHint, 0x606060)
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	; ---- Webhook -----------------------------------------------------------
	GUICtrlCreateGroup("Webhook - Teams, Slack, Discord, Home Assistant, n8n, Node-RED, ...", 15, 128, $iW - 30, 166)
	Local $idHookOn = GUICtrlCreateCheckbox("Send notifications to a webhook", $xL, 148, 300, 20)
	GUICtrlSetTip($idHookOn, "Sends every message as an HTTPS POST with a JSON text to the URL below." & @CRLF & _
			"INI: [Notify] WebhookEnabled, default: off")
	Local $idHookTest = GUICtrlCreateButton("Test", $xT, 145, 95, 25)
	GUICtrlSetTip($idHookTest, "Send a test message to the webhook with the values in this window now.")
	GUICtrlCreateLabel("URL:", $xL, 179, 85, 18)
	Local $idHookUrl = GUICtrlCreateInput(_DPAPI_Unprotect($g_sWebhookUrlEnc, "webhook URL"), $xI, 176, $wI, 21)
	GUICtrlSetTip($idHookUrl, "The webhook address you got from the service (e.g. Teams: Workflows ->" & @CRLF & _
			"""Send webhook alerts to a channel"" -> copy the URL). It works like a password:" & @CRLF & _
			"whoever has it can post messages - it is stored encrypted and never written to the log." & @CRLF & _
			"INI: [Notify] WebhookUrlEnc")
	GUICtrlCreateLabel("Format:", $xL, 209, 85, 18)
	Local $idHookPreset = GUICtrlCreateCombo("", $xI, 206, 330, 22, BitOR($CBS_DROPDOWNLIST, $CBS_AUTOHSCROLL))
	Local Const $sPresetNone = "(choose a preset to fill in the template)"
	GUICtrlSetData($idHookPreset, $sPresetNone & "|Microsoft Teams (Workflows)|Slack / Mattermost / Rocket.Chat|Discord|" & _
			"All fields (Home Assistant, n8n, Node-RED, others)", $sPresetNone)
	GUICtrlSetTip($idHookPreset, "Fills the template below with the JSON format the chosen service expects." & @CRLF & _
			"You can change the template afterwards.")
	GUICtrlCreateLabel("Template:", $xL, 238, 85, 18)
	Local $idHookTpl = GUICtrlCreateEdit($g_sWebhookTemplate, $xI, 236, $wI, 48, _
			BitOR($ES_MULTILINE, $ES_WANTRETURN, $ES_AUTOVSCROLL, $WS_VSCROLL))
	GUICtrlSetTip($idHookTpl, "The JSON text that is sent. Placeholders:" & @CRLF & _
			"  {headline}  program (PC): title      {title}  e.g. ""Sign-in required""" & @CRLF & _
			"  {message}   account: description     {text}   the description only" & @CRLF & _
			"  {account}  {event}  {time}  {host}  {app}" & @CRLF & _
			"The values are inserted JSON-safe. Line breaks are removed when saving." & @CRLF & _
			"INI: [Notify] WebhookTemplate")
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	; ---- Command -----------------------------------------------------------
	; Command (left) and Heartbeat (right) share one row (Y1)
	GUICtrlCreateGroup("Command - your own program or script", 15, 300, 300, 82)
	Local $idCmdOn = GUICtrlCreateCheckbox("Run a command", $xL, 320, 180, 20)
	GUICtrlSetTip($idCmdOn, "Runs the command below (hidden, via cmd.exe) for every message - for anything" & @CRLF & _
			"that has no channel of its own (Signal via signal-cli, a monitoring agent, a mail tool, ...)." & @CRLF & _
			"INI: [Notify] CommandEnabled, default: off")
	Local $idCmdTest = GUICtrlCreateButton("Test", 225, 317, 80, 25)
	GUICtrlSetTip($idCmdTest, "Run the command once now with a test message.")
	Local $idCmd = GUICtrlCreateInput($g_sNotifyCommand, $xL, 348, 277, 21)
	__SetCueBanner($idCmd, "Command line, e.g. powershell -File ...")
	GUICtrlSetTip($idCmd, "Command line, with the same placeholders as the webhook template, e.g." & @CRLF & _
			"  powershell -NoProfile -File C:\Scripts\notify.ps1 ""{event}"" ""{message}""" & @CRLF & _
			"Characters the command line would interpret (< > | & ^ % "") are removed from the" & @CRLF & _
			"inserted values. Unchanged values are available as environment variables:" & @CRLF & _
			"CCSMTP_EVENT, CCSMTP_TITLE, CCSMTP_HEADLINE, CCSMTP_TEXT, CCSMTP_MESSAGE," & @CRLF & _
			"CCSMTP_ACCOUNT, CCSMTP_TIME, CCSMTP_HOST. Exit code 0 = success." & @CRLF & _
			"INI: [Notify] Command")
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	; ---- Heartbeat ---------------------------------------------------------
	GUICtrlCreateGroup("Heartbeat - alarm when the proxy stops", 325, 300, 300, 82)
	Local $idHbOn = GUICtrlCreateCheckbox("Send a regular ping", 338, 320, 180, 20)
	GUICtrlSetTip($idHbOn, "Calls the ping URL below regularly - but only while the proxy really works." & @CRLF & _
			"If the pings stop (proxy crashed or hanging, PC off, no internet), the monitoring" & @CRLF & _
			"service (healthchecks.io, Uptime Kuma, Better Stack, ...) alerts you. This is the" & @CRLF & _
			"only way to hear about a proxy that can no longer send anything itself." & @CRLF & _
			"INI: [Notify] HeartbeatEnabled, default: off")
	Local $idHbTest = GUICtrlCreateButton("Test", 535, 317, 80, 25)
	GUICtrlSetTip($idHbTest, "Send one ping now with the values in this window.")
	Local $idHbUrl = GUICtrlCreateInput(_DPAPI_Unprotect($g_sHeartbeatUrlEnc, "heartbeat URL"), 338, 348, 160, 21)
	__SetCueBanner($idHbUrl, "Ping URL (https://...)")
	GUICtrlSetTip($idHbUrl, "The ping URL of your check, e.g." & @CRLF & _
			"  https://hc-ping.com/<uuid>                       (healthchecks.io)" & @CRLF & _
			"  https://kuma.example.com/api/push/<token>?status=up&msg=OK   (Uptime Kuma)" & @CRLF & _
			"Stored encrypted. INI: [Notify] HeartbeatUrlEnc")
	GUICtrlCreateLabel("every", 503, 351, 33, 18)
	Local $idHbInt = GUICtrlCreateInput($g_iHeartbeatIntervalMin, 537, 348, 40, 21, BitOR($GUI_SS_DEFAULT_INPUT, $ES_RIGHT))
	GUICtrlSetTip($idHbInt, "Minutes between two pings (1-1440). Set the monitoring service's period to the" & @CRLF & _
			"same value and allow a grace time of at least as much again." & @CRLF & _
			"INI: [Notify] HeartbeatIntervalMin, default: 5")
	GUICtrlCreateLabel("min", 581, 351, 30, 18)
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	; ---- Events ------------------------------------------------------------
	GUICtrlCreateGroup("Events (for ntfy, webhook and command)", 15, 388, $iW - 30, 128)
	Local $idEvReauth = GUICtrlCreateCheckbox("Sign-in required", $xL, 408, 280, 20)
	GUICtrlSetTip($idEvReauth, "An account needs a new sign-in (revoked, expired, password changed), and at the" & @CRLF & _
			"start for every active account that has no sign-in yet." & @CRLF & _
			"INI: [Notify] EventReauth, default: on")
	Local $idEvRefresh = GUICtrlCreateCheckbox("Token renewal failed (twice in a row)", $xL, 432, 280, 20)
	GUICtrlSetTip($idEvRefresh, "The access token could not be renewed twice in a row (e.g. disruption at" & @CRLF & _
			"Microsoft/Google, expired client secret). A single failure is not reported." & @CRLF & _
			"INI: [Notify] EventRefreshFail, default: on")
	Local $idEvRefused = GUICtrlCreateCheckbox("E-mail refused by the mail server", $xL, 456, 280, 20)
	GUICtrlSetTip($idEvRefused, "The real mail server did not accept an e-mail (e.g. ""Send As"" not allowed," & @CRLF & _
			"mailbox full, message too large) - with sender, recipient, subject and the reply." & @CRLF & _
			"INI: [Notify] EventRefused, default: on")
	Local $idEvErrors = GUICtrlCreateCheckbox("Repeated errors (3 within 15 min)", 330, 408, 280, 20)
	GUICtrlSetTip($idEvErrors, "Three error answers of the mail server (or sign-ins it did not answer) for the" & @CRLF & _
			"same account within 15 minutes." & @CRLF & _
			"INI: [Notify] EventErrors, default: on")
	Local $idEvLoop = GUICtrlCreateCheckbox("Proxy blocked for at least", 330, 432, 160, 20)
	GUICtrlSetTip($idEvLoop, "Nothing could be accepted or relayed for at least this long (sent once the" & @CRLF & _
			"block is over; not for a standby of the PC). Needs ""Warning: main loop blocked" & @CRLF & _
			"for"" in the Advanced settings to be on (not 0)." & @CRLF & _
			"INI: [Notify] EventLoopBlock, default: on")
	Local $idLoopSec = GUICtrlCreateInput($g_iNotifyLoopBlockSec, 495, 431, 45, 21, BitOR($GUI_SS_DEFAULT_INPUT, $ES_RIGHT))
	GUICtrlSetTip($idLoopSec, "Seconds (10-3600). INI: [Notify] LoopBlockSec, default: 60")
	GUICtrlCreateLabel("s", 545, 434, 20, 18)
	Local $idEvStart = GUICtrlCreateCheckbox("Proxy started / stopped", 330, 456, 280, 20)
	GUICtrlSetTip($idEvStart, "A message when the program starts and when it is ended via Exit." & @CRLF & _
			"INI: [Notify] EventStartStop, default: on")
	Local $idAllClear = GUICtrlCreateCheckbox("""OK again"" message when a problem is resolved", $xL, 484, 290, 20)
	GUICtrlSetTip($idAllClear, "E.g. ""OK again: Sign-in required"" once the account has been signed in again," & @CRLF & _
			"so you know the problem is gone." & @CRLF & _
			"INI: [Notify] AllClear, default: on")
	GUICtrlCreateLabel("Same message at most every", 330, 487, 160, 18)
	Local $idMinInt = GUICtrlCreateInput($g_iNotifyMinIntervalMin, 495, 484, 45, 21, BitOR($GUI_SS_DEFAULT_INPUT, $ES_RIGHT))
	GUICtrlSetTip($idMinInt, "Rate limit: the same event for the same account is sent at most once in this" & @CRLF & _
			"many minutes (0 = no limit; 0-1440). Prevents a flood of messages during a" & @CRLF & _
			"disruption. INI: [Notify] MinIntervalMin, default: 60")
	GUICtrlCreateLabel("min", 545, 487, 40, 18)
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	; ---- Result of the last test + buttons -----------------------------------
	Local $idResult = GUICtrlCreateEdit("Result of the last test appears here.", 15, 524, $iW - 30, 34, _
			BitOR($ES_MULTILINE, $ES_READONLY, $ES_AUTOVSCROLL, $WS_VSCROLL))
	GUICtrlSetBkColor($idResult, 0xFFFFFF)
	GUICtrlSetTip($idResult, "Result of the last ""Test"" (also written to the log).")
	Local $idSave = GUICtrlCreateButton("Save", $iW - 235, 566, 105, 30)
	GUICtrlSetTip($idSave, "Check the values, save them and use them right away.")
	Local $idCancel = GUICtrlCreateButton("Cancel", $iW - 120, 566, 105, 30)
	GUICtrlSetTip($idCancel, "Close this window and discard all changes (the same as X or Esc).")

	; Current state of the switches
	__NotifySetCheck($idNtfyOn, $g_bNtfyEnabled)
	__NotifySetCheck($idHookOn, $g_bWebhookEnabled)
	__NotifySetCheck($idCmdOn, $g_bCommandEnabled)
	__NotifySetCheck($idHbOn, $g_bHeartbeatEnabled)
	__NotifySetCheck($idEvReauth, $g_oNotifyEventOn.Item("reauth"))
	__NotifySetCheck($idEvRefresh, $g_oNotifyEventOn.Item("refreshfail"))
	__NotifySetCheck($idEvRefused, $g_oNotifyEventOn.Item("refused"))
	__NotifySetCheck($idEvErrors, $g_oNotifyEventOn.Item("errors"))
	__NotifySetCheck($idEvLoop, $g_oNotifyEventOn.Item("loopblock"))
	__NotifySetCheck($idEvStart, $g_oNotifyEventOn.Item("startstop"))
	__NotifySetCheck($idAllClear, $g_bNotifyAllClear)

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	Local $sChannel = "", $sErr = "", $idFocus = 0
	While 1
		Local $nMsg = GUIGetMsg()
		$sChannel = ""
		Switch $nMsg
			Case $GUI_EVENT_CLOSE, $idCancel
				GUIDelete($hGui)
				_DialogClosed()
				Return False

			Case $idHookPreset
				Switch GUICtrlRead($idHookPreset)
					Case "Microsoft Teams (Workflows)"
						GUICtrlSetData($idHookTpl, $NOTIFY_TPL_TEAMS)
					Case "Slack / Mattermost / Rocket.Chat"
						GUICtrlSetData($idHookTpl, $NOTIFY_TPL_SLACK)
					Case "Discord"
						GUICtrlSetData($idHookTpl, $NOTIFY_TPL_DISCORD)
					Case "All fields (Home Assistant, n8n, Node-RED, others)"
						GUICtrlSetData($idHookTpl, $NOTIFY_TPL_ALL)
				EndSwitch

			Case $idNtfyTest
				$sChannel = "ntfy"
			Case $idHookTest
				$sChannel = "webhook"
			Case $idCmdTest
				$sChannel = "command"
			Case $idHbTest
				$sChannel = "heartbeat"

			Case $idSave
				; 1. check (a switched-on channel needs its settings; numbers in range)
				$sErr = ""
				$idFocus = 0
				If __NotifyIsChecked($idNtfyOn) Then __NotifyCheckChannel("ntfy", $idNtfyServer, $idNtfyTopic, $sErr, $idFocus)
				If $sErr = "" And __NotifyIsChecked($idHookOn) Then __NotifyCheckChannel("webhook", $idHookUrl, $idHookTpl, $sErr, $idFocus)
				If $sErr = "" And __NotifyIsChecked($idCmdOn) Then __NotifyCheckChannel("command", $idCmd, 0, $sErr, $idFocus)
				If $sErr = "" And __NotifyIsChecked($idHbOn) Then __NotifyCheckChannel("heartbeat", $idHbUrl, 0, $sErr, $idFocus)
				If $sErr = "" Then __NotifyCheckNumber($idHbInt, "Heartbeat interval (minutes)", 1, 1440, $sErr, $idFocus)
				If $sErr = "" Then __NotifyCheckNumber($idLoopSec, """Proxy blocked for at least"" (seconds)", 10, 3600, $sErr, $idFocus)
				If $sErr = "" Then __NotifyCheckNumber($idMinInt, """Same message at most every"" (minutes)", 0, 1440, $sErr, $idFocus)
				If $sErr <> "" Then
					_ProxyMsgBox(48, "Invalid input", $sErr, $hGui)
					If $idFocus Then GUICtrlSetState($idFocus, $GUI_FOCUS)
					ContinueLoop
				EndIf
				; 2. write the [Notify] section
				IniWrite($g_sIniPath, "Notify", "NtfyEnabled", Number(__NotifyIsChecked($idNtfyOn)))
				IniWrite($g_sIniPath, "Notify", "NtfyServer", StringStripWS(GUICtrlRead($idNtfyServer), 3))
				IniWrite($g_sIniPath, "Notify", "NtfyTopic", StringStripWS(GUICtrlRead($idNtfyTopic), 3))
				IniWrite($g_sIniPath, "Notify", "NtfyTokenEnc", _DPAPI_Protect(StringStripWS(GUICtrlRead($idNtfyToken), 3)))
				IniWrite($g_sIniPath, "Notify", "WebhookEnabled", Number(__NotifyIsChecked($idHookOn)))
				IniWrite($g_sIniPath, "Notify", "WebhookUrlEnc", _DPAPI_Protect(StringStripWS(GUICtrlRead($idHookUrl), 3)))
				IniWrite($g_sIniPath, "Notify", "WebhookTemplate", __NotifyOneLine(GUICtrlRead($idHookTpl)))
				IniWrite($g_sIniPath, "Notify", "CommandEnabled", Number(__NotifyIsChecked($idCmdOn)))
				IniWrite($g_sIniPath, "Notify", "Command", StringStripWS(GUICtrlRead($idCmd), 3))
				IniWrite($g_sIniPath, "Notify", "HeartbeatEnabled", Number(__NotifyIsChecked($idHbOn)))
				IniWrite($g_sIniPath, "Notify", "HeartbeatUrlEnc", _DPAPI_Protect(StringStripWS(GUICtrlRead($idHbUrl), 3)))
				IniWrite($g_sIniPath, "Notify", "HeartbeatIntervalMin", Number(GUICtrlRead($idHbInt)))
				IniWrite($g_sIniPath, "Notify", "LoopBlockSec", Number(GUICtrlRead($idLoopSec)))
				IniWrite($g_sIniPath, "Notify", "MinIntervalMin", Number(GUICtrlRead($idMinInt)))
				IniWrite($g_sIniPath, "Notify", "AllClear", Number(__NotifyIsChecked($idAllClear)))
				IniWrite($g_sIniPath, "Notify", "EventReauth", Number(__NotifyIsChecked($idEvReauth)))
				IniWrite($g_sIniPath, "Notify", "EventRefreshFail", Number(__NotifyIsChecked($idEvRefresh)))
				IniWrite($g_sIniPath, "Notify", "EventRefused", Number(__NotifyIsChecked($idEvRefused)))
				IniWrite($g_sIniPath, "Notify", "EventErrors", Number(__NotifyIsChecked($idEvErrors)))
				IniWrite($g_sIniPath, "Notify", "EventLoopBlock", Number(__NotifyIsChecked($idEvLoop)))
				IniWrite($g_sIniPath, "Notify", "EventStartStop", Number(__NotifyIsChecked($idEvStart)))
				; 3. use them at once
				Local $bHbWasOn = ($g_bHeartbeatEnabled And $g_sHeartbeatUrlEnc <> "")
				_NotifyLoadSettings()
				If Not $bHbWasOn Then $g_hHeartbeatTimer = 0 ; a newly switched-on heartbeat pings right away
				LogFile("Notification settings saved: ntfy " & __NotifyOnOff($g_bNtfyEnabled) & ", webhook " & __NotifyOnOff($g_bWebhookEnabled) & _
						", command " & __NotifyOnOff($g_bCommandEnabled) & ", heartbeat " & __NotifyOnOff($g_bHeartbeatEnabled) & _
						" (every " & $g_iHeartbeatIntervalMin & " min); same message at most every " & $g_iNotifyMinIntervalMin & " min.")
				GUIDelete($hGui)
				_DialogClosed()
				Return True
		EndSwitch

		If $sChannel <> "" Then
			; Test with the values currently in the window
			$sErr = ""
			$idFocus = 0
			Switch $sChannel
				Case "ntfy"
					__NotifyCheckChannel("ntfy", $idNtfyServer, $idNtfyTopic, $sErr, $idFocus)
				Case "webhook"
					__NotifyCheckChannel("webhook", $idHookUrl, $idHookTpl, $sErr, $idFocus)
				Case "command"
					__NotifyCheckChannel("command", $idCmd, 0, $sErr, $idFocus)
				Case "heartbeat"
					__NotifyCheckChannel("heartbeat", $idHbUrl, 0, $sErr, $idFocus)
			EndSwitch
			If $sErr <> "" Then
				_ProxyMsgBox(48, "Invalid input", $sErr, $hGui)
				If $idFocus Then GUICtrlSetState($idFocus, $GUI_FOCUS)
				ContinueLoop
			EndIf
			Local $oCfg = ObjCreate("Scripting.Dictionary")
			$oCfg.Item("NtfyServer") = StringStripWS(GUICtrlRead($idNtfyServer), 3)
			$oCfg.Item("NtfyTopic") = StringStripWS(GUICtrlRead($idNtfyTopic), 3)
			$oCfg.Item("NtfyTokenEnc") = _DPAPI_Protect(StringStripWS(GUICtrlRead($idNtfyToken), 3))
			$oCfg.Item("WebhookUrlEnc") = _DPAPI_Protect(StringStripWS(GUICtrlRead($idHookUrl), 3))
			$oCfg.Item("WebhookTemplate") = __NotifyOneLine(GUICtrlRead($idHookTpl))
			$oCfg.Item("Command") = StringStripWS(GUICtrlRead($idCmd), 3)
			$oCfg.Item("HeartbeatUrlEnc") = _DPAPI_Protect(StringStripWS(GUICtrlRead($idHbUrl), 3))
			GUICtrlSetData($idResult, "Sending a test via " & $sChannel & " ...")
			GUICtrlSetData($idResult, __NotifyRunTest($sChannel, $oCfg, $hGui))
		EndIf

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowNotificationSettingsDialog

; Small helpers of the Notifications dialog

; Y1 (v80): grey hint text shown in an EMPTY input field (EM_SETCUEBANNER) -
; replaces the field labels that no longer fit next to Command / Ping URL.
Func __SetCueBanner($idCtl, $sText)
	DllCall("user32.dll", "lresult", "SendMessageW", "hwnd", GUICtrlGetHandle($idCtl), "uint", 0x1501, "wparam", True, "wstr", $sText)
EndFunc   ;==>__SetCueBanner

; X1 (v78): suggested ntfy topic "<AppName>-" plus 8 random letters/digits
; (62^8, about 2 * 10^14 possibilities - not guessable). Worked out once per
; program run, so the suggestion stays the same when the window is opened
; again before "Save" (e.g. after subscribing to it in the app and then
; cancelling); it is only stored with "Save".
Func __NotifyTopicSuggestion()
	Local Static $sTopic = ""
	If $sTopic <> "" Then Return $sTopic
	Local Const $sChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	Local $sRand = "", $i = 0
	For $i = 1 To 8
		$sRand &= StringMid($sChars, Random(1, StringLen($sChars), 1), 1)
	Next
	$sTopic = $g_sAppName & "-" & $sRand
	Return $sTopic
EndFunc   ;==>__NotifyTopicSuggestion
Func __NotifySetCheck($idCtl, $bOn)
	If $bOn Then
		GUICtrlSetState($idCtl, $GUI_CHECKED)
	Else
		GUICtrlSetState($idCtl, $GUI_UNCHECKED)
	EndIf
EndFunc   ;==>__NotifySetCheck

Func __NotifyIsChecked($idCtl)
	Return (BitAND(GUICtrlRead($idCtl), $GUI_CHECKED) = $GUI_CHECKED)
EndFunc   ;==>__NotifyIsChecked

Func __NotifyOnOff($b)
	If $b Then Return "on"
	Return "off"
EndFunc   ;==>__NotifyOnOff

; Checks the fields a channel needs; sets $sErr and $idFocus on a problem.
Func __NotifyCheckChannel($sChannel, $idMain, $idSecond, ByRef $sErr, ByRef $idFocus)
	Local $sMain = StringStripWS(GUICtrlRead($idMain), 3)
	Switch $sChannel
		Case "ntfy"
			If Not StringRegExp($sMain, "(?i)^https?://[^/\s]+") Then
				$sErr = "ntfy: the server must be an address like https://ntfy.sh."
				$idFocus = $idMain
				Return
			EndIf
			Local $sTopic = StringStripWS(GUICtrlRead($idSecond), 3)
			If Not StringRegExp($sTopic, "^[A-Za-z0-9_-]{1,64}$") Then
				$sErr = "ntfy: please enter a topic (1-64 characters: letters, digits, - and _)."
				$idFocus = $idSecond
			EndIf
		Case "webhook"
			If Not StringRegExp($sMain, "(?i)^https?://[^/\s]+") Then
				$sErr = "Webhook: please enter the webhook URL (https://...)."
				$idFocus = $idMain
				Return
			EndIf
			Local $sTpl = StringStripWS(GUICtrlRead($idSecond), 3)
			If Not StringRegExp($sTpl, "^[\{\[]") Then
				$sErr = "Webhook: the template must be JSON text starting with { (choose a format preset to fill it in)."
				$idFocus = $idSecond
			EndIf
		Case "command"
			If $sMain = "" Then
				$sErr = "Command: please enter the command to run."
				$idFocus = $idMain
			EndIf
		Case "heartbeat"
			If Not StringRegExp($sMain, "(?i)^https?://[^/\s]+") Then
				$sErr = "Heartbeat: please enter the ping URL (https://...)."
				$idFocus = $idMain
			EndIf
	EndSwitch
EndFunc   ;==>__NotifyCheckChannel

; Checks a whole number in a field; sets $sErr and $idFocus on a problem.
Func __NotifyCheckNumber($idCtl, $sName, $iMin, $iMax, ByRef $sErr, ByRef $idFocus)
	Local $s = StringStripWS(GUICtrlRead($idCtl), 3)
	If Not StringRegExp($s, "^[0-9]+$") Or Number($s) < $iMin Or Number($s) > $iMax Then
		$sErr = $sName & ": please enter a whole number from " & $iMin & " to " & $iMax & "."
		$idFocus = $idCtl
	EndIf
EndFunc   ;==>__NotifyCheckNumber

; ############################################################################
; #  ADVANCED SETTINGS DIALOG (tray menu: Settings > Advanced)
; ############################################################################

; ============================================================================
; _ShowAdvancedSettingsDialog
; ----------------------------------------------------------------------------
; Description : Q1: dialog for the [General] INI settings that have no other
;               place in the user interface (opened by the "Advanced"
;               item of the tray menu's Settings submenu, since v61): logging, ports, connections
;               and time limits, monitoring. The low-level performance
;               settings (MainLoopTickMs, AcceptCheckIntervalMs,
;               RelayPollMs, TcpTimeoutMs) are deliberately NOT offered -
;               they stay INI-only.
;               All fields are described in one table (__AdvAddField()):
;               INI key, label, kind of control, unit, default, allowed
;               range and tooltip - the dialog, the check on "Save" and the
;               "Defaults" button all work from it, so the three can never
;               disagree. Times stored in milliseconds are shown in
;               seconds (decimals allowed, e.g. 0.5).
;               "Save": every value is checked against the same range that
;               _LoadGeneralSettings() uses; an invalid value is reported
;               with its field name and allowed range, and the dialog
;               stays open. Otherwise the changed keys are written to the
;               INI, a log line lists them (old -> new), and
;               _LoadGeneralSettings() is called, so the running program
;               uses the new values at once. "Cancel" / the window's X /
;               Escape discard all changes. "Defaults" only fills the
;               fields with the default values - nothing is saved until
;               "Save".
;               Settings that only matter at a certain moment take effect
;               then: "Clear ... on start" at the next start, "Relay
;               helper debug log" for new connections, the port suggestion
;               for the next new account / sign-in.
; Parameters  : $hParent - Optional owner window (0 when opened from the tray menu).
; Returns     : True if settings were saved, False otherwise.
; ============================================================================
Func _ShowAdvancedSettingsDialog($hParent = 0)
	Local $aF[20][13], $n = 0
	; ---- 1 Logging -------------------------------------------------------
	__AdvAddField($aF, $n, "UseLogFile", "Write a log file", "chk", 1, 1, 0, 1, False, "", 1, _
			"Write the program's log to log\" & $g_sAppName & ".log next to the program." & @CRLF & _
			"Recommended: on. Without a log, problems can hardly be traced afterwards." & @CRLF & _
			"(The program switches this off by itself for the current session if the" & @CRLF & _
			"file cannot be written - ticking it again here switches it back on.)" & @CRLF & _
			"INI: [General] UseLogFile, default: on")
	__AdvAddField($aF, $n, "LogLevel", "Log detail level", "lvl", 1, 5, 0, 9, False, "", 1, _
			"How much is written to the log:" & @CRLF & _
			"  0-5  normal operation (default 5): start/stop, connections with their summary," & @CRLF & _
			"       e-mails sent, token refreshes, warnings and errors (also errors of the" & @CRLF & _
			"       PowerShell helpers)" & @CRLF & _
			"  6    plus details: every SMTP command (passwords and tokens are always hidden)" & @CRLF & _
			"       and every line of the PowerShell helper of a connection (connect, TLS," & @CRLF & _
			"       end with byte totals) - the level for tracking down a problem" & @CRLF & _
			"  8    plus timing measurements (where the time of a slow send goes)" & @CRLF & _
			"  9    everything (debug)" & @CRLF & _
			"Higher levels make the log grow much faster - use them for troubleshooting only." & @CRLF & _
			"When run as an uncompiled script, level 9 is always used." & @CRLF & _
			"INI: [General] LogLevel, default: 5")
	__AdvAddField($aF, $n, "ClearLogOnStart", "Clear the log on every start", "chk", 1, 1, 0, 1, False, "", 1, _
			"Empty the log each time the program starts." & @CRLF & _
			"Switch this OFF while you are tracking down a problem - otherwise a restart" & @CRLF & _
			"deletes exactly the lines that would explain it. Older rotated parts" & @CRLF & _
			"(.1.log, .2.log ...) are never deleted by this." & @CRLF & _
			"Takes effect at the next start." & @CRLF & _
			"INI: [General] ClearLogOnStart, default: on")
	__AdvAddField($aF, $n, "RelayDebugLog", "Log every data block of the helpers", "chk", 1, 0, 0, 1, False, "", 1, _
			"The PowerShell helpers also log a line for every block of data (64 KB)" & @CRLF & _
			"they relay - shown in the log at log detail level 6 or higher. Only for" & @CRLF & _
			"troubleshooting - a large e-mail then produces hundreds of lines." & @CRLF & _
			"Takes effect for new connections." & @CRLF & _
			"INI: [General] RelayDebugLog, default: off")
	__AdvAddField($aF, $n, "MaxLogSizeMB", "Rotate the log at", "num", 1, 10, 1, 1000, True, "MB", 1, _
			"When the log reaches this size, it is renamed to ...1.log (older parts" & @CRLF & _
			"move up to .2, .3, ...) and a new file is started." & @CRLF & _
			"Checked about once a minute. 0 = never rotate (the file then grows without limit)." & @CRLF & _
			"Allowed: 0 or 1-1000 MB. INI: [General] MaxLogSizeMB, default: 10")
	__AdvAddField($aF, $n, "LogGenerations", "Older log parts to keep", "num", 1, 5, 1, 99, False, "", 1, _
			"How many older parts of the log are kept when it is rotated" & @CRLF & _
			"(...1.log is the newest, the highest number the oldest; anything" & @CRLF & _
			"older is deleted)." & @CRLF & _
			"Allowed: 1-99. INI: [General] LogGenerations, default: 5")
	; ---- 2 Ports ---------------------------------------------------------
	__AdvAddField($aF, $n, "SmtpPortStart", "First local SMTP port suggested", "num", 1, 1587, 1024, 65000, False, "", 2, _
			"When a new account is created, the first free local port from this" & @CRLF & _
			"number upwards is suggested for it (it can still be changed there)." & @CRLF & _
			"Existing accounts are not affected." & @CRLF & _
			"Allowed: 1024-65000. INI: [General] SmtpPortStart, default: 1587")
	__AdvAddField($aF, $n, "AuthPortStart", "First port for the browser sign-in", "num", 1, 8462, 1024, 65000, False, "", 2, _
			"For the sign-in in the browser, the program briefly listens on a local" & @CRLF & _
			"port (http://localhost:<port>/) to receive the answer of the sign-in page." & @CRLF & _
			"The first free port from this number upwards is used. Only change it if" & @CRLF & _
			"another program is in the way." & @CRLF & _
			"Allowed: 1024-65000. INI: [General] AuthPortStart, default: 8462")
	; ---- 3 Connections and time limits -----------------------------------
	__AdvAddField($aF, $n, "MaxConnections", "Max. simultaneous connections", "num", 1, 5, 1, 100, True, "", 3, _
			"At most this many devices can be connected to the proxy at the same time" & @CRLF & _
			"(all accounts together). Further devices are refused at once with" & @CRLF & _
			"421 (try again later) - protects against a device that opens connections" & @CRLF & _
			"in a loop. 0 = no limit." & @CRLF & _
			"Allowed: 0 or 1-100. INI: [General] MaxConnections, default: 5")
	__AdvAddField($aF, $n, "AuthResultTimeoutMs", "Wait for the server's sign-in answer", "num", 1000, 20000, 5000, 600000, True, "s", 3, _
			"After a device has logged in, the proxy signs in at the mail server with" & @CRLF & _
			"the OAuth2 token. If the server has not answered after this time (e.g." & @CRLF & _
			"during a disruption of the mail service), the device gets a temporary" & @CRLF & _
			"error (454) so it can try again, instead of running into its own timeout." & @CRLF & _
			"Keep it BELOW the device's own timeout (often 30 s). 0 = wait without limit." & @CRLF & _
			"Allowed: 0 or 5-600 s. INI: [General] AuthResultTimeoutMs, default: 20 s")
	__AdvAddField($aF, $n, "PreAuthTimeoutMs", "Close if no login after", "num", 1000, 60000, 10000, 3600000, True, "s", 3, _
			"A connection that has not completed its login after this time is closed" & @CRLF & _
			"(the device gets 421). Frees the slot of a device that connected and" & @CRLF & _
			"then never logged in. 0 = never." & @CRLF & _
			"Allowed: 0 or 10-3600 s. INI: [General] PreAuthTimeoutMs, default: 60 s")
	__AdvAddField($aF, $n, "IdleCloseMs", "Close idle connection after", "num", 1000, 600000, 60000, 86400000, True, "s", 3, _
			"A signed-in connection with no data in either direction for this long is" & @CRLF & _
			"closed (Microsoft itself closes idle connections after about 10 minutes)." & @CRLF & _
			"0 = never." & @CRLF & _
			"Allowed: 0 or 60-86400 s. INI: [General] IdleCloseMs, default: 600 s")
	__AdvAddField($aF, $n, "HttpTimeoutMs", "Max. wait for the token server", "num", 1000, 15000, 1000, 120000, False, "s", 3, _
			"Longest wait for an answer of the provider's token server (token refresh," & @CRLF & _
			"and the last step of the browser sign-in). If it is exceeded, the refresh" & @CRLF & _
			"counts as failed: a still-valid token keeps being used and the refresh is" & @CRLF & _
			"tried again later. While waiting, the proxy relays nothing (README, section 16, C6)." & @CRLF & _
			"Allowed: 1-120 s. INI: [General] HttpTimeoutMs, default: 15 s")
	__AdvAddField($aF, $n, "AuthRedirectTimeoutSec", "Max. wait for the browser sign-in", "num", 1, 180, 30, 1800, False, "s", 3, _
			"How long the program waits for the sign-in in the browser to be" & @CRLF & _
			"completed (new account, or ""sign-in required"") before giving up." & @CRLF & _
			"Allowed: 30-1800 s. INI: [General] AuthRedirectTimeoutSec, default: 180 s")
	__AdvAddField($aF, $n, "ProactiveRefreshLeadSec", "Renew the access token ahead by", "num", 1, 600, 180, 3000, False, "s", 3, _
			"The access token (valid about 1 hour) is renewed this long BEFORE it" & @CRLF & _
			"expires, in the background - so it does not have to be renewed while" & @CRLF & _
			"an e-mail is being sent, and a failed renewal can be retried in time." & @CRLF & _
			"Allowed: 180-3000 s. INI: [General] ProactiveRefreshLeadSec, default: 600 s")
	; ---- 4 Monitoring (log notes only) -----------------------------------
	__AdvAddField($aF, $n, "StallWatchdogMs", "Note: no login yet after", "num", 1000, 15000, 1000, 600000, False, "s", 4, _
			"Writes a warning to the log (once per connection) if a connection has" & @CRLF & _
			"not completed its login after this time - with the step it is stuck at." & @CRLF & _
			"Only a log note; the connection is not closed (see ""Close if no login after"")." & @CRLF & _
			"Allowed: 1-600 s. INI: [General] StallWatchdogMs, default: 15 s")
	__AdvAddField($aF, $n, "IdleWatchdogMs", "Note: connection idle for", "num", 1000, 120000, 10000, 86400000, False, "s", 4, _
			"Writes a note to the log (repeated at this interval) if a signed-in" & @CRLF & _
			"connection has had no data in either direction for this long." & @CRLF & _
			"Can be normal; only a log note (closing: see ""Close idle connection" & @CRLF & _
			"after"")." & @CRLF & _
			"Allowed: 10-86400 s. INI: [General] IdleWatchdogMs, default: 120 s")
	__AdvAddField($aF, $n, "LoopBlockWarnMs", "Warning: main loop blocked for", "num", 1000, 3000, 500, 600000, True, "s", 4, _
			"Writes a warning ""the main loop was not serviced"" if the program could" & @CRLF & _
			"not serve any connection for this long - with the likely cause (e.g. a slow" & @CRLF & _
			"token refresh, the tray menu being open, PC standby). 0 = off." & @CRLF & _
			"Allowed: 0 or 0.5-600 s. INI: [General] LoopBlockWarnMs, default: 3 s")

	Local $hGui = GUICreate("Advanced settings - " & $g_sAppName, 760, 465, -1, -1, -1, -1, $hParent)
	_SetDialogIcon($hGui)

	; Group boxes: 1 + 2 left, 3 + 4 right.
	Local $aGrpX[5] = [0, 20, 20, 390, 390]
	Local $aGrpY[5] = [0, 15, 250, 15, 250]
	Local $aGrpName[5] = ["", "Logging", "Ports", "Connections and time limits", "Monitoring (notes in the log only)"]
	Local $aGrpRows[5] = [0, 0, 0, 0, 0]
	Local $i = 0, $g = 0
	For $i = 0 To $n - 1
		$aGrpRows[$aF[$i][10]] += 1
	Next
	For $g = 1 To 4
		GUICtrlCreateGroup($aGrpName[$g], $aGrpX[$g], $aGrpY[$g], 350, 28 + $aGrpRows[$g] * 27)
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; close the group
	Next

	Local $aRowInGrp[5] = [0, 0, 0, 0, 0]
	For $i = 0 To $n - 1
		$g = $aF[$i][10]
		Local $iX = $aGrpX[$g] + 12, $iY = $aGrpY[$g] + 22 + $aRowInGrp[$g] * 27
		$aRowInGrp[$g] += 1
		Local $idCtl = 0
		Switch $aF[$i][2]
			Case "chk"
				$idCtl = GUICtrlCreateCheckbox($aF[$i][1], $iX, $iY, 326, 20)
			Case "lvl"
				Local $idLbl1 = GUICtrlCreateLabel($aF[$i][1] & ":", $iX, $iY + 3, 200, 18)
				GUICtrlSetTip($idLbl1, $aF[$i][11])
				$idCtl = GUICtrlCreateCombo("", $iX + 205, $iY, 120, 22, BitOR($CBS_DROPDOWNLIST, $CBS_AUTOHSCROLL))
				GUICtrlSetData($idCtl, "0|1|2|3|4|5 (normal)|6 (commands)|7|8 (timing)|9 (debug)")
			Case Else ; "num"
				Local $idLbl2 = GUICtrlCreateLabel($aF[$i][1] & ":", $iX, $iY + 3, 220, 18)
				GUICtrlSetTip($idLbl2, $aF[$i][11])
				$idCtl = GUICtrlCreateInput("", $iX + 225, $iY, 65, 21, BitOR($GUI_SS_DEFAULT_INPUT, $ES_RIGHT))
				If $aF[$i][9] <> "" Then GUICtrlCreateLabel($aF[$i][9], $iX + 296, $iY + 3, 30, 18)
		EndSwitch
		GUICtrlSetTip($idCtl, $aF[$i][11])
		$aF[$i][12] = $idCtl
		__AdvSetControl($aF, $i, __AdvCurrentValue($aF[$i][0]))
	Next

	Local $idInfo = GUICtrlCreateLabel("Changes take effect as soon as you click ""Save"" (settings that only matter at a certain " & _
			"moment - e.g. clearing the log at the start - at that moment). ""Cancel"" discards all changes. " & _
			"Hover over a setting for a detailed explanation.", 20, 368, 720, 34)
	GUICtrlSetColor($idInfo, 0x505050)

	Local $idDefaults = GUICtrlCreateButton("Defaults", 20, 415, 110, 30)
	GUICtrlSetTip($idDefaults, "Fill every field with its default value." & @CRLF & _
			"Nothing is saved until you click ""Save"".")
	Local $idSave = GUICtrlCreateButton("Save", 510, 415, 110, 30)
	GUICtrlSetTip($idSave, "Check the values, save them to the INI file and use them right away.")
	Local $idClose = GUICtrlCreateButton("Cancel", 630, 415, 110, 30)
	GUICtrlSetTip($idClose, "Close this window and discard all changes" & @CRLF & _
			"(the same as the window's X or the Esc key).")

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	While 1
		Switch GUIGetMsg()
			Case $GUI_EVENT_CLOSE, $idClose
				GUIDelete($hGui)
				_DialogClosed()
				Return False

			Case $idDefaults
				For $i = 0 To $n - 1
					__AdvSetControl($aF, $i, $aF[$i][4])
				Next

			Case $idSave
				; 1. check everything first - nothing is written unless all is valid
				Local $aNew[$n], $sErr = ""
				For $i = 0 To $n - 1
					$aNew[$i] = __AdvReadControl($aF, $i, $sErr)
					If $sErr <> "" Then ExitLoop
				Next
				If $sErr <> "" Then
					_ProxyMsgBox(48, "Invalid value", $sErr, $hGui)
					GUICtrlSetState($aF[$i][12], $GUI_FOCUS)
					ContinueLoop
				EndIf
				; 2. write the changed keys and log them (before reloading, so the
				;    line is still written if "Write a log file" was just switched off)
				Local $sChanges = ""
				For $i = 0 To $n - 1
					Local $iOld = __AdvCurrentValue($aF[$i][0])
					If $aNew[$i] <> $iOld Or IniRead($g_sIniPath, "General", $aF[$i][0], "##missing##") <> String($aNew[$i]) Then
						IniWrite($g_sIniPath, "General", $aF[$i][0], $aNew[$i])
						If $aNew[$i] <> $iOld Then $sChanges &= ", " & $aF[$i][0] & " " & $iOld & " -> " & $aNew[$i]
					EndIf
				Next
				If $sChanges <> "" Then
					LogFile("Advanced settings saved: " & StringTrimLeft($sChanges, 2) & ".")
				EndIf
				; 3. take them over into the running program
				$g_sSettingsWarnings = ""
				_LoadGeneralSettings()
				If $g_sSettingsWarnings <> "" Then
					Local $aW = StringSplit(StringTrimRight($g_sSettingsWarnings, 2), @CRLF, 1)
					For $i = 1 To $aW[0]
						LogFile($aW[$i])
					Next
					$g_sSettingsWarnings = ""
				EndIf
				$g_bTooltipDirty = True
				GUIDelete($hGui)
				_DialogClosed()
				Return True
		EndSwitch

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowAdvancedSettingsDialog

; Internal helpers of _ShowAdvancedSettingsDialog() --------------------------
; Field table columns: [0] INI key, [1] label, [2] kind ("chk"/"lvl"/"num"),
; [3] display scale (1000 = stored in ms, shown in s), [4] default, [5] min,
; [6] max, [7] 0 allowed as "off", [8] (unused), [9] unit label, [10] group,
; [11] tooltip, [12] control ID. Values are always in INI units.
Func __AdvAddField(ByRef $aF, ByRef $n, $sKey, $sLabel, $sKind, $iScale, $iDefault, $iMin, $iMax, $bZeroOff, $sUnit, $iGroup, $sTip)
	$aF[$n][0] = $sKey
	$aF[$n][1] = $sLabel
	$aF[$n][2] = $sKind
	$aF[$n][3] = $iScale
	$aF[$n][4] = $iDefault
	$aF[$n][5] = $iMin
	$aF[$n][6] = $iMax
	$aF[$n][7] = $bZeroOff
	$aF[$n][9] = $sUnit
	$aF[$n][10] = $iGroup
	$aF[$n][11] = $sTip
	$n += 1
EndFunc   ;==>__AdvAddField

; The value the running program currently uses, in INI units.
Func __AdvCurrentValue($sKey)
	Switch $sKey
		Case "UseLogFile"
			Return Int($g_bUseLogSetting)
		Case "LogLevel"
			If @Compiled Then Return $g_iLogLevel
			Return _IniReadInt("LogLevel", 5, 0, 9) ; uncompiled the program always uses 9 - show what the INI says
		Case "ClearLogOnStart"
			Return Int($g_bClearLogOnStart)
		Case "RelayDebugLog"
			Return $g_iRelayDebugLog
		Case "MaxLogSizeMB"
			Return $g_iMaxLogSizeMB
		Case "LogGenerations"
			Return $g_iLogGenerations
		Case "SmtpPortStart"
			Return $g_iSmtpPortStart
		Case "AuthPortStart"
			Return $g_iAuthPortStart
		Case "MaxConnections"
			Return $g_iMaxConnections
		Case "AuthResultTimeoutMs"
			Return $g_iAuthResultTimeoutMs
		Case "PreAuthTimeoutMs"
			Return $g_iPreAuthTimeoutMs
		Case "IdleCloseMs"
			Return $g_iIdleCloseMs
		Case "HttpTimeoutMs"
			Return $g_iHttpTimeoutMs
		Case "AuthRedirectTimeoutSec"
			Return $g_iAuthRedirectTimeoutSec
		Case "ProactiveRefreshLeadSec"
			Return $g_iProactiveRefreshLeadSec
		Case "StallWatchdogMs"
			Return $g_iStallWatchdogMs
		Case "IdleWatchdogMs"
			Return $g_iIdleWatchdogMs
		Case "LoopBlockWarnMs"
			Return $g_iLoopBlockWarnMs
	EndSwitch
	Return 0
EndFunc   ;==>__AdvCurrentValue

; Shows a value (INI units) in the field's control.
Func __AdvSetControl(ByRef $aF, $i, $iValue)
	Local $idCtl = $aF[$i][12]
	Switch $aF[$i][2]
		Case "chk"
			If Number($iValue) = 1 Then
				GUICtrlSetState($idCtl, $GUI_CHECKED)
			Else
				GUICtrlSetState($idCtl, $GUI_UNCHECKED)
			EndIf
		Case "lvl"
			Local $aLvl = StringSplit("0|1|2|3|4|5 (normal)|6 (commands)|7|8 (timing)|9 (debug)", "|")
			Local $iLvl = Number($iValue)
			If $iLvl < 0 Or $iLvl > 9 Then $iLvl = 5
			GUICtrlSetData($idCtl, $aLvl[$iLvl + 1])
		Case Else
			GUICtrlSetData($idCtl, __AdvFormatNum($iValue / $aF[$i][3]))
	EndSwitch
EndFunc   ;==>__AdvSetControl

; "20" instead of "20.0", "0.5" stays "0.5".
Func __AdvFormatNum($fValue)
	If $fValue = Int($fValue) Then Return String(Int($fValue))
	Return StringRegExpReplace(StringFormat("%.3f", $fValue), "0+$", "")
EndFunc   ;==>__AdvFormatNum

; Reads and checks a field. Returns the value in INI units; on an invalid
; value sets $sErr to a message for the user (and returns 0).
Func __AdvReadControl(ByRef $aF, $i, ByRef $sErr)
	Local $idCtl = $aF[$i][12]
	Switch $aF[$i][2]
		Case "chk"
			If BitAND(GUICtrlRead($idCtl), $GUI_CHECKED) Then Return 1
			Return 0
		Case "lvl"
			Return Number(StringLeft(GUICtrlRead($idCtl), 1))
	EndSwitch

	Local $iScale = $aF[$i][3], $sUnit = $aF[$i][9]
	Local $sRange = __AdvFormatNum($aF[$i][5] / $iScale) & " - " & __AdvFormatNum($aF[$i][6] / $iScale)
	If $sUnit <> "" Then $sRange &= " " & $sUnit
	If $aF[$i][7] Then $sRange = "0 (off) or " & $sRange
	Local $sRaw = StringReplace(StringStripWS(GUICtrlRead($idCtl), 8), ",", ".")
	Local $sPattern = "^[0-9]+$"
	If $iScale > 1 Then $sPattern = "^[0-9]+(\.[0-9]+)?$"
	If Not StringRegExp($sRaw, $sPattern) Then
		$sErr = """" & $aF[$i][1] & """: """ & GUICtrlRead($idCtl) & """ is not a valid number." & @CRLF & @CRLF & "Allowed: " & $sRange & "."
		Return 0
	EndIf
	Local $iValue = Round(Number($sRaw) * $iScale)
	If $iValue = 0 And $aF[$i][7] Then Return 0
	If $iValue < $aF[$i][5] Or $iValue > $aF[$i][6] Then
		$sErr = """" & $aF[$i][1] & """: " & $sRaw & __AdvUnitSuffix($sUnit) & " is outside the allowed range." & _
				@CRLF & @CRLF & "Allowed: " & $sRange & "."
		Return 0
	EndIf
	Return $iValue
EndFunc   ;==>__AdvReadControl

; " s" / " MB" for an error message, or "" if the field has no unit.
Func __AdvUnitSuffix($sUnit)
	If $sUnit = "" Then Return ""
	Return " " & $sUnit
EndFunc   ;==>__AdvUnitSuffix

; ############################################################################
; #  SEND TEST E-MAIL (Account Settings > "Test E-Mail" - no external mail
; #  client needed)
; ############################################################################
;
; Runs its own SMTP session against the real server (over the same
; PowerShell/TLS helper process used for normal pass-through) purely to
; send a test e-mail. This lets an admin verify that an account's OAuth2
; sign-in actually works - and, with another sender address, whether the
; account may "Send As" e.g. a shared mailbox - without having to configure
; Outlook, Thunderbird, etc. against the local proxy just to test it.

; ============================================================================
; _ShowSendTestEmailDialog
; ----------------------------------------------------------------------------
; Description : Shows a small GUI dialog for sending a test e-mail from
;               one specific, already-selected account (passed in via
;               $sEmail - see _ShowSettingsDialog()'s "Test E-Mail"
;               button, its only caller). The account it signs in with is
;               shown read-only; the sender address ("Sender (From)", S1)
;               and the recipient address are both pre-filled with the
;               account's own address (covering the common case of
;               testing by sending to oneself) and freely editable - a
;               different sender checks whether the account may "Send As"
;               that address (e.g. a shared mailbox); a refusal for that
;               reason gets an explanation added (_SendAsHint()), and
;               Microsoft's long internal diagnostic block is shortened
;               (_ShortenServerReply()). Two independent, combinable
;               options extend the plain test e-mail: "Send large test
;               e-mail" replaces the short body with a large generated
;               text/HTML multipart body (see _BuildTestEmailContent()),
;               and "Attach random file" adds a randomly-generated binary
;               attachment of the size picked in the dropdown next to it
;               (500 KB-20 MB - see _AttachmentSizeLabelToBytes()); the
;               dropdown is disabled until that checkbox is ticked. On
;               "Send test e-mail", keeps the dialog open with its
;               buttons disabled and a "Sending ..." status line visible
;               for the whole (blocking) duration of _SendTestEmail(),
;               rather than closing immediately and leaving the user
;               looking at nothing while the send is still in progress -
;               once it returns, the same status field (a read-only,
;               scrollable text field in bold, S2 - so a long server reply
;               can be read completely and copied) is updated with the
;               outcome, colour-coded green for success or red for
;               failure (including the server's own response text) so
;               the result is visible at a glance, not just from the
;               wording, and also written to the log file. Both buttons
;               are re-enabled afterward so another test can be sent
;               (e.g. to a different recipient) without having to reopen
;               the dialog. The "Close" button (also reachable via the
;               window's own close button) is the only way out - there is
;               no separate result popup to dismiss.
; Parameters  : $sEmail  - E-mail address of the account to send from; must
;               already be a key in $g_oAccountsByEmail.
;               $hParent - Optional owner window handle (see GUICreate()'s
;               own $hWndParent parameter) - _ShowSettingsDialog() passes
;               its own handle here and disables itself for as long as
;               this dialog is open, so Account Settings cannot be
;               interacted with while this one is (see its own header comment).
; Returns     : (nothing)
; ============================================================================
Func _ShowSendTestEmailDialog($sEmail, $hParent = 0)
	If Not $g_oAccountsByEmail.Exists($sEmail) Then
		_ProxyMsgBox(16, "Error", "No such account is configured: " & $sEmail, $hParent)
		Return
	EndIf

	Local $hGui = GUICreate("Send test e-mail - " & $g_sAppName, 520, 400, -1, -1, -1, -1, $hParent)
	_SetDialogIcon($hGui)

	Local $idAccLbl = GUICtrlCreateLabel("Signed in as:", 20, 20, 120, 20)
	Local $idAccVal = GUICtrlCreateLabel($sEmail, 150, 20, 350, 20)
	Local $sAccTip = "The account the proxy signs in with at the mail server (OAuth2)." & @CRLF & _
			"This is always the account selected in Account Settings."
	GUICtrlSetTip($idAccLbl, $sAccTip)
	GUICtrlSetTip($idAccVal, $sAccTip)

	; S1 (v65): sender address - to check whether the account may send with
	; another address, e.g. a shared mailbox ("Send As" in Microsoft 365).
	Local $idFromLbl = GUICtrlCreateLabel("Sender (From):", 20, 55, 120, 20)
	Local $idFrom = GUICtrlCreateInput($sEmail, 150, 53, 350, 22)
	Local $sFromTip = "The sender address of the test e-mail (SMTP ""MAIL FROM"" and the ""From:"" line)." & @CRLF & _
			"Normally the account's own address. Enter another address - e.g. a shared" & @CRLF & _
			"mailbox such as invoices@your-domain - to check whether this account may" & @CRLF & _
			"send AS that address. In Microsoft 365 this needs the ""Send As"" permission" & @CRLF & _
			"for that mailbox (""Send on behalf"" is not enough for SMTP); without it the" & @CRLF & _
			"server refuses the message (e.g. ""554 5.2.252 SendAsDenied"") and the" & @CRLF & _
			"result below explains what to change. See the README, section 9."
	GUICtrlSetTip($idFromLbl, $sFromTip)
	GUICtrlSetTip($idFrom, $sFromTip)

	GUICtrlCreateLabel("Recipient address:", 20, 90, 120, 20)
	Local $idTo = GUICtrlCreateInput($sEmail, 150, 88, 350, 22)
	GUICtrlSetTip($idTo, "The e-mail address the test message will be sent to." & @CRLF & _
			"Pre-filled with the account's own address, to send a test to yourself.")

	Local $idLarge = GUICtrlCreateCheckbox("Send large test e-mail (long text/HTML)", 20, 125, 380, 22)
	GUICtrlSetTip($idLarge, "Replace the short test message with a much larger" & @CRLF & _
			"generated text/HTML e-mail, to test how a big message" & @CRLF & _
			"comes through end to end.")

	Local $idAttach = GUICtrlCreateCheckbox("Attach random file", 20, 153, 160, 22)
	GUICtrlSetTip($idAttach, "Attach a randomly-generated file of the size chosen" & @CRLF & _
			"on the right, to test how attachments of that size" & @CRLF & _
			"come through end to end.")
	Local $idSize = GUICtrlCreateCombo("", 190, 151, 110, 22, BitOR($CBS_DROPDOWNLIST, $CBS_AUTOHSCROLL))
	GUICtrlSetData($idSize, "500 KB|1 MB|5 MB|10 MB|15 MB|20 MB", "1 MB")
	GUICtrlSetState($idSize, $GUI_DISABLE) ; only meaningful once "Attach random file" is checked
	GUICtrlSetTip($idSize, "Size of the random attachment - only used when" & @CRLF & _
			"""Attach random file"" is checked.")

	; Stays empty until "Send test e-mail" is clicked, then shows progress
	; text for the duration of the (blocking) send, and finally the
	; outcome (success or failure, including the server's own response
	; text on failure) once _SendTestEmail() returns - see the $idSend
	; case below.
	; S2 (v66): a read-only, scrollable text field instead of a label, so a
	; long server reply (plus the "Send As" hint) can be read completely -
	; and selected/copied (e.g. into a support request).
	Local $idStatus = GUICtrlCreateEdit("", 20, 190, 480, 150, BitOR($ES_MULTILINE, $ES_READONLY, $ES_AUTOVSCROLL, $WS_VSCROLL))
	GUICtrlSetFont($idStatus, 9, 700)
	GUICtrlSetBkColor($idStatus, 0xFFFFFF)
	GUICtrlSetTip($idStatus, "Progress and result of the test e-mail, including the server's" & @CRLF & _
			"exact reply if it failed. Scroll for long messages; the text can be" & @CRLF & _
			"selected and copied (Ctrl+A, Ctrl+C).")

	Local $idSend = GUICtrlCreateButton("Send test e-mail", 250, 355, 130, 30)
	GUICtrlSetTip($idSend, "Send the test e-mail now with the options above.")
	Local $idClose = GUICtrlCreateButton("Close", 400, 355, 100, 30)
	GUICtrlSetTip($idClose, "Close this window.")

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	While 1
		Local $nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE, $idClose
				GUIDelete($hGui)
				_DialogClosed()
				Return

			Case $idAttach
				If GUICtrlRead($idAttach) = $GUI_CHECKED Then
					GUICtrlSetState($idSize, $GUI_ENABLE)
				Else
					GUICtrlSetState($idSize, $GUI_DISABLE)
				EndIf

			Case $idSend
				Local $sToAddress = StringStripWS(GUICtrlRead($idTo), 3)
				Local $sFromAddress = StringStripWS(GUICtrlRead($idFrom), 3)

				If Not StringRegExp($sToAddress, "^[^@\s]+@[^@\s]+\.[^@\s]+$") Then
					_ProxyMsgBox(48, "Invalid address", "Please enter a valid e-mail address as the recipient.", $hGui)
					ContinueLoop
				EndIf
				If Not StringRegExp($sFromAddress, "^[^@\s]+@[^@\s]+\.[^@\s]+$") Then
					_ProxyMsgBox(48, "Invalid address", "Please enter a valid e-mail address as the sender.", $hGui)
					ContinueLoop
				EndIf
				Local $bSendAs = ($sFromAddress <> $sEmail) ; StringCompare would be case-sensitive; "<>" in AutoIt is not

				Local $oAcc = $g_oAccountsByEmail.Item($sEmail)
				Local $oListener = _FindListenerForAccount($sEmail)
				If Not IsObj($oListener) Then
					_ProxyMsgBox(16, "Error", "No matching listener was found for this account.", $hGui)
					GUIDelete($hGui)
					_DialogClosed()
					Return
				EndIf

				Local $bLargeEmail = (GUICtrlRead($idLarge) = $GUI_CHECKED)
				Local $iAttachmentBytes = 0
				If GUICtrlRead($idAttach) = $GUI_CHECKED Then
					$iAttachmentBytes = _AttachmentSizeLabelToBytes(GUICtrlRead($idSize))
				EndIf

				; _SendTestEmail() below blocks (synchronously) for the
				; whole SMTP session, which can take anywhere from under a
				; second (small plain test e-mail) to several minutes (a
				; large body and/or a multi-megabyte attachment - see
				; _SendTestEmail()'s own header comment for how its final
				; timeout scales with the content size), and itself now
				; calls _ServiceConnections() during its own internal waits
				; (see its header comment) so the proxy keeps working for
				; that whole duration too. Disable both buttons for that
				; duration so neither can be clicked again mid-send, and
				; show a persistent status line; Sleep(100) here gives the
				; GUI a moment to actually repaint that change before the
				; blocking call below starts (AutoIt processes pending
				; window messages, including WM_PAINT, during Sleep()).
				GUICtrlSetState($idSend, $GUI_DISABLE)
				GUICtrlSetState($idClose, $GUI_DISABLE)
				Local $sStatusMsg = "Sending test e-mail - this can take a few seconds, please wait ..."
				If $bLargeEmail Or $iAttachmentBytes > 0 Then
					$sStatusMsg = "Sending large test e-mail - this can take a while depending on your " & _
							"connection speed and the server's own processing time, please wait ..."
				EndIf
				; Reset to the default text colour for the "Sending ..."
				; message itself - a previous attempt in this same dialog
				; may have left it red or green (see below).
				GUICtrlSetColor($idStatus, 0x000000)
				GUICtrlSetData($idStatus, $sStatusMsg)
				Sleep(100)

				Local $iTestEmailTimer = TimerInit()
				Local $sResult = _SendTestEmail($oAcc, $oListener, $sToAddress, $bLargeEmail, $iAttachmentBytes, False, $sFromAddress)
				Local $bFailed = @error
				Local $sTestEmailDuration = _FormatDurationMs(Round(TimerDiff($iTestEmailTimer)))
				LogFile("Timing: _SendTestEmail() to " & $sToAddress & " via " & $sEmail & " took " & _
						$sTestEmailDuration & " overall (see the level-8 timing log lines above this one, from " & _
						"the same connection, for a breakdown of where that time went).", 8)

				; Report the outcome right here in the same dialog, in
				; $idStatus (where the "Sending ..." text was), instead of
				; a separate _ProxyMsgBox() - keeps the whole interaction
				; in one window rather than popping a second one just to
				; show a result the dialog already has room for. Colour-
				; coded (green/red) so success or failure is visible at a
				; glance, not just from the wording. The elapsed time is
				; shown either way - directly useful when troubleshooting
				; a slow send, without having to go find it in the log.
				Local $sSenderInfo = ""
				If $bSendAs Then $sSenderInfo = " with sender " & $sFromAddress
				If $bFailed Then
					; S3: without Microsoft's internal diagnostic block (full text at LogLevel 6)
					Local $sResultShort = _ShortenServerReply($sResult)
					If $sResultShort <> $sResult Then LogFile("Test e-mail: full server reply: " & StringReplace($sResult, @CRLF, " "), 6)
					$sResult = $sResultShort
					LogFile("Test e-mail to " & $sToAddress & " via " & $sEmail & $sSenderInfo & " failed after " & _
							$sTestEmailDuration & ": " & StringReplace($sResult, @CRLF, " "))
					GUICtrlSetColor($idStatus, 0xC00000)
					GUICtrlSetData($idStatus, "Failed after " & $sTestEmailDuration & ":" & @CRLF & StringRegExpReplace($sResult, "(?<!\r)\n", @CRLF))
				Else
					LogFile("Test e-mail to " & $sToAddress & " via " & $sEmail & $sSenderInfo & " sent successfully in " & _
							$sTestEmailDuration & ".")
					GUICtrlSetColor($idStatus, 0x008000)
					If $bSendAs Then
						; Accepted by the server - "Send As" works. (Microsoft checks
						; the permission when the message is submitted, so a refusal
						; would have come back right here as an error.)
						GUICtrlSetData($idStatus, "Success - the server accepted the test e-mail with sender " & $sFromAddress & _
								" (signed in as " & $sEmail & ") in " & $sTestEmailDuration & ". ""Send As"" works. " & _
								"Check in the received e-mail that the sender is shown as " & $sFromAddress & ".")
					Else
						GUICtrlSetData($idStatus, "Success - the test e-mail was sent to " & $sToAddress & " in " & _
								$sTestEmailDuration & ".")
					EndIf
				EndIf

				GUICtrlSetState($idSend, $GUI_ENABLE)
				GUICtrlSetState($idClose, $GUI_ENABLE)
		EndSwitch

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowSendTestEmailDialog

; ============================================================================
; _AttachmentSizeLabelToBytes
; ----------------------------------------------------------------------------
; Description : Maps one of the display labels used in the "Attachment
;               size" dropdown ("500 KB", "1 MB", ...) to the exact byte
;               count _SendTestEmail() should generate, using the
;               conventional 1024-based KB/MB (matching how file sizes are
;               commonly shown elsewhere, e.g. Windows Explorer).
; Parameters  : $sLabel - One of the exact strings used in the dropdown.
; Returns     : The corresponding byte count, or 1 MB's worth of bytes if
;               $sLabel does not match any known option (should not
;               normally happen, since the dropdown only ever offers the
;               known labels).
; ============================================================================
Func _AttachmentSizeLabelToBytes($sLabel)
	Switch $sLabel
		Case "500 KB"
			Return 500 * 1024
		Case "1 MB"
			Return 1 * 1024 * 1024
		Case "5 MB"
			Return 5 * 1024 * 1024
		Case "10 MB"
			Return 10 * 1024 * 1024
		Case "15 MB"
			Return 15 * 1024 * 1024
		Case "20 MB"
			Return 20 * 1024 * 1024
		Case Else
			Return 1 * 1024 * 1024
	EndSwitch
EndFunc   ;==>_AttachmentSizeLabelToBytes

; ============================================================================
; _FindListenerForAccount
; ----------------------------------------------------------------------------
; Description : Looks up the listener dictionary (with ServerAddress /
;               ServerPort / ServerSTARTTLS) that belongs to a given
;               account e-mail address, by scanning $g_oListeners for the
;               one whose associated account's "Username" matches.
; Parameters  : $sEmail - Account e-mail address to search for.
; Returns     : The matching listener dictionary (object), or the integer
;               0 if no listener references this account (check with
;               IsObj() on the caller side).
; ============================================================================
Func _FindListenerForAccount($sEmail)
	Local $aKeys = $g_oListeners.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		Local $oL = $g_oListeners.Item($aKeys[$i])
		If $oL.Item("Account").Item("Username") = $sEmail Then Return $oL
	Next
	Return 0
EndFunc   ;==>_FindListenerForAccount

; ============================================================================
; _SendTestEmail
; ----------------------------------------------------------------------------
; Description : Drives a complete, synchronous (blocking, with per-step
;               timeouts) SMTP session against the real server to deliver
;               one test e-mail: EHLO -> optional STARTTLS -> EHLO
;               again -> AUTH XOAUTH2 -> MAIL FROM -> RCPT TO -> DATA ->
;               QUIT. Uses its own dedicated upstream helper process,
;               completely independent of any active proxy connections.
;               Every failure path closes the helper process (and releases
;               its pipe handles, via _Upstream_Kill()) before returning,
;               so no process or handle is ever leaked. Every
;               failure message includes both WHY the step failed (no
;               response / timed out / helper process ended / server sent
;               an unexpected reply) and, where available, the raw text
;               received from the server up to that point, so the message
;               shown to the user is enough to diagnose the problem without
;               needing to reproduce it with a packet capture.
;               The message content itself is built by
;               _BuildTestEmailContent() - a short, single-part plain-text
;               body by default, or a much larger multipart body and/or a
;               randomly-generated binary attachment if requested (see
;               $bLargeEmail / $iAttachmentBytes). The final step's own
;               timeout (waiting for the server's response to the message
;               content) scales with the content size rather than using
;               the same fixed timeout as every other, always-tiny SMTP
;               command - a multi-megabyte attachment can legitimately
;               take much longer to transfer and be scanned/accepted by
;               the server than a few hundred bytes of plain text can.
; Parameters  : $oAcc             - Account dictionary to send as (must
;               have a valid/refreshable OAuth2 token).
;               $oListener        - Listener dictionary providing
;               ServerAddress/ServerPort/ServerSTARTTLS (see
;               _FindListenerForAccount).
;               $sToAddress       - Recipient e-mail address.
;               $bLargeEmail      - True to use a large generated
;               text/HTML body instead of the normal short one.
;               $iAttachmentBytes - 0 for no attachment, otherwise the
;               size (in bytes) of a randomly-generated binary attachment
;               to include.
;               $bLoginOnly       - True for the connection test in Settings
;               ("Test Connection", see _RunConnectionTest()): stop after
;               the successful XOAUTH2 sign-in, send QUIT and return "OK"
;               without sending an e-mail.
;               $sFromAddress     - S1 (v65): sender address (MAIL FROM and
;               the From: header). "" = the account's own address. A
;               different address (e.g. a shared mailbox) only works if
;               the account has the "Send As" permission for it - this is
;               what the "Sender" field of the test dialog checks.
; Returns     : "OK" on success (with @error = 0).
;               On failure: a human-readable error message
;               describing what went wrong, including the raw server
;               response when one was received, with @error set to a
;               non-zero diagnostic code (1-12, see the individual Return
;               statements below for what each one means).
; ============================================================================
Func _SendTestEmail($oAcc, $oListener, $sToAddress, $bLargeEmail = False, $iAttachmentBytes = 0, $bLoginOnly = False, $sFromAddress = "")
	If $sFromAddress = "" Then $sFromAddress = $oAcc.Item("Username")
	LogFile("=== _SendTestEmail START: account=" & $oAcc.Item("Username") & " recipient=" & $sToAddress & _
			" largeEmail=" & $bLargeEmail & " attachmentBytes=" & $iAttachmentBytes & " ===", 6)
	; See the matching comment in _AcceptNewConnections() for why this is
	; inverted from ServerSTARTTLS - implicit TLS and STARTTLS are the two
	; mutually exclusive ways a connection can end up encrypted, so
	; "STARTTLS not in use" is exactly when implicit TLS is needed instead.
	Local $bImplicit = (Number($oListener.Item("ServerSTARTTLS")) = 0)
	Local $iPID = _Upstream_Start($oListener.Item("ServerAddress"), $oListener.Item("ServerPort"), $bImplicit)
	If Not $iPID Then Return SetError(1, 0, "Could not start the helper process for the server connection.")
	Local $sHelperCtx = "test e-mail"
	If $bLoginOnly Then $sHelperCtx = "connection test"
	_HelperLogRegister($iPID, $sHelperCtx & " | " & $oAcc.Item("Username")) ; M1

	Local $sBuf = ""
	Local $sLine = ""
	Local $sEhloResp = ""
	Local $iErr = 0

	; Wait for the server greeting
	LogFile("Step: waiting for server greeting ...", 6)
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
	$iErr = @error
	If $iErr Or StringLeft($sLine, 1) <> "2" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(2, 0, "No server greeting received: " & _ReadErrorText($iErr) & @CRLF & _
					"Server: " & $oListener.Item("ServerAddress") & ":" & $oListener.Item("ServerPort"))
		Else
			Return SetError(2, 0, "No valid server greeting received." & @CRLF & "Server response: " & $sLine)
		EndIf
	EndIf

	; First EHLO
	LogFile("Step: sending EHLO ...", 6)
	_Upstream_Write($iPID, "EHLO " & $g_sAppName & @CRLF)
	$sEhloResp = _Upstream_ReadEhloBlocking($iPID, $sBuf)
	$iErr = @error
	If $iErr Then
		_Upstream_Kill($iPID)
		Return SetError(3, 0, "Server did not respond to EHLO as expected: " & _ReadErrorText($iErr) & @CRLF & _
				"Received so far:" & @CRLF & $sEhloResp)
	EndIf
	LogFile("EHLO response received in full.", 6)

	; Negotiate STARTTLS if required, then send EHLO again (same as during
	; normal proxy operation)
	If Not $bImplicit Then
		LogFile("Step: sending STARTTLS ...", 6)
		_Upstream_Write($iPID, "STARTTLS" & @CRLF)
		$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
		$iErr = @error
		If $iErr Or StringLeft($sLine, 3) <> "220" Then
			_Upstream_Kill($iPID)
			If $iErr Then
				Return SetError(4, 0, "STARTTLS: " & _ReadErrorText($iErr))
			Else
				Return SetError(4, 0, "STARTTLS was rejected by the server." & @CRLF & "Server response: " & $sLine)
			EndIf
		EndIf

		LogFile("Step: TLS upgrade (sending sentinel to helper process) ...", 6)
		_Upstream_Write($iPID, $SENTINEL & @CRLF)
		$sBuf = ""

		LogFile("Step: sending EHLO again (after TLS upgrade) ...", 6)
		_Upstream_Write($iPID, "EHLO " & $g_sAppName & @CRLF)
		$sEhloResp = _Upstream_ReadEhloBlocking($iPID, $sBuf)
		$iErr = @error
		If $iErr Then
			_Upstream_Kill($iPID)
			Return SetError(5, 0, "Server did not respond to EHLO as expected after STARTTLS: " & _ReadErrorText($iErr) & @CRLF & _
					"Received so far:" & @CRLF & $sEhloResp)
		EndIf
		LogFile("EHLO response after TLS upgrade received in full.", 6)
	EndIf

	; OAuth2 sign-in
	LogFile("Step: sending AUTH XOAUTH2 ...", 6)
	_Upstream_Write($iPID, "AUTH XOAUTH2" & @CRLF)
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
	$iErr = @error
	If $iErr Or StringLeft($sLine, 3) <> "334" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(6, 0, "AUTH XOAUTH2: " & _ReadErrorText($iErr))
		Else
			Return SetError(6, 0, "Server did not respond to AUTH XOAUTH2 as expected." & @CRLF & "Server response: " & $sLine)
		EndIf
	EndIf

	LogFile("Step: fetching/refreshing access token ...", 6)
	Local $iTokenTimer = TimerInit()
	Local $sAccessToken = _Auth_GetValidAccessToken($oAcc)
	; Level 8: same timing this connection's real counterpart logs in
	; _OnServerLine() (see its own comment there) - lets a slow test send
	; be narrowed down the same way a slow real one can be.
	LogFile("Timing: obtaining a valid access token for " & $oAcc.Item("Username") & " took " & _
			_FormatDurationMs(Round(TimerDiff($iTokenTimer))) & ".", 8)
	If $sAccessToken = "" Then
		_Upstream_Kill($iPID)
		Return SetError(7, 0, "No valid access token available. Please sign in to the account again via the tray menu.")
	EndIf

	LogFile("Step: sending XOAUTH2 credentials ...", 6)
	Local $sXOAuth = _BuildXOAuth2String($oAcc.Item("Username"), $sAccessToken)
	Local $iXOAuth2Timer = TimerInit()
	_Upstream_Write($iPID, $sXOAuth & @CRLF)
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
	$iErr = @error
	If $iErr Or StringLeft($sLine, 3) <> "235" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(8, 0, "Signing in to the server: " & _ReadErrorText($iErr))
		Else
			Return SetError(8, 0, "Sign-in to the server failed." & @CRLF & "Server response: " & $sLine)
		EndIf
	EndIf
	LogFile("Timing: server confirmed XOAUTH2 sign-in " & _FormatDurationMs(Round(TimerDiff($iXOAuth2Timer))) & _
			" after the credentials were sent.", 8)
	LogFile("SMTP sign-in successful.", 6)

	; E9: connection test - stop here, after a successful sign-in
	If $bLoginOnly Then
		_Upstream_Write($iPID, "QUIT" & @CRLF)
		Sleep(200)
		_Upstream_Kill($iPID)
		LogFile("=== _SendTestEmail (login only) SUCCESSFUL ===", 6)
		Return "OK"
	EndIf

	; Actual test e-mail
	LogFile("Step: sending MAIL FROM ...", 6)
	_Upstream_Write($iPID, "MAIL FROM:<" & $sFromAddress & ">" & @CRLF)
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
	$iErr = @error
	If $iErr Or StringLeft($sLine, 1) <> "2" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(9, 0, "MAIL FROM: " & _ReadErrorText($iErr))
		Else
			Return SetError(9, 0, "MAIL FROM was rejected by the server." & @CRLF & "Server response: " & $sLine & _SendAsHint($sLine, $sFromAddress, $oAcc.Item("Username")))
		EndIf
	EndIf

	LogFile("Step: sending RCPT TO ...", 6)
	_Upstream_Write($iPID, "RCPT TO:<" & $sToAddress & ">" & @CRLF)
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
	$iErr = @error
	If $iErr Or StringLeft($sLine, 1) <> "2" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(10, 0, "RCPT TO: " & _ReadErrorText($iErr))
		Else
			Return SetError(10, 0, "RCPT TO was rejected by the server." & @CRLF & "Server response: " & $sLine)
		EndIf
	EndIf

	LogFile("Step: sending DATA ...", 6)
	_Upstream_Write($iPID, "DATA" & @CRLF)
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, 15000)
	$iErr = @error
	If $iErr Or StringLeft($sLine, 3) <> "354" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(11, 0, "DATA: " & _ReadErrorText($iErr))
		Else
			Return SetError(11, 0, "DATA was rejected by the server." & @CRLF & "Server response: " & $sLine)
		EndIf
	EndIf

	Local $sMessage = _BuildTestEmailContent($oAcc, $sToAddress, $bLargeEmail, $iAttachmentBytes, $sFromAddress)
	$sMessage &= "." & @CRLF ; the SMTP DATA terminator itself, not part of the message content

	; A fixed 20-second timeout (fine for the few hundred bytes of a plain
	; test e-mail) would be unrealistic for a large body and/or a
	; multi-megabyte attachment - scale it up based on the actual content
	; size, assuming a conservative effective throughput of roughly
	; 100 KB/s (100,000 bytes/s -> 0.01 ms/byte -> bytes/100 = ms) to
	; account for slow connections and server-side content scanning, with
	; a 10-minute cap as a sane upper bound. E.g. a 20 MB attachment
	; (~27 MB once base64-encoded) gets roughly 20s + 270s =~ 4.8 minutes.
	; Only this one step scales this way - every other SMTP command in
	; this function keeps its own fixed 15s timeout, since none of them
	; ever carry more than a few bytes regardless of e-mail size.
	Local $iDataTimeoutMs = 20000 + Int(StringLen($sMessage) / 100)
	If $iDataTimeoutMs > 600000 Then $iDataTimeoutMs = 600000

	LogFile("Step: sending message body (" & StringLen($sMessage) & " characters, timeout " & $iDataTimeoutMs & "ms) ...", 6)
	; Unlike a real relayed e-mail (see _SniffClientData()/_SniffServerData()),
	; there is no separate "client -> proxy" leg to measure here - the
	; message content is generated locally (_BuildTestEmailContent()), so
	; this one timer covers writing it to the upstream helper's stdin AND
	; waiting for the real server's response, together.
	Local $iDataTimer = TimerInit()
	; M1: written in blocks of 64 KB, emptying the helper's stderr pipe in
	; between - with RelayDebugLog=1 the helper writes a log line per block
	; it receives, and if nobody read them while a large message is being
	; written, its stderr pipe could fill up and both sides would wait for
	; each other.
	Local $iMsgPos = 1
	While $iMsgPos <= StringLen($sMessage)
		_Upstream_Write($iPID, StringMid($sMessage, $iMsgPos, 65536))
		$iMsgPos += 65536
		_HelperStderrDrain($iPID)
	WEnd
	$sLine = _Upstream_ReadLineBlocking($iPID, $sBuf, $iDataTimeoutMs)
	$iErr = @error
	LogFile("Timing: sending the message body and receiving the server's response took " & _
			_FormatDurationMs(Round(TimerDiff($iDataTimer))) & ".", 8)
	If $iErr Or StringLeft($sLine, 1) <> "2" Then
		_Upstream_Kill($iPID)
		If $iErr Then
			Return SetError(12, 0, "Sending the message: " & _ReadErrorText($iErr))
		Else
			Return SetError(12, 0, "The message was rejected by the server." & @CRLF & "Server response: " & $sLine & _SendAsHint($sLine, $sFromAddress, $oAcc.Item("Username")))
		EndIf
	EndIf

	LogFile("Step: sending QUIT and closing the helper process ...", 6)
	_Upstream_Write($iPID, "QUIT" & @CRLF)
	Sleep(200)
	_Upstream_Kill($iPID)

	LogFile("=== _SendTestEmail SUCCESSFUL ===", 6)
	Return "OK"
EndFunc   ;==>_SendTestEmail

; ============================================================================
; _SendAsHint
; ----------------------------------------------------------------------------
; Description : S1: if a server reply says the account may not send with
;               this sender address (Microsoft 365: "SendAsDenied",
;               5.2.252, 5.7.60 "...permissions to send as this sender"),
;               returns a short explanation of what is missing and how to
;               fix it - otherwise "". Used by the test e-mail and by the
;               "did NOT accept the e-mail" log line of real traffic.
; Parameters  : $sReply   - The server's reply line.
;               $sSender  - The sender address used ("" if unknown).
;               $sAccount - The account (sign-in) address.
; Returns     : The hint text (starting with a line break) or "".
; ============================================================================
Func _SendAsHint($sReply, $sSender, $sAccount)
	If Not StringRegExp($sReply, "(?i)SendAsDenied|5\.2\.252|5\.7\.60|send as this sender|not authorized to send") Then Return ""
	Local $sWho = "this sender address"
	If $sSender <> "" Then $sWho = $sSender
	Return @CRLF & @CRLF & "Hint: the account " & $sAccount & " is not allowed to send as " & $sWho & ". In Microsoft 365, " & _
			"give it the ""Send As"" permission for that mailbox (Exchange admin center: Recipients -> Mailboxes -> " & $sWho & _
			" -> Delegation -> Send as) and wait up to about an hour. ""Send on behalf"" is not enough for SMTP. See the README, section 9."
EndFunc   ;==>_SendAsHint

; ============================================================================
; _ShortenServerReply
; ----------------------------------------------------------------------------
; Description : S3: Microsoft 365 appends several KB of internal diagnostic
;               codes to some error replies ("[BeginDiagnosticData] ...
;               [EndDiagnosticData]") - meaningless to a user and making
;               the actual reason hard to find. This replaces that block
;               by a short note with its length. The full reply is still
;               written to the log at LogLevel 6 by the callers.
; Parameters  : $sText - Server reply (or a message containing it).
; Returns     : The shortened text (unchanged if there is no such block).
; ============================================================================
Func _ShortenServerReply($sText)
	Local $aM = StringRegExp($sText, "(?s)\[BeginDiagnosticData\](.*?)\[EndDiagnosticData\]", 1)
	If @error Then Return $sText
	Return StringRegExpReplace($sText, "(?s)\[BeginDiagnosticData\].*?\[EndDiagnosticData\]", _
			"[Microsoft diagnostic data (" & StringLen($aM[0]) & " characters) omitted]")
EndFunc   ;==>_ShortenServerReply

; ============================================================================
; _BuildTestEmailContent
; ----------------------------------------------------------------------------
; Description : Builds the complete RFC 5322 message (headers + body,
;               dot-stuffed and ready to send, but WITHOUT the final
;               SMTP DATA terminator line - the caller, _SendTestEmail(),
;               appends that itself) for a test e-mail. Four shapes,
;               depending on the two parameters:
;                 - Neither: a single text/plain part (the original,
;                   short test e-mail body - unchanged from before these
;                   options existed).
;                 - $bLargeEmail only: multipart/alternative with a large
;                   generated text/plain part and a matching text/html
;                   part (see _GenerateLoremText()/_GenerateLoremHtml()),
;                   each around $LARGE_TEST_EMAIL_BODY_BYTES bytes.
;                 - $iAttachmentBytes only: multipart/mixed with the
;                   normal short text/plain body as the first part, and a
;                   randomly-generated binary attachment (see
;                   _BuildAttachmentPart()) as the second.
;                 - Both: multipart/mixed containing a nested
;                   multipart/alternative (as above) as its first part,
;                   plus the binary attachment as its second - the
;                   standard MIME shape for "HTML e-mail with an
;                   attachment".
;               MIME part boundaries are built from _RandomToken(), so
;               they cannot coincidentally collide with generated content.
; Parameters  : $oAcc             - Account dictionary (used for the
;               "From" header).
;               $sToAddress       - Recipient e-mail address.
;               $bLargeEmail      - True to use the large text/HTML body.
;               $iAttachmentBytes - 0 for no attachment, otherwise the
;               size (in bytes) of a randomly-generated attachment to
;               include.
; Returns     : The complete, dot-stuffed message content (headers +
;               blank line + body), without the final ".", ready to be
;               followed by "." & @CRLF and sent as-is.
; ============================================================================
Func _BuildTestEmailContent($oAcc, $sToAddress, $bLargeEmail, $iAttachmentBytes, $sFromAddress = "")
	Local $sNow = _UtcTimestamp()
	Local $sFrom = $oAcc.Item("Username")
	If $sFromAddress <> "" Then $sFrom = $sFromAddress ; S1: sender may differ from the account ("Send As")

	Local $sSubject = "Test e-mail from " & $g_sAppName
	If $bLargeEmail Then $sSubject &= " (large)"
	If $iAttachmentBytes > 0 Then $sSubject &= " (with attachment)"

	Local $sHeaders = ""
	$sHeaders &= "From: " & $sFrom & @CRLF
	$sHeaders &= "To: " & $sToAddress & @CRLF
	$sHeaders &= "Subject: " & $sSubject & @CRLF
	$sHeaders &= "Date: " & _RfcDate() & @CRLF
	$sHeaders &= "MIME-Version: 1.0" & @CRLF

	; Plain-text body always exists (used standalone for the simple case,
	; and as the "text/plain" alternative whenever a large/HTML body is
	; requested) - keeps every generated e-mail readable even in a client
	; that cannot render HTML.
	Local $sPlainBody = "This is a test e-mail from " & $g_sAppName & "." & @CRLF & _
			"Sent on " & $sNow & " (UTC) via account " & $oAcc.Item("Username") & ", sender (From): " & $sFrom & "." & @CRLF & _
			"If this e-mail arrived, the SMTP sign-in via OAuth2 is working correctly." & @CRLF
	If $bLargeEmail Then $sPlainBody &= @CRLF & _GenerateLoremText($LARGE_TEST_EMAIL_BODY_BYTES)

	; windows-1252 matches the ANSI encoding _Upstream_Write() uses, so any
	; non-ASCII characters in the (fixed, English) generated text stay
	; readable - not that any actually occur in it.
	Local $sBodyPart = ""
	If $bLargeEmail Then
		Local $sHtmlBody = _GenerateLoremHtml($sNow, $sFrom)
		Local $sAltBoundary = "alt-" & _RandomToken(12)
		$sBodyPart &= "Content-Type: multipart/alternative; boundary=""" & $sAltBoundary & """" & @CRLF & @CRLF
		$sBodyPart &= "--" & $sAltBoundary & @CRLF
		$sBodyPart &= "Content-Type: text/plain; charset=windows-1252" & @CRLF & @CRLF
		$sBodyPart &= $sPlainBody & @CRLF
		$sBodyPart &= "--" & $sAltBoundary & @CRLF
		$sBodyPart &= "Content-Type: text/html; charset=windows-1252" & @CRLF & @CRLF
		$sBodyPart &= $sHtmlBody & @CRLF
		$sBodyPart &= "--" & $sAltBoundary & "--" & @CRLF
	Else
		$sBodyPart &= "Content-Type: text/plain; charset=windows-1252" & @CRLF & @CRLF
		$sBodyPart &= $sPlainBody
	EndIf

	Local $sFullMessage = ""
	If $iAttachmentBytes > 0 Then
		Local $sMixedBoundary = "mixed-" & _RandomToken(12)
		Local $sTextSection = $sHeaders
		$sTextSection &= "Content-Type: multipart/mixed; boundary=""" & $sMixedBoundary & """" & @CRLF & @CRLF
		$sTextSection &= "--" & $sMixedBoundary & @CRLF
		$sTextSection &= $sBodyPart & @CRLF
		$sTextSection &= "--" & $sMixedBoundary & @CRLF
		; Dot-stuff only the headers/text section here - the base64
		; attachment content below can never need it (its alphabet does
		; not include ".") and running a regex pass over what can be a
		; many-megabyte string was needless overhead (and a source of
		; uncertainty while tracking down why attachments were coming
		; through empty) this sidesteps entirely.
		$sFullMessage &= _DotStuffBody($sTextSection)
		$sFullMessage &= _BuildAttachmentPart($iAttachmentBytes) & @CRLF
		$sFullMessage &= "--" & $sMixedBoundary & "--" & @CRLF
	Else
		$sFullMessage &= _DotStuffBody($sHeaders & $sBodyPart)
	EndIf

	Return $sFullMessage
EndFunc   ;==>_BuildTestEmailContent

; ============================================================================
; _BuildAttachmentPart
; ----------------------------------------------------------------------------
; Description : Builds one MIME body part (headers + base64-encoded
;               content) containing a randomly-generated binary
;               attachment of the requested size. The random bytes come
;               from _GenerateRandomBytes() - a native Win32 CryptoAPI
;               call filling the whole buffer at once, not an AutoIt-
;               level per-byte loop, so generating even a 20 MB
;               attachment takes a moment rather than however long
;               millions of interpreted loop iterations would.
; Parameters  : $iAttachmentBytes - Size, in bytes, of the random content
;               to generate (before base64 encoding, which inflates it by
;               roughly a third).
; Returns     : The complete MIME part (its own Content-Type/
;               Content-Transfer-Encoding/Content-Disposition headers, a
;               blank line, then the base64-encoded content) - WITHOUT a
;               leading or trailing boundary line, which the caller adds.
; ============================================================================
Func _BuildAttachmentPart($iAttachmentBytes)
	LogFile("_BuildAttachmentPart: generating " & $iAttachmentBytes & " random byte(s) ...", 6)
	Local $bRandom = _GenerateRandomBytes($iAttachmentBytes)
	If @error Or BinaryLen($bRandom) <> $iAttachmentBytes Then
		LogFile("Error: _GenerateRandomBytes() did not return the expected " & $iAttachmentBytes & _
				" byte(s) (got " & BinaryLen($bRandom) & ") - the test e-mail's attachment will be missing or wrong-sized.")
	EndIf

	Local $sFileName = "random_" & $iAttachmentBytes & "_bytes.bin"
	LogFile("_BuildAttachmentPart: base64-encoding ...", 6)
	Local $sEncoded = _Base64EncodeMime($bRandom)

	Local $sPart = ""
	$sPart &= "Content-Type: application/octet-stream; name=""" & $sFileName & """" & @CRLF
	$sPart &= "Content-Transfer-Encoding: base64" & @CRLF
	$sPart &= "Content-Disposition: attachment; filename=""" & $sFileName & """" & @CRLF
	$sPart &= @CRLF
	$sPart &= $sEncoded
	Return $sPart
EndFunc   ;==>_BuildAttachmentPart

; ============================================================================
; _DotStuffBody
; ----------------------------------------------------------------------------
; Description : Applies SMTP "dot-stuffing" (RFC 5321 section 4.5.2): any
;               content line that starts with a "." gets a second "."
;               prepended, so the DATA terminator (a line consisting of
;               exactly one ".") can never be confused with actual
;               message content that happens to start the same way. The
;               original short, fixed test e-mail body never had a line
;               starting with "." so this was never needed before, but
;               the large generated text/HTML body (and, in principle,
;               any future free-form content) could plausibly start a
;               line with one by coincidence.
; Parameters  : $sContent - Message content (headers + body) to stuff.
; Returns     : The dot-stuffed content.
; ============================================================================
Func _DotStuffBody($sContent)
	Return StringRegExpReplace($sContent, "(?m)^\.", "..")
EndFunc   ;==>_DotStuffBody

; ============================================================================
; _GenerateLoremText
; ----------------------------------------------------------------------------
; Description : Generates filler plain text (repeated Lorem-Ipsum-style
;               paragraphs, each numbered) up to approximately
;               $iTargetBytes. Used for the "large test e-mail" option's
;               plain-text part/fallback.
; Parameters  : $iTargetBytes - Approximate size, in bytes, to generate
;               (the actual result is that size rounded up to the next
;               whole paragraph).
; Returns     : The generated text.
; ============================================================================
Func _GenerateLoremText($iTargetBytes)
	Local $sParagraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod " & _
			"tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis " & _
			"nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis " & _
			"aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat " & _
			"nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui " & _
			"officia deserunt mollit anim id est laborum." & @CRLF & @CRLF

	Local $sResult = ""
	Local $iParaNum = 1
	While StringLen($sResult) < $iTargetBytes
		$sResult &= "Paragraph " & $iParaNum & ":" & @CRLF & $sParagraph
		$iParaNum += 1
	WEnd
	Return $sResult
EndFunc   ;==>_GenerateLoremText

; ============================================================================
; _GenerateLoremHtml
; ----------------------------------------------------------------------------
; Description : Generates a filler HTML document (heading, intro
;               paragraphs, then a repeated table of Lorem-Ipsum-style
;               rows) up to approximately $LARGE_TEST_EMAIL_BODY_BYTES.
;               Used for the "large test e-mail" option's text/html part.
; Parameters  : $sTimestamp - UTC timestamp string to show in the intro
;               text (see _UtcTimestamp()).
;               $sFrom      - Sender e-mail address to show in the intro
;               text.
; Returns     : The generated HTML document.
; ============================================================================
Func _GenerateLoremHtml($sTimestamp, $sFrom)
	Local $sHtml = "<html><head><meta charset='windows-1252'><title>Test e-mail</title></head>" & _
			"<body style='font-family:sans-serif'>"
	$sHtml &= "<h1>Test e-mail from " & $g_sAppName & "</h1>"
	$sHtml &= "<p>Sent on " & $sTimestamp & " (UTC) via account <b>" & $sFrom & "</b>.</p>"
	$sHtml &= "<p>If this e-mail arrived <i>and looks like this</i>, HTML rendering and a large " & _
			"message body both work correctly.</p>"
	$sHtml &= "<table border='1' cellpadding='4'><tr><th>#</th><th>Lorem ipsum</th></tr>"

	Local $iRow = 1
	While StringLen($sHtml) < $LARGE_TEST_EMAIL_BODY_BYTES
		$sHtml &= "<tr><td>" & $iRow & "</td><td>Lorem ipsum dolor sit amet, consectetur adipiscing " & _
				"elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</td></tr>"
		$iRow += 1
	WEnd
	$sHtml &= "</table></body></html>"
	Return $sHtml
EndFunc   ;==>_GenerateLoremHtml

; ============================================================================
; _ReadErrorText
; ----------------------------------------------------------------------------
; Description : Translates the numeric @error codes produced by
;               _Upstream_ReadLineBlocking() (1, 2) and
;               _Upstream_ReadEhloBlocking() (1, 2, 10, 11) into a short,
;               human-readable explanation. Used throughout
;               _SendTestEmail() to make failure messages self-explanatory
;               without the reader needing to know the internal error-code
;               scheme.
; Parameters  : $iCode - The numeric @error code to translate.
; Returns     : A short explanation string. Falls back to a generic
;               "unknown error" message (including the raw code) for any
;               code not explicitly handled.
; ============================================================================
Func _ReadErrorText($iCode)
	Switch $iCode
		Case 1
			Return "The connection to the server was interrupted (helper process/TLS connection ended)."
		Case 2
			Return "Timeout - the server did not respond within the waiting period."
		Case 3
			Return "The server sent an excessively long, unterminated line."
		Case 10
			Return "The server responded with an error code instead of the expected 2xx confirmation."
		Case 11
			Return "The server sent an unusually large number of response lines without ever sending the terminating line."
		Case Else
			Return "Unknown internal error (code " & $iCode & ")."
	EndSwitch
EndFunc   ;==>_ReadErrorText

; ============================================================================
; _Upstream_ReadLineBlocking
; ----------------------------------------------------------------------------
; Description : Blocking (bounded by $iTimeoutMs) read of a single
;               CRLF-terminated line from an upstream helper process. Any
;               already-buffered-but-not-yet-consumed bytes from previous
;               calls are kept in $sBuffer (ByRef) between calls, so this
;               can safely be called repeatedly to read a multi-line
;               response one line at a time. Polls StdoutRead() every
;               ~20ms until either a full line is available, the timeout
;               elapses, or the process has terminated - calling
;               _ServiceConnections() on every idle poll, so a
;               _SendTestEmail() waiting here (up to 15 seconds per line,
;               see _Upstream_ReadEhloBlocking()) does not stop the proxy
;               from accepting or relaying other, unrelated mail while it
;               waits; see _ServiceConnections()'s header comment. Every
;               raw chunk received, every completed line, and every
;               timeout/process-gone outcome is echoed live via
;               LogFile().
;               If the helper process has ended, whatever it wrote to stderr
;               is logged (e.g. PowerShell refusing to run the script).
; Parameters  : $iPID       - PID of the upstream helper process to read
;               from.
;               $sBuffer    - ByRef: bytes already read but not yet
;               consumed into a line; updated in place.
;               $iTimeoutMs - Maximum time to wait for a complete line, in
;               milliseconds.
; Returns     : The next complete line (without the trailing CRLF).
;               On timeout: SetError(2, 0, "").
;               If the process is no longer running: SetError(1, 0, "").
;               If more than $MAX_LINE_BUFFER_BYTES accumulate without a
;               CRLF ever appearing: SetError(3, 0, "") (buffer discarded).
; ============================================================================
Func _Upstream_ReadLineBlocking($iPID, ByRef $sBuffer, $iTimeoutMs)
	Local $iStart = TimerInit()
	While 1
		Local $iPos = StringInStr($sBuffer, @CRLF)
		If $iPos > 0 Then
			Local $sLine = StringLeft($sBuffer, $iPos - 1)
			$sBuffer = StringMid($sBuffer, $iPos + 2)
			LogFile("_Upstream_ReadLineBlocking PID=" & $iPID & ": line received: '" & $sLine & "'", 6)
			Return $sLine
		EndIf

		If StringLen($sBuffer) > $MAX_LINE_BUFFER_BYTES Then
			LogFile("_Upstream_ReadLineBlocking PID=" & $iPID & ": buffer exceeded " & $MAX_LINE_BUFFER_BYTES & " bytes without a CRLF - giving up.", 6)
			$sBuffer = ""
			Return SetError(3, 0, "")
		EndIf

		_HelperStderrDrain($iPID) ; M1: keep the helper's stderr pipe empty, write its log lines
		If Not ProcessExists($iPID) Then
			LogFile("_Upstream_ReadLineBlocking PID=" & $iPID & ": process no longer exists (buffer so far: '" & $sBuffer & "').", 6)
			_HelperStderrDrain($iPID)
			Local $sHelperStderr = ""
			If $g_oHelperErrTail.Exists(String($iPID)) Then $sHelperStderr = $g_oHelperErrTail.Item(String($iPID))
			$sHelperStderr = StringStripWS(StringRegExpReplace($sHelperStderr, "[\r\n]+", " | "), 3) ; F3
			If $sHelperStderr <> "" Then LogFile("Helper process (PID " & $iPID & ") ended with error output: " & StringLeft($sHelperStderr, 500))
			Return SetError(1, 0, "")
		EndIf
		If TimerDiff($iStart) > $iTimeoutMs Then
			LogFile("_Upstream_ReadLineBlocking PID=" & $iPID & ": timeout after " & $iTimeoutMs & " ms (buffer so far: '" & $sBuffer & "').", 6)
			Return SetError(2, 0, "")
		EndIf

		Local $bData = StdoutRead($iPID, False, True)
		If Not @error And $bData <> "" Then
			LogFile("_Upstream_ReadLineBlocking PID=" & $iPID & ": " & BinaryLen($bData) & " raw byte(s) received from StdoutRead.", 6)
			$sBuffer &= BinaryToString($bData, 1)
		Else
			If Not _ServiceConnections() Then Sleep(20)
		EndIf
	WEnd
EndFunc   ;==>_Upstream_ReadLineBlocking

; ============================================================================
; _Upstream_ReadEhloBlocking
; ----------------------------------------------------------------------------
; Description : Reads a complete, possibly multi-line SMTP "250" EHLO
;               response from an upstream helper process, one line at a
;               time via _Upstream_ReadLineBlocking(). Stops as soon as a
;               terminal "250 " (space, not dash) line is seen, or bails
;               out immediately if any line does not start with "2"
;               (a server-side error response). A hard cap of 30 lines
;               guards against a runaway/misbehaving server.
; Parameters  : $iPID    - PID of the upstream helper process to read from.
;               $sBuffer - ByRef: shared read buffer, see
;               _Upstream_ReadLineBlocking().
; Returns     : The accumulated response text (each line followed by
;               @CRLF) on success.
;               On failure, still returns whatever was accumulated so far,
;               but with @error set: propagated from
;               _Upstream_ReadLineBlocking() (timeout/process gone), 10 if
;               the server sent a non-2xx response, or 11 if the 30-line
;               safety cap was hit without seeing a terminal line.
; ============================================================================
Func _Upstream_ReadEhloBlocking($iPID, ByRef $sBuffer)
	Local $sAccum = ""
	Local $iMaxLines = 30
	Local $i = 0
	For $i = 1 To $iMaxLines
		Local $sLine = _Upstream_ReadLineBlocking($iPID, $sBuffer, 15000)
		If @error Then Return SetError(@error, 0, $sAccum)
		$sAccum &= $sLine & @CRLF
		If StringLeft($sLine, 1) <> "2" Then Return SetError(10, 0, $sAccum)
		If StringLeft($sLine, 3) = "250" And StringMid($sLine, 4, 1) = " " Then Return $sAccum
	Next
	Return SetError(11, 0, $sAccum)
EndFunc   ;==>_Upstream_ReadEhloBlocking

; ============================================================================
; _RfcDate
; ----------------------------------------------------------------------------
; Description : Builds a valid RFC 5322 "Date:" header value, in UTC
;               (avoids any ambiguity from local time zone / daylight
;               saving time). Reads the current UTC time directly via the
;               Win32 GetSystemTime API.
; Parameters  : (none)
; Returns     : A date string of the form "Www, DD Mon YYYY HH:MM:SS +0000"
;               (e.g. "Sat, 08 Aug 2026 14:23:01 +0000").
; ============================================================================
Func _RfcDate()
	Local $tST = DllStructCreate("ushort wYear;ushort wMonth;ushort wDayOfWeek;ushort wDay;" & _
			"ushort wHour;ushort wMinute;ushort wSecond;ushort wMilliseconds")
	DllCall("kernel32.dll", "none", "GetSystemTime", "struct*", $tST)

	Local $aWeekday[7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
	Local $aMonth[13] = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

	Local $iWd = DllStructGetData($tST, "wDayOfWeek")
	Local $iDay = DllStructGetData($tST, "wDay")
	Local $iMon = DllStructGetData($tST, "wMonth")
	Local $iYear = DllStructGetData($tST, "wYear")
	Local $iHour = DllStructGetData($tST, "wHour")
	Local $iMin = DllStructGetData($tST, "wMinute")
	Local $iSec = DllStructGetData($tST, "wSecond")

	Return $aWeekday[$iWd] & ", " & StringFormat("%02d", $iDay) & " " & $aMonth[$iMon] & " " & $iYear & " " & _
			StringFormat("%02d:%02d:%02d", $iHour, $iMin, $iSec) & " +0000"
EndFunc   ;==>_RfcDate

; ============================================================================
; _UtcTimestamp
; ----------------------------------------------------------------------------
; Description : Builds a "YYYY-MM-DD HH:MM:SS" timestamp in UTC, using the
;               same Win32 GetSystemTime API as _RfcDate() (as opposed to
;               the @YEAR/@MON/.../@SEC macros, which reflect the LOCAL
;               system time zone). Used wherever a UTC timestamp is shown
;               to the user with an explicit "(UTC)" label, so the label
;               is actually accurate regardless of the machine's local
;               time zone or daylight saving setting.
; Parameters  : (none)
; Returns     : A timestamp string of the form "YYYY-MM-DD HH:MM:SS".
; ============================================================================
Func _UtcTimestamp()
	Local $tST = DllStructCreate("ushort wYear;ushort wMonth;ushort wDayOfWeek;ushort wDay;" & _
			"ushort wHour;ushort wMinute;ushort wSecond;ushort wMilliseconds")
	DllCall("kernel32.dll", "none", "GetSystemTime", "struct*", $tST)

	Local $iDay = DllStructGetData($tST, "wDay")
	Local $iMon = DllStructGetData($tST, "wMonth")
	Local $iYear = DllStructGetData($tST, "wYear")
	Local $iHour = DllStructGetData($tST, "wHour")
	Local $iMin = DllStructGetData($tST, "wMinute")
	Local $iSec = DllStructGetData($tST, "wSecond")

	Return $iYear & "-" & StringFormat("%02d", $iMon) & "-" & StringFormat("%02d", $iDay) & " " & _
			StringFormat("%02d:%02d:%02d", $iHour, $iMin, $iSec)
EndFunc   ;==>_UtcTimestamp

; ############################################################################
; #  SETTINGS OVERVIEW (list all accounts, enable/disable, edit, delete)
; ############################################################################

; ============================================================================
; _ShowSettingsDialog
; ----------------------------------------------------------------------------
; Description : Shows the main "Settings" GUI: a table (ListView) listing
;               every configured account side by side - Active, e-mail,
;               provider, local port, upstream server, STARTTLS, whether a
;               local SMTP password is set, and sign-in status - so all
;               accounts' settings can be compared at a glance. The first
;               row is selected automatically when the dialog opens (if
;               there is at least one account), so the action buttons can
;               be used right away without first having to click a row.
;               Selecting a row and clicking "Enable/Disable", "Edit", or
;               "Delete" acts on that one account; "New" opens the
;               existing _ShowAddAccountDialog() wizard unchanged,
;               independent of the current row selection. Double-clicking
;               a row is a shortcut for selecting it and clicking "Edit"
;               - see _WM_NOTIFY_AccountList()'s header comment for why
;               that needs its own lower-level detection instead of an
;               ordinary GUIGetMsg() Case. "Test E-Mail" also
;               requires a row to be selected first - it is passed
;               straight through as the fixed sender to
;               _ShowSendTestEmailDialog($sEmail), which no longer offers
;               its own account picker. "New", "Edit" and "Test E-Mail"
;               all get this dialog's own window handle passed as
;               their $hParent, and this window is disabled
;               (GUISetState(@SW_DISABLE, ...)) for as long as each stays
;               open and re-enabled right after - so Settings cannot be
;               clicked into or otherwise interacted with while one of
;               them is open, rather than just sitting there unresponsive
;               (see _ProxyMsgBox()'s own header comment for the same
;               "AutoIt is single-threaded" reason this matters here too).
;               If "New"/"Edit"/a row double-click is cancelled, or
;               "Delete" removes an account, the first remaining row (if
;               any) is selected automatically afterward, the same way it
;               is when the dialog first opens - so the list is never
;               left with nothing selected after one of these unless
;               there are no accounts left at all, in which case the
;               other buttons' own "no account selected" checks handle
;               that gracefully.
;               Disabling or deleting an account forcibly closes any
;               connection currently in progress for it
;               (_CloseConnectionsForAccount()) rather than letting it run
;               to completion unsupervised. Every action refreshes the
;               table in place afterward via _PopulateAccountListView()
;               (and, where the underlying configuration changed, also
;               reloads/restarts the listeners and rebuilds the tray
;               menu, exactly like the other places in the script that
;               change accounts). This is what the tray menu's Settings >
;               Accounts item opens. Its message loop calls _ServiceConnections()
;               on every tick and uses _ProxyMsgBox() (not a native
;               MsgBox()) for every prompt, so the proxy keeps accepting
;               and relaying mail for as long as this dialog - or any
;               prompt it shows - stays open; see _ServiceConnections()'s
;               header comment for why that matters.
;               "Test Connection" checks connection, TLS and sign-in for the
;               selected account without sending an e-mail
;               (_RunConnectionTest()).
;               The window is titled "Account Settings" since v61 and is
;               opened via the tray menu Settings > Accounts; the general
;               settings ("Advanced", _ShowAdvancedSettingsDialog()) moved
;               from a button here to Settings > Advanced in the tray menu.
; Parameters  : (none)
; Returns     : (nothing)
; ============================================================================
Func _ShowSettingsDialog()
	Local $hGui = GUICreate("Account Settings - " & $g_sAppName, 990, 390)
	_SetDialogIcon($hGui)

	Local $idListView = GUICtrlCreateListView( _
			"Active|E-mail|Provider|Local Port|Local Address|Server|STARTTLS|Local Password|Status", 20, 20, 950, 300)
	Local $hListView = GUICtrlGetHandle($idListView)
	GUICtrlSetTip($idListView, "Every configured account. Select a row, then use the buttons" & @CRLF & _
			"below, or double-click a row to edit that account directly.")
	_GUICtrlListView_SetColumnWidth($hListView, 0, 50)
	_GUICtrlListView_SetColumnWidth($hListView, 1, 160)
	_GUICtrlListView_SetColumnWidth($hListView, 2, 90)
	_GUICtrlListView_SetColumnWidth($hListView, 3, 70)
	_GUICtrlListView_SetColumnWidth($hListView, 4, 100)
	_GUICtrlListView_SetColumnWidth($hListView, 5, 200)
	_GUICtrlListView_SetColumnWidth($hListView, 6, 70)
	_GUICtrlListView_SetColumnWidth($hListView, 7, 90)
	_GUICtrlListView_SetColumnWidth($hListView, 8, 120)

	; See _WM_NOTIFY_AccountList()'s header comment for why a ListView
	; double-click needs this lower-level mechanism instead of an
	; ordinary GUIGetMsg() Case.
	$g_hAccountListView = $hListView
	$g_bAccountListDblClk = False
	GUIRegisterMsg($WM_NOTIFY, "_WM_NOTIFY_AccountList")

	Local $aRowEmails[0]
	_PopulateAccountListView($idListView, $aRowEmails)
	If UBound($aRowEmails) > 0 Then _SelectAccountRow($hListView, $aRowEmails, $aRowEmails[0])

	; Button row: 7 buttons of equal width with equal gaps, spanning exactly the
	; width of the ListView above (x = 20 ... 970): 7 x 128 + 6 x 9 = 950.
	; ("Advanced" moved to the tray menu in v61: Settings > Advanced.)
	Local Const $iBtnW = 128, $iBtnStep = 128 + 9, $iBtnY = 335, $iBtnH = 30
	Local $idNew = GUICtrlCreateButton("New", 20, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idNew, "Add a new account.")
	Local $idEdit = GUICtrlCreateButton("Edit", 20 + 1 * $iBtnStep, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idEdit, "Edit the selected account's settings.")
	Local $idToggle = GUICtrlCreateButton("Enable/Disable", 20 + 2 * $iBtnStep, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idToggle, "Switch the selected account's local listener on or off," & @CRLF & _
			"without deleting its configuration.")
	Local $idDelete = GUICtrlCreateButton("Delete", 20 + 3 * $iBtnStep, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idDelete, "Permanently remove the selected account and its" & @CRLF & _
			"local listener. Asks for confirmation first.")
	Local $idSendTest = GUICtrlCreateButton("Test E-Mail", 20 + 4 * $iBtnStep, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idSendTest, "Send a test message through the selected account.")
	Local $idTestConn = GUICtrlCreateButton("Test Connection", 20 + 5 * $iBtnStep, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idTestConn, "Check connection, encryption and sign-in at the mail" & @CRLF & _
			"server for the selected account - without sending an e-mail.")
	Local $idClose = GUICtrlCreateButton("Close", 20 + 6 * $iBtnStep, $iBtnY, $iBtnW, $iBtnH)
	GUICtrlSetTip($idClose, "Close this window.")

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	While 1
		Local $nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE, $idClose
				GUIRegisterMsg($WM_NOTIFY, "")
				$g_hAccountListView = 0
				GUIDelete($hGui)
				_DialogClosed()
				Return

			Case $idNew
				; Disabling the Settings window for the duration keeps it
				; from being clicked/interacted with while the child dialog
				; is open (its own message loop takes over completely
				; while it runs, so Settings would otherwise sit there
				; looking clickable without actually responding to
				; anything until the child closes) - re-enabled
				; unconditionally right after, however the child closed.
				; SW_ENABLE alone does not bring a window back to the
				; foreground/give it focus though - when the child dialog
				; closes, Windows has to hand focus to something else
				; right away, and Settings cannot take it while still
				; disabled at that exact moment, so it can end up behind
				; other windows; WinActivate() explicitly brings it back.
				GUISetState(@SW_DISABLE, $hGui)
				Local $sNewEmail = _ShowAddAccountDialog($hGui)
				GUISetState(@SW_ENABLE, $hGui)
				WinActivate($hGui)
				_PopulateAccountListView($idListView, $aRowEmails)
				; Select the just-created account so it is immediately
				; visible and ready for further action (e.g. "Send Test
				; E-mail" right away) - or, if the dialog was cancelled
				; ($sNewEmail = ""), fall back to the first row instead of
				; leaving the list with nothing selected at all (see
				; _SelectAccountRow()'s own header comment for why that
				; matters), same as when the Settings dialog first opens.
				If $sNewEmail <> "" Then
					_SelectAccountRow($hListView, $aRowEmails, $sNewEmail)
				ElseIf UBound($aRowEmails) > 0 Then
					_SelectAccountRow($hListView, $aRowEmails, $aRowEmails[0])
				EndIf

			Case $idEdit
				Local $sEmail = _GetSelectedAccountEmail($hListView, $aRowEmails)
				If $sEmail = "" Then
					_ProxyMsgBox(48, "No account selected", "Please select an account first.", $hGui)
					ContinueLoop
				EndIf
				GUISetState(@SW_DISABLE, $hGui)
				Local $bEditSaved = _ShowEditAccountDialog($g_oAccountsByEmail.Item($sEmail), _FindListenerForAccount($sEmail), $hGui)
				GUISetState(@SW_ENABLE, $hGui)
				WinActivate($hGui)
				_PopulateAccountListView($idListView, $aRowEmails)
				If Not $bEditSaved And UBound($aRowEmails) > 0 Then _SelectAccountRow($hListView, $aRowEmails, $aRowEmails[0])

			Case $idToggle
				Local $sEmail2 = _GetSelectedAccountEmail($hListView, $aRowEmails)
				If $sEmail2 = "" Then
					_ProxyMsgBox(48, "No account selected", "Please select an account first.", $hGui)
					ContinueLoop
				EndIf
				Local $oListener2 = _FindListenerForAccount($sEmail2)
				If Not IsObj($oListener2) Then
					_ProxyMsgBox(16, "Error", "No matching listener was found for this account.", $hGui)
					ContinueLoop
				EndIf
				Local $bWasActive = $oListener2.Item("Active")
				_SetListenerActive("SMTP-" & $oListener2.Item("LocalPort"), Not $bWasActive)
				; Disabling: forcibly end any connection already in progress
				; rather than letting it run to completion unsupervised (see
				; _CloseConnectionsForAccount()). Enabling needs no such step
				; - nothing was running against this listener to begin with.
				If $bWasActive Then _CloseConnectionsForAccount($sEmail2)
				_LoadAllListeners()
				_StartAllListeners()
				_RebuildTrayMenu()
				_PopulateAccountListView($idListView, $aRowEmails)
				; Keep the just-toggled row selected (rather than losing the
				; selection to the repopulate above) so it can quickly be
				; switched back with another click, without having to find
				; and re-select it first.
				_SelectAccountRow($hListView, $aRowEmails, $sEmail2)

			Case $idDelete
				Local $sEmail3 = _GetSelectedAccountEmail($hListView, $aRowEmails)
				If $sEmail3 = "" Then
					_ProxyMsgBox(48, "No account selected", "Please select an account first.", $hGui)
					ContinueLoop
				EndIf
				If _ProxyMsgBox(BitOR(4, 48), "Delete account?", _
						"Permanently delete " & $sEmail3 & " and its local SMTP listener?" & @CRLF & _
						"Any connection currently in progress for this account will be closed immediately." & @CRLF & _
						"This cannot be undone.", $hGui) <> 6 Then ContinueLoop

				_DeleteAccount($g_oAccountsByEmail.Item($sEmail3), _FindListenerForAccount($sEmail3))
				_LoadAllListeners()
				_StartAllListeners()
				_RebuildTrayMenu()
				_PopulateAccountListView($idListView, $aRowEmails)
				; Select the new first row, same as after a cancelled
				; New/Edit - if this was the last account, $aRowEmails is
				; now empty and there is nothing to select; the list is
				; then left with no selection, which every other button
				; here already handles gracefully via its own
				; _GetSelectedAccountEmail() = "" check ("No account
				; selected").
				If UBound($aRowEmails) > 0 Then _SelectAccountRow($hListView, $aRowEmails, $aRowEmails[0])

			Case $idTestConn
				Local $sEmail5 = _GetSelectedAccountEmail($hListView, $aRowEmails)
				If $sEmail5 = "" Then
					_ProxyMsgBox(48, "No account selected", "Please select an account first.", $hGui)
					ContinueLoop
				EndIf
				_RunConnectionTest($sEmail5, $hGui, $idTestConn)

			Case $idSendTest
				Local $sEmail4 = _GetSelectedAccountEmail($hListView, $aRowEmails)
				If $sEmail4 = "" Then
					_ProxyMsgBox(48, "No account selected", "Please select an account first.", $hGui)
					ContinueLoop
				EndIf
				GUISetState(@SW_DISABLE, $hGui)
				_ShowSendTestEmailDialog($sEmail4, $hGui)
				GUISetState(@SW_ENABLE, $hGui)
				WinActivate($hGui)
		EndSwitch

		; Double-clicking a row opens Edit for that account, same as
		; clicking it once to select it and then clicking the "Edit"
		; button - see _WM_NOTIFY_AccountList()'s header comment for why
		; this is detected here instead of as an ordinary Switch Case
		; above. Does nothing if there was no row under the double-click
		; (e.g. double-clicking empty space below the last account, or
		; the column header) - _GetSelectedAccountEmail() then returns ""
		; and there is nothing to edit.
		If $g_bAccountListDblClk Then
			$g_bAccountListDblClk = False
			Local $sDblClkEmail = _GetSelectedAccountEmail($hListView, $aRowEmails)
			If $sDblClkEmail <> "" Then
				GUISetState(@SW_DISABLE, $hGui)
				Local $bDblClkEditSaved = _ShowEditAccountDialog($g_oAccountsByEmail.Item($sDblClkEmail), _FindListenerForAccount($sDblClkEmail), $hGui)
				GUISetState(@SW_ENABLE, $hGui)
				WinActivate($hGui)
				_PopulateAccountListView($idListView, $aRowEmails)
				If Not $bDblClkEditSaved And UBound($aRowEmails) > 0 Then _SelectAccountRow($hListView, $aRowEmails, $aRowEmails[0])
			EndIf
		EndIf

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowSettingsDialog

; ============================================================================
; _PopulateAccountListView
; ----------------------------------------------------------------------------
; Description : (Re-)fills the accounts ListView in _ShowSettingsDialog():
;               clears every existing row (_GUICtrlListView_DeleteAllItems),
;               then adds one row per account currently in
;               $g_oAccountsByEmail, in the same order returned by its
;               Keys(). Also rebuilds $aRowEmails so that row index N in
;               the ListView corresponds to $aRowEmails[N]'s e-mail
;               address - this is how _GetSelectedAccountEmail() maps a
;               selected row back to an account without depending on which
;               column happens to be selected/focused.
; Parameters  : $idListView - Control ID of the ListView to populate.
;               $aRowEmails - ByRef: replaced with a fresh array mapping
;               row index -> e-mail address.
; Returns     : (nothing - mutates the ListView and $aRowEmails as a side
;               effect)
; ============================================================================
Func _PopulateAccountListView($idListView, ByRef $aRowEmails)
	Local $hListView = GUICtrlGetHandle($idListView)
	_GUICtrlListView_DeleteAllItems($hListView)

	Local $aEmails = $g_oAccountsByEmail.Keys()
	Local $aNewRowEmails[UBound($aEmails)]
	Local $i = 0
	For $i = 0 To UBound($aEmails) - 1
		Local $sEmail = $aEmails[$i]
		Local $oAcc = $g_oAccountsByEmail.Item($sEmail)
		Local $oListener = _FindListenerForAccount($sEmail)

		Local $sActive = "?"
		Local $sPort = "?"
		Local $sLocalAddress = "?"
		Local $sServer = "?"
		Local $sTls = "?"
		If IsObj($oListener) Then
			$sActive = "No"
			If $oListener.Item("Active") Then $sActive = "Yes"
			$sPort = String($oListener.Item("LocalPort"))
			$sLocalAddress = $oListener.Item("LocalAddress")
			$sServer = $oListener.Item("ServerAddress") & ":" & $oListener.Item("ServerPort")
			$sTls = "No"
			If Number($oListener.Item("ServerSTARTTLS")) = 1 Then $sTls = "Yes"
		EndIf

		Local $sPassStatus = "Missing!"
		If $oAcc.Item("LocalPassword") <> "" Then $sPassStatus = "Set"

		Local $sStatus = "Signed in"
		If $oAcc.Item("NeedsReauth") Then $sStatus = "Sign-in required"

		Local $sRow = $sActive & "|" & $sEmail & "|" & $oAcc.Item("Provider") & "|" & $sPort & "|" & _
				$sLocalAddress & "|" & $sServer & "|" & $sTls & "|" & $sPassStatus & "|" & $sStatus
		GUICtrlCreateListViewItem($sRow, $idListView)

		$aNewRowEmails[$i] = $sEmail
	Next

	$aRowEmails = $aNewRowEmails
EndFunc   ;==>_PopulateAccountListView

; ============================================================================
; _GetSelectedAccountEmail
; ----------------------------------------------------------------------------
; Description : Returns the e-mail address of the currently selected row in
;               the accounts ListView, via $aRowEmails (see
;               _PopulateAccountListView()) rather than reading the
;               selected row's own text - this way it does not matter
;               which column happens to be first ("Active" is visually
;               first, per the requested layout, but is not a unique
;               identifier on its own).
; Parameters  : $hListView  - Native window handle of the ListView (from
;               GUICtrlGetHandle()).
;               $aRowEmails - The row-index -> e-mail array maintained by
;               _PopulateAccountListView().
; Returns     : The selected row's e-mail address, or "" if no row is
;               currently selected.
; ============================================================================
Func _GetSelectedAccountEmail($hListView, ByRef $aRowEmails)
	Local $sIndices = _GUICtrlListView_GetSelectedIndices($hListView)
	If $sIndices = "" Then Return ""

	Local $aParts = StringSplit($sIndices, "|")
	Local $iIndex = Number($aParts[1]) ; first selected index if more than one somehow got selected
	If $iIndex < 0 Or $iIndex > UBound($aRowEmails) - 1 Then Return ""
	Return $aRowEmails[$iIndex]
EndFunc   ;==>_GetSelectedAccountEmail

; ============================================================================
; _SelectAccountRow
; ----------------------------------------------------------------------------
; Description : Selects (and focuses) the row belonging to a given account
;               e-mail address in the accounts ListView, via $aRowEmails
;               (see _PopulateAccountListView()) - the counterpart to
;               _GetSelectedAccountEmail(). Used after an action that
;               refreshes the list but should not lose the user's current
;               selection (e.g. "Enable/Disable", so the same row can be
;               quickly toggled back without having to find and click it
;               again) - call this AFTER _PopulateAccountListView() has
;               already rebuilt $aRowEmails for the new state, since row
;               indices are not stable across a repopulate. Does nothing
;               if the e-mail address is no longer in the list (e.g. the
;               account was just deleted).
; Parameters  : $hListView  - Native window handle of the ListView (from
;               GUICtrlGetHandle()).
;               $aRowEmails - The row-index -> e-mail array maintained by
;               _PopulateAccountListView(), already refreshed for the
;               current state.
;               $sEmail     - E-mail address of the row to select.
; Returns     : (nothing)
; ============================================================================
Func _SelectAccountRow($hListView, ByRef $aRowEmails, $sEmail)
	Local $i = 0
	For $i = 0 To UBound($aRowEmails) - 1
		If $aRowEmails[$i] = $sEmail Then
			_GUICtrlListView_SetItemSelected($hListView, $i, True, True)
			ExitLoop
		EndIf
	Next
EndFunc   ;==>_SelectAccountRow

; ============================================================================
; _WM_NOTIFY_AccountList
; ----------------------------------------------------------------------------
; Description : WM_NOTIFY handler for the Account Settings dialog's account
;               ListView, registered (and unregistered again on close) by
;               _ShowSettingsDialog(). A ListView double-click on a row
;               does NOT surface as its own, distinct event through the
;               ordinary GUIGetMsg() polling loop the rest of this script
;               uses everywhere else - a single click already returns
;               nothing there, and even a double-click, depending on
;               where exactly it lands (a cell vs. the column header),
;               may not either - it has to be caught at this lower,
;               native-Windows-message level instead via $NM_DBLCLK,
;               which is what this function does. Only sets a flag
;               ($g_bAccountListDblClk) rather than acting immediately,
;               since a GUIRegisterMsg() handler runs synchronously
;               in the middle of whatever the main script was doing when
;               the message arrived - not a safe place to open another
;               window from. _ShowSettingsDialog()'s own message loop
;               checks and consumes that flag on every tick instead.
; Parameters  : $hWnd, $iMsg, $wParam, $lParam - standard Windows message
;               handler parameters (see GUIRegisterMsg()); only $lParam
;               (the NMHDR structure) is actually used here.
; Returns     : $GUI_RUNDEFMSG, so AutoIt still processes this message
;               normally afterwards (e.g. for the ListView's own default
;               selection-on-click behaviour) - this handler only
;               observes the notification, it does not replace it.
; ============================================================================
Func _WM_NOTIFY_AccountList($hWnd, $iMsg, $wParam, $lParam)
	#forceref $hWnd, $iMsg, $wParam
	If $g_hAccountListView = 0 Then Return $GUI_RUNDEFMSG

	Local $tNMHDR = DllStructCreate($tagNMHDR, $lParam)
	Local $hWndFrom = HWnd(DllStructGetData($tNMHDR, "hWndFrom"))
	Local $iCode = DllStructGetData($tNMHDR, "Code")

	If $hWndFrom = $g_hAccountListView And $iCode = $NM_DBLCLK Then
		$g_bAccountListDblClk = True
	EndIf

	Return $GUI_RUNDEFMSG
EndFunc   ;==>_WM_NOTIFY_AccountList

; ============================================================================
; _ShowEditAccountDialog
; ----------------------------------------------------------------------------
; Description : Shows an "Edit account" GUI closely mirroring
;               _ShowAddAccountDialog(), pre-filled with the selected
;               account's current settings, for changing an EXISTING
;               account/listener instead of creating a new one. The e-mail
;               address is shown but not editable (changing which mailbox
;               a configuration represents is really "delete + create
;               new", not an edit - see _DeleteAccount() /
;               _ShowAddAccountDialog()).
;               The local SMTP password field is pre-filled with a fixed
;               12-character placeholder ($sPwPlaceholder, unrelated to the
;               real password's actual length, so it gives no hint about
;               it) rather than left blank - the stored password is only
;               changed if the field no longer contains exactly that
;               placeholder when "Save" is clicked, i.e. the placeholder
;               was replaced with something else. A newly-entered password
;               must be at least 8 characters (see the $idSave case). The
;               client secret field is left blank instead, and - unlike
;               the password - only overwrites the stored (encrypted)
;               value if something is actually typed into it, since a
;               blank/empty secret is itself a valid, meaningful choice
;               for Microsoft accounts using PKCE (see UsePKCE).
;               If Provider, Client ID or Tenant ID actually change, the
;               stored OAuth2 tokens are cleared (they would not be valid
;               against the new configuration anyway), which makes
;               NeedsReauth become True again on the next load - unlike
;               _ShowAddAccountDialog(), this does NOT automatically launch
;               the interactive sign-in; use the account's tray menu entry
;               to re-authenticate once ready. Changing the local port
;               renames the listener's "SMTP-<port>" INI section
;               (IniDelete of the old one, then a fresh write) rather than
;               leaving a stale section behind - and is rejected before
;               saving if the new port is already used by a DIFFERENT
;               configured account (this account's own current port is
;               excluded from that check, so leaving it unchanged is
;               always fine), for the same "would silently overwrite
;               another account's listener" reason described in
;               _ShowAddAccountDialog().
;               The fields Authorize URL, Token URL and Scope are only
;               editable for the "Custom" provider
;               (_SetEndpointFieldsState()); for Microsoft and Google the
;               values already stored are kept as long as provider and tenant
;               are unchanged, so a manually adjusted scope survives an edit.
;               Port, address and Custom endpoints are checked by
;               _ValidateConnectionInputs() / _ValidateCustomEndpoints(); a
;               changed token URL also clears the stored tokens. The client
;               secret is entered masked.
; Parameters  : $oAcc      - Account dictionary to edit.
;               $oListener - The account's listener dictionary (as
;               returned by _FindListenerForAccount()).
;               $hParent   - Optional owner window handle (see
;               GUICreate()'s own $hWndParent parameter) -
;               _ShowSettingsDialog() passes its own handle here and
;               disables itself for as long as this dialog is open, so
;               Settings cannot be interacted with while this one is (see
;               its own header comment).
; Returns     : True if the account was saved; False if the dialog was
;               cancelled (or could not open in the first place) -
;               _ShowSettingsDialog() uses this to know whether to fall
;               back to selecting the account list's first row, since
;               cancelling leaves the list with no selection otherwise.
; ============================================================================
Func _ShowEditAccountDialog($oAcc, $oListener, $hParent = 0)
	If Not IsObj($oListener) Then
		_ProxyMsgBox(16, "Error", "No matching listener was found for this account.", $hParent)
		Return False
	EndIf

	; Fixed placeholder shown in the local password field - always exactly
	; this many characters, regardless of the real password's actual
	; length, so the field itself leaks nothing about it. See the header
	; comment and the $idSave case below for how this is used to detect
	; whether the user actually typed a new password.
	Local Const $sPwPlaceholder = "************"

	Local $hGui = GUICreate("Edit account - " & $g_sAppName, 460, 535, -1, -1, -1, -1, $hParent)
	_SetDialogIcon($hGui)

	GUICtrlCreateLabel("Provider:", 20, 20, 100, 20)
	Local $idProvider = GUICtrlCreateCombo("", 140, 18, 280, 22, BitOR($CBS_DROPDOWNLIST, $CBS_AUTOHSCROLL))
	GUICtrlSetTip($idProvider, "Changing this fills in the server address, port and" & @CRLF & _
			"OAuth2 endpoints below with that provider's defaults.")
	Local $sProviderCombo = "Custom"
	If $oAcc.Item("Provider") = "microsoft" Then $sProviderCombo = "Microsoft 365 / Outlook.com"
	If $oAcc.Item("Provider") = "google" Then $sProviderCombo = "Google Workspace / Gmail"
	GUICtrlSetData($idProvider, "Microsoft 365 / Outlook.com|Google Workspace / Gmail|Custom", $sProviderCombo)

	GUICtrlCreateLabel("E-mail address:", 20, 55, 100, 20)
	Local $idEmail = GUICtrlCreateInput($oAcc.Item("Username"), 140, 53, 280, 22)
	GUICtrlSetState($idEmail, $GUI_DISABLE)
	GUICtrlSetTip($idEmail, "The e-mail address cannot be changed here - delete and" & @CRLF & _
			"re-add the account instead if you need a different one.")

	GUICtrlCreateLabel("Local SMTP password:", 20, 90, 115, 20)
	Local $idLocalPassword = GUICtrlCreateInput($sPwPlaceholder, 140, 88, 280, 22, BitOR($GUI_SS_DEFAULT_INPUT, $ES_PASSWORD))
	GUICtrlSetTip($idLocalPassword, "Not your real Microsoft/Google password - a password" & @CRLF & _
			"you choose yourself, used only between your local" & @CRLF & _
			"device and this proxy. At least 8 characters. Leave" & @CRLF & _
			"the placeholder as-is to keep the current password.")

	GUICtrlCreateLabel("Local port:", 20, 125, 100, 20)
	Local $idLocalPort = GUICtrlCreateInput(String($oListener.Item("LocalPort")), 140, 123, 100, 22)
	GUICtrlSetTip($idLocalPort, "The port this account's local listener uses on this PC." & @CRLF & _
			"Point your device's SMTP settings at this port.")

	GUICtrlCreateLabel("Local address:", 250, 125, 90, 20)
	Local $idLocalAddress = GUICtrlCreateInput($oListener.Item("LocalAddress"), 345, 123, 95, 22)
	GUICtrlSetTip($idLocalAddress, "127.0.0.1 = this PC only (recommended)." & @CRLF & _
			"0.0.0.0 = every network interface on this PC." & @CRLF & _
			"A specific IP restricts it to one interface - see" & @CRLF & _
			"the README before changing this. IPv4 only - if a" & @CRLF & _
			"client tries IPv6 and fails, point it at this exact" & @CRLF & _
			"address instead of ""localhost"".")

	GUICtrlCreateLabel("Server address:", 20, 160, 100, 20)
	Local $idServerAddr = GUICtrlCreateInput($oListener.Item("ServerAddress"), 140, 158, 200, 22)
	GUICtrlSetTip($idServerAddr, "The real SMTP server to relay to.")
	GUICtrlCreateLabel("Server port:", 20, 195, 100, 20)
	Local $idServerPort = GUICtrlCreateInput(String($oListener.Item("ServerPort")), 140, 193, 60, 22)
	GUICtrlSetTip($idServerPort, "The real SMTP server's port.")
	Local $idStartTls = GUICtrlCreateCheckbox("Use STARTTLS", 210, 195, 200, 22)
	If Number($oListener.Item("ServerSTARTTLS")) = 1 Then GUICtrlSetState($idStartTls, $GUI_CHECKED)
	GUICtrlSetTip($idStartTls, "Upgrade to an encrypted connection after connecting," & @CRLF & _
			"instead of starting encrypted immediately. Leave at" & @CRLF & _
			"the preset default unless you know this provider" & @CRLF & _
			"needs something different.")

	GUICtrlCreateLabel("Client ID:", 20, 230, 100, 20)
	Local $idClientId = GUICtrlCreateInput($oAcc.Item("ClientID"), 140, 228, 280, 22)
	GUICtrlSetTip($idClientId, "The Application (client) ID from your app registration -" & @CRLF & _
			"see the README for how to obtain this from Microsoft" & @CRLF & _
			"or Google.")

	GUICtrlCreateLabel("Directory (tenant) ID:", 20, 265, 115, 20)
	Local $idTenantId = GUICtrlCreateInput($oAcc.Item("TenantID"), 140, 263, 280, 22)
	GUICtrlSetTip($idTenantId, "Microsoft only. Leave empty to use the shared" & @CRLF & _
			"/common/ endpoint instead of one specific tenant.")
	GUICtrlCreateLabel("(Microsoft only; leave empty for the shared /common/ endpoint)", 140, 286, 300, 30)

	GUICtrlCreateLabel("Client secret:", 20, 322, 100, 20)
	Local $idClientSecret = GUICtrlCreateInput("", 140, 320, 280, 22, BitOR($GUI_SS_DEFAULT_INPUT, $ES_PASSWORD)) ; B5: masked
	GUICtrlSetTip($idClientSecret, "From your app registration. Optional for Microsoft when" & @CRLF & _
			"using PKCE (the default); Google issues one for every" & @CRLF & _
			"""Desktop app"" credential. Leave empty to keep the" & @CRLF & _
			"secret already stored for this account.")
	GUICtrlCreateLabel("(leave empty to keep the current secret)", 140, 343, 280, 16)

	GUICtrlCreateLabel("Authorize URL:", 20, 372, 115, 20)
	Local $idAuthUrl = GUICtrlCreateInput($oAcc.Item("PermissionURL"), 140, 370, 300, 22)
	GUICtrlSetTip($idAuthUrl, "OAuth2 authorization endpoint. Filled in automatically for" & @CRLF & _
			"Microsoft and Google; only editable for ""Custom"".")
	GUICtrlCreateLabel("Token URL:", 20, 407, 115, 20)
	Local $idTokenUrl = GUICtrlCreateInput($oAcc.Item("TokenURL"), 140, 405, 300, 22)
	GUICtrlSetTip($idTokenUrl, "OAuth2 token endpoint. Filled in automatically for" & @CRLF & _
			"Microsoft and Google; only editable for ""Custom"".")
	GUICtrlCreateLabel("Scope:", 20, 442, 115, 20)
	Local $idScope = GUICtrlCreateInput($oAcc.Item("Scope"), 140, 440, 300, 22)
	GUICtrlSetTip($idScope, "OAuth2 scope(s) for sending via SMTP, separated by spaces." & @CRLF & _
			"Filled in automatically for Microsoft and Google; only" & @CRLF & _
			"editable for ""Custom"".")
	_SetEndpointFieldsState($oAcc.Item("Provider") = "custom", $idAuthUrl, $idTokenUrl, $idScope)

	Local $idSave = GUICtrlCreateButton("Save", 140, 485, 150, 30)
	GUICtrlSetTip($idSave, "Save these changes.")
	Local $idCancel = GUICtrlCreateButton("Cancel", 300, 485, 100, 30)
	GUICtrlSetTip($idCancel, "Discard changes and close this window.")

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()

	While 1
		Local $nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE, $idCancel
				GUIDelete($hGui)
				_DialogClosed()
				Return False

			Case $idProvider
				_ApplyProviderDefaults($idProvider, $idServerAddr, $idServerPort, $idStartTls, $idClientId, $idTenantId, $idClientSecret, $idAuthUrl, $idTokenUrl, $idScope)

			Case $idSave
				Local $sLocalPasswordRaw = GUICtrlRead($idLocalPassword)
				Local $bLocalPasswordChanged = ($sLocalPasswordRaw <> $sPwPlaceholder)
				Local $iNewPort = Number(GUICtrlRead($idLocalPort))
				Local $sLocalAddress = StringStripWS(GUICtrlRead($idLocalAddress), 3)
				Local $sServerAddr = StringStripWS(GUICtrlRead($idServerAddr), 3)
				Local $iServerPort = Number(GUICtrlRead($idServerPort))
				Local $bStartTls = (GUICtrlRead($idStartTls) = $GUI_CHECKED)
				Local $sClientId = StringStripWS(GUICtrlRead($idClientId), 3)
				Local $sTenantId = StringStripWS(GUICtrlRead($idTenantId), 3)
				Local $sClientSecret = GUICtrlRead($idClientSecret)
				Local $sProviderText = GUICtrlRead($idProvider)
				Local $sAuthUrlIn = StringStripWS(GUICtrlRead($idAuthUrl), 3)
				Local $sTokenUrlIn = StringStripWS(GUICtrlRead($idTokenUrl), 3)
				Local $sScopeIn = StringStripWS(GUICtrlRead($idScope), 3)
				Local $bIsCustom = Not (StringInStr($sProviderText, "Microsoft") Or StringInStr($sProviderText, "Google"))

				If $iNewPort <= 1023 Or $sLocalAddress = "" Or $sServerAddr = "" Or $sClientId = "" Then
					_ProxyMsgBox(48, "Incomplete input", _
							"Please provide a local port (> 1023), a local address, a server address and a client ID.", $hGui)
					ContinueLoop
				EndIf

				; B4: ranges and formats; B2: endpoints of a "Custom" account
				If Not _ValidateConnectionInputs($iNewPort, $sLocalAddress, $sServerAddr, $iServerPort, $hGui) Then ContinueLoop
				If $bIsCustom And Not _ValidateCustomEndpoints($sAuthUrlIn, $sTokenUrlIn, $sScopeIn, $hGui) Then ContinueLoop

				If $bLocalPasswordChanged And StringLen($sLocalPasswordRaw) < 8 Then
					_ProxyMsgBox(48, "Password too short", "The local SMTP password must be at least 8 characters long.", $hGui)
					ContinueLoop
				EndIf

				; Local ports double as INI section names ("SMTP-<port>") - saving
				; over an already-used one would silently overwrite that other
				; account's entire listener configuration rather than just fail
				; to bind the socket later. Excludes this account's own current
				; port, since leaving it unchanged (or "changing" it to the same
				; value) is not a collision.
				If $iNewPort <> $oListener.Item("LocalPort") And $g_oListeners.Exists("SMTP-" & $iNewPort) Then
					_ProxyMsgBox(48, "Port already in use", _
							"Local port " & $iNewPort & " is already used by another configured account." & @CRLF & _
							"Please choose a different local port.", $hGui)
					ContinueLoop
				EndIf

				Local $sProviderKey = "custom"
				If StringInStr($sProviderText, "Microsoft") Then $sProviderKey = "microsoft"
				If StringInStr($sProviderText, "Google") Then $sProviderKey = "google"
				Local $aPreset = _GetProviderPreset($sProviderKey)

				Local $sPermissionUrl = $aPreset[0]
				Local $sTokenUrl = $aPreset[1]
				If $sProviderKey = "microsoft" And $sTenantId <> "" Then
					$sPermissionUrl = StringReplace($sPermissionUrl, "/common/", "/" & $sTenantId & "/")
					$sTokenUrl = StringReplace($sTokenUrl, "/common/", "/" & $sTenantId & "/")
				EndIf

				; B2: "Custom" uses the URLs/scope entered in the dialog. For Microsoft
				; and Google the values already stored are kept as long as provider and
				; tenant are unchanged (so a manually adjusted scope survives "Edit");
				; otherwise the preset (with tenant) is used.
				Local $sScope = $aPreset[2]
				If $bIsCustom Then
					$sPermissionUrl = $sAuthUrlIn
					$sTokenUrl = $sTokenUrlIn
					$sScope = $sScopeIn
				ElseIf $sProviderKey = $oAcc.Item("Provider") And $sTenantId = $oAcc.Item("TenantID") And _
						$oAcc.Item("PermissionURL") <> "" And $oAcc.Item("TokenURL") <> "" Then
					$sPermissionUrl = $oAcc.Item("PermissionURL")
					$sTokenUrl = $oAcc.Item("TokenURL")
					If $oAcc.Item("Scope") <> "" Then $sScope = $oAcc.Item("Scope")
				EndIf

				Local $iOldPort = $oListener.Item("LocalPort")
				Local $sAccSection = $oAcc.Item("IniSection")
				Local $bCredsChanged = ($sProviderKey <> $oAcc.Item("Provider")) Or _
						($sClientId <> $oAcc.Item("ClientID")) Or ($sTenantId <> $oAcc.Item("TenantID")) Or ($sTokenUrl <> $oAcc.Item("TokenURL"))

				GUIDelete($hGui)

				If $iNewPort <> $iOldPort Then IniDelete($g_sIniPath, "SMTP-" & $iOldPort)
				Local $sNewSection = "SMTP-" & $iNewPort
				IniWrite($g_sIniPath, $sNewSection, "LocalAddress", $sLocalAddress)
				IniWrite($g_sIniPath, $sNewSection, "LocalPort", $iNewPort)
				IniWrite($g_sIniPath, $sNewSection, "ServerAddress", $sServerAddr)
				IniWrite($g_sIniPath, $sNewSection, "ServerPort", $iServerPort)
				Local $sTls = "0"
				If $bStartTls Then $sTls = "1"
				IniWrite($g_sIniPath, $sNewSection, "ServerSTARTTLS", $sTls)
				IniWrite($g_sIniPath, $sNewSection, "Account", $oAcc.Item("Username"))
				Local $sActiveVal = "0"
				If $oListener.Item("Active") Then $sActiveVal = "1"
				IniWrite($g_sIniPath, $sNewSection, "Active", $sActiveVal)

				IniWrite($g_sIniPath, $sAccSection, "Provider", $sProviderKey)
				IniWrite($g_sIniPath, $sAccSection, "PermissionURL", $sPermissionUrl)
				IniWrite($g_sIniPath, $sAccSection, "TokenURL", $sTokenUrl)
				IniWrite($g_sIniPath, $sAccSection, "Scope", $sScope)
				IniWrite($g_sIniPath, $sAccSection, "ClientID", $sClientId)
				IniWrite($g_sIniPath, $sAccSection, "TenantID", $sTenantId)
				If $sClientSecret <> "" Then IniWrite($g_sIniPath, $sAccSection, "ClientSecretEnc", _DPAPI_Protect($sClientSecret))
				Local $sPkce = "0"
				If Number($aPreset[6]) = 1 Then $sPkce = "1"
				IniWrite($g_sIniPath, $sAccSection, "UsePKCE", $sPkce)

				If $bLocalPasswordChanged Then _SetLocalPassword($oAcc, $sLocalPasswordRaw)

				If $bCredsChanged Then
					IniDelete($g_sIniPath, $sAccSection, "RefreshTokenEnc")
					IniDelete($g_sIniPath, $sAccSection, "AccessTokenEnc")
					IniDelete($g_sIniPath, $sAccSection, "AccessTokenExpiry")
					LogFile("Account " & $oAcc.Item("Username") & _
							": provider/client ID/tenant changed - stored tokens cleared, re-authentication required.")
				EndIf

				LogFile("Account " & $oAcc.Item("Username") & " was edited.")

				_LoadAllListeners()
				_StartAllListeners()
				_RebuildTrayMenu()
				_DialogClosed()
				Return True
		EndSwitch

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowEditAccountDialog

; ############################################################################
; #  ADD ACCOUNT (GUI wizard)
; ############################################################################

; ============================================================================
; _ShowAddAccountDialog
; ----------------------------------------------------------------------------
; Description : Shows the "Add account" GUI wizard: provider selection
;               (Microsoft/Google/custom, auto-filling server/endpoint
;               defaults via _ApplyProviderDefaults), e-mail address, local
;               SMTP password (see _CheckLocalCredentials()), local port,
;               server address/port/STARTTLS, client ID, optional tenant
;               (directory) ID, and client secret. For Microsoft, if a
;               tenant ID/domain is entered, it replaces the generic
;               "/common/" path segment in both the PermissionURL and
;               TokenURL, so the app is authenticated against that
;               specific Entra ID tenant instead of the multi-tenant
;               "/common/" endpoint (which requires the app registration
;               itself to be configured as multi-tenant). Left empty, the
;               generic "/common/" endpoint from _GetProviderPreset() is
;               used unchanged. Validates the required fields (including
;               that the e-mail address is not already configured, ignoring
;               upper/lower case - see _AccountExistsNoCase() below, since it doubles as
;               the "Account:<email>" INI section name and an unchecked
;               duplicate would silently overwrite that account's entire
;               configuration - and that the chosen local port is not
;               already used by another configured account - see
;               $g_oListeners.Exists() below, for the same "would silently
;               overwrite" reason, just for the "SMTP-<port>" listener
;               section instead). On "Save & sign
;               in", persists the new listener and account to the INI file
;               (_SaveNewListenerAndAccount), runs the interactive OAuth2
;               sign-in flow (_RunInteractiveAuth), then reloads the
;               configuration, (re)starts all listeners and rebuilds the
;               tray menu so the new account becomes active immediately.
;               Its message loop calls
;               _ServiceConnections() on every tick and uses
;               _ProxyMsgBox() (not a native MsgBox()) for every prompt,
;               so the proxy keeps working while this dialog is open; see
;               _ServiceConnections()'s header comment for why that
;               matters.
;               For "Custom", the authorize URL, token URL and scope are
;               entered in the dialog (for Microsoft and Google they are
;               shown, locked). Port, address and Custom endpoints are
;               checked by _ValidateConnectionInputs() /
;               _ValidateCustomEndpoints(); the client secret is entered
;               masked.
; Parameters  : $hParent - Optional owner window handle (see GUICreate()'s
;               own $hWndParent parameter) - _ShowSettingsDialog() passes
;               its own handle here and disables itself for as long as
;               this dialog is open, so Account Settings cannot be
;               interacted with while this one is (see its own header comment).
; Returns     : The new account's e-mail address if it was saved; "" if
;               the dialog was cancelled - _ShowSettingsDialog() uses
;               this to select that account in the list on success, or
;               fall back to the list's first row on cancel (which would
;               otherwise be left with no selection at all).
; ============================================================================
Func _ShowAddAccountDialog($hParent = 0)
	Local $hGui = GUICreate("Add account - " & $g_sAppName, 460, 535, -1, -1, -1, -1, $hParent)
	_SetDialogIcon($hGui)

	GUICtrlCreateLabel("Provider:", 20, 20, 100, 20)
	Local $idProvider = GUICtrlCreateCombo("", 140, 18, 280, 22, BitOR($CBS_DROPDOWNLIST, $CBS_AUTOHSCROLL))
	GUICtrlSetTip($idProvider, "Fills in the server address, port and OAuth2 endpoints" & @CRLF & _
			"below with that provider's defaults. Choose ""Custom""" & @CRLF & _
			"for anything else that offers a standard OAuth2 SMTP login.")
	GUICtrlSetData($idProvider, "Microsoft 365 / Outlook.com|Google Workspace / Gmail|Custom", _
			"Microsoft 365 / Outlook.com")

	GUICtrlCreateLabel("E-mail address:", 20, 55, 100, 20)
	Local $idEmail = GUICtrlCreateInput("", 140, 53, 280, 22)
	GUICtrlSetTip($idEmail, "The real mailbox address you want to send through.")

	GUICtrlCreateLabel("Local SMTP password:", 20, 90, 115, 20)
	Local $idLocalPassword = GUICtrlCreateInput("", 140, 88, 280, 22, BitOR($GUI_SS_DEFAULT_INPUT, $ES_PASSWORD))
	GUICtrlSetTip($idLocalPassword, "Not your real Microsoft/Google password - a password" & @CRLF & _
			"you choose yourself, used only between your local" & @CRLF & _
			"device and this proxy. At least 8 characters.")

	GUICtrlCreateLabel("Local port:", 20, 125, 100, 20)
	Local $idLocalPort = GUICtrlCreateInput(String(_FindFreeSmtpPort()), 140, 123, 100, 22)
	GUICtrlSetTip($idLocalPort, "The port this account's local listener will use on this" & @CRLF & _
			"PC. Point your device's SMTP settings at this port.")

	GUICtrlCreateLabel("Local address:", 250, 125, 90, 20)
	Local $idLocalAddress = GUICtrlCreateInput("127.0.0.1", 345, 123, 95, 22)
	GUICtrlSetTip($idLocalAddress, "127.0.0.1 = this PC only (recommended)." & @CRLF & _
			"0.0.0.0 = every network interface on this PC." & @CRLF & _
			"A specific IP restricts it to one interface - see" & @CRLF & _
			"the README before changing this. IPv4 only - if a" & @CRLF & _
			"client tries IPv6 and fails, point it at this exact" & @CRLF & _
			"address instead of ""localhost"".")

	GUICtrlCreateLabel("Server address:", 20, 160, 100, 20)
	Local $idServerAddr = GUICtrlCreateInput("smtp-mail.outlook.com", 140, 158, 200, 22)
	GUICtrlSetTip($idServerAddr, "The real SMTP server to relay to.")
	GUICtrlCreateLabel("Server port:", 20, 195, 100, 20)
	Local $idServerPort = GUICtrlCreateInput("587", 140, 193, 60, 22)
	GUICtrlSetTip($idServerPort, "The real SMTP server's port.")
	Local $idStartTls = GUICtrlCreateCheckbox("Use STARTTLS", 210, 195, 200, 22)
	GUICtrlSetState($idStartTls, $GUI_CHECKED)
	GUICtrlSetTip($idStartTls, "Upgrade to an encrypted connection after connecting," & @CRLF & _
			"instead of starting encrypted immediately. Leave at" & @CRLF & _
			"the preset default unless you know this provider" & @CRLF & _
			"needs something different.")

	GUICtrlCreateLabel("Client ID:", 20, 230, 100, 20)
	Local $idClientId = GUICtrlCreateInput("", 140, 228, 280, 22)
	GUICtrlSetTip($idClientId, "The Application (client) ID from your app registration -" & @CRLF & _
			"see the README for how to obtain this from Microsoft" & @CRLF & _
			"or Google.")

	GUICtrlCreateLabel("Directory (tenant) ID:", 20, 265, 115, 20)
	Local $idTenantId = GUICtrlCreateInput("", 140, 263, 280, 22)
	GUICtrlSetTip($idTenantId, "Microsoft only. Leave empty to use the shared" & @CRLF & _
			"/common/ endpoint instead of one specific tenant.")
	GUICtrlCreateLabel("(Microsoft only; leave empty for the shared /common/ endpoint)", 140, 286, 300, 30)

	GUICtrlCreateLabel("Client secret:", 20, 322, 100, 20)
	Local $idClientSecret = GUICtrlCreateInput("", 140, 320, 280, 22, BitOR($GUI_SS_DEFAULT_INPUT, $ES_PASSWORD)) ; B5: masked
	GUICtrlSetTip($idClientSecret, "From your app registration. Optional for Microsoft when" & @CRLF & _
			"using PKCE (the default); Google issues one for every" & @CRLF & _
			"""Desktop app"" credential and it should be entered.")
	GUICtrlCreateLabel("(optional for Microsoft with PKCE)", 140, 343, 280, 16)

	GUICtrlCreateLabel("Authorize URL:", 20, 372, 115, 20)
	Local $idAuthUrl = GUICtrlCreateInput("", 140, 370, 300, 22)
	GUICtrlSetTip($idAuthUrl, "OAuth2 authorization endpoint. Filled in automatically for" & @CRLF & _
			"Microsoft and Google; only editable for ""Custom"".")
	GUICtrlCreateLabel("Token URL:", 20, 407, 115, 20)
	Local $idTokenUrl = GUICtrlCreateInput("", 140, 405, 300, 22)
	GUICtrlSetTip($idTokenUrl, "OAuth2 token endpoint. Filled in automatically for" & @CRLF & _
			"Microsoft and Google; only editable for ""Custom"".")
	GUICtrlCreateLabel("Scope:", 20, 442, 115, 20)
	Local $idScope = GUICtrlCreateInput("", 140, 440, 300, 22)
	GUICtrlSetTip($idScope, "OAuth2 scope(s) for sending via SMTP, separated by spaces." & @CRLF & _
			"Filled in automatically for Microsoft and Google; only" & @CRLF & _
			"editable for ""Custom"".")

	Local $idSave = GUICtrlCreateButton("Save && sign in", 140, 485, 150, 30)
	GUICtrlSetTip($idSave, "Save this account and start the OAuth2 sign-in in your browser.")
	Local $idCancel = GUICtrlCreateButton("Cancel", 300, 485, 100, 30)
	GUICtrlSetTip($idCancel, "Discard this account and close this window.")

	GUISetState(@SW_SHOW, $hGui)
	_DialogOpened()
	_ApplyProviderDefaults($idProvider, $idServerAddr, $idServerPort, $idStartTls, $idClientId, $idTenantId, $idClientSecret, $idAuthUrl, $idTokenUrl, $idScope)

	While 1
		Local $nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE, $idCancel
				GUIDelete($hGui)
				_DialogClosed()
				Return ""

			Case $idProvider
				_ApplyProviderDefaults($idProvider, $idServerAddr, $idServerPort, $idStartTls, $idClientId, $idTenantId, $idClientSecret, $idAuthUrl, $idTokenUrl, $idScope)

			Case $idSave
				Local $sEmail = StringStripWS(GUICtrlRead($idEmail), 3)
				Local $sLocalPassword = GUICtrlRead($idLocalPassword)
				Local $iPort = Number(GUICtrlRead($idLocalPort))
				Local $sLocalAddress = StringStripWS(GUICtrlRead($idLocalAddress), 3)
				Local $sServerAddr = StringStripWS(GUICtrlRead($idServerAddr), 3)
				Local $iServerPort = Number(GUICtrlRead($idServerPort))
				Local $bStartTls = (GUICtrlRead($idStartTls) = $GUI_CHECKED)
				Local $sClientId = StringStripWS(GUICtrlRead($idClientId), 3)
				Local $sTenantId = StringStripWS(GUICtrlRead($idTenantId), 3)
				Local $sClientSecret = GUICtrlRead($idClientSecret)
				Local $sProviderText = GUICtrlRead($idProvider)
				Local $sAuthUrlIn = StringStripWS(GUICtrlRead($idAuthUrl), 3)
				Local $sTokenUrlIn = StringStripWS(GUICtrlRead($idTokenUrl), 3)
				Local $sScopeIn = StringStripWS(GUICtrlRead($idScope), 3)
				Local $bIsCustom = Not (StringInStr($sProviderText, "Microsoft") Or StringInStr($sProviderText, "Google"))

				If $sEmail = "" Or $sLocalPassword = "" Or $iPort <= 1023 Or $sLocalAddress = "" Or $sServerAddr = "" Or $sClientId = "" Then
					_ProxyMsgBox(48, "Incomplete input", _
							"Please provide an e-mail address, a local SMTP password, a local port (> 1023), " & _
							"a local address, a server address and a client ID.", $hGui)
					ContinueLoop
				EndIf

				; B4: ranges and formats; B2: endpoints of a "Custom" account
				If Not _ValidateConnectionInputs($iPort, $sLocalAddress, $sServerAddr, $iServerPort, $hGui) Then ContinueLoop
				If $bIsCustom And Not _ValidateCustomEndpoints($sAuthUrlIn, $sTokenUrlIn, $sScopeIn, $hGui) Then ContinueLoop

				If StringLen($sLocalPassword) < 8 Then
					_ProxyMsgBox(48, "Password too short", "The local SMTP password must be at least 8 characters long.", $hGui)
					ContinueLoop
				EndIf

				If Not StringRegExp($sEmail, "^[^@\s]+@[^@\s]+\.[^@\s]+$") Then
					_ProxyMsgBox(48, "Invalid address", "Please enter a valid e-mail address for the account.", $hGui)
					ContinueLoop
				EndIf

				; The e-mail address doubles as the "Account:<email>" INI
				; section name - saving over an already-configured one would
				; silently overwrite that account's entire configuration
				; (OAuth2 endpoints, tokens, local password, ...) instead of
				; being rejected with a clear reason. Editing an existing
				; account's own settings goes through _ShowEditAccountDialog()
				; instead (where the e-mail address field is read-only for
				; exactly this reason), so there is no legitimate case where
				; this dialog needs to accept an address that is already in use.
				If _AccountExistsNoCase($sEmail) Then ; B3: ignores upper/lower case
					_ProxyMsgBox(48, "Account already exists", _
							$sEmail & " is already configured." & @CRLF & _
							"Use ""Edit"" in Settings to change an existing account instead.", $hGui)
					ContinueLoop
				EndIf

				; Local ports double as INI section names ("SMTP-<port>") - saving
				; over an already-used one would silently overwrite that other
				; account's entire listener configuration rather than just fail
				; to bind the socket later.
				If $g_oListeners.Exists("SMTP-" & $iPort) Then
					_ProxyMsgBox(48, "Port already in use", _
							"Local port " & $iPort & " is already used by another configured account." & @CRLF & _
							"Please choose a different local port.", $hGui)
					ContinueLoop
				EndIf

				Local $sProviderKey = "custom"
				If StringInStr($sProviderText, "Microsoft") Then $sProviderKey = "microsoft"
				If StringInStr($sProviderText, "Google") Then $sProviderKey = "google"
				Local $aPreset = _GetProviderPreset($sProviderKey)

				Local $sPermissionUrl = $aPreset[0]
				Local $sTokenUrl = $aPreset[1]
				If $sProviderKey = "microsoft" And $sTenantId <> "" Then
					$sPermissionUrl = StringReplace($sPermissionUrl, "/common/", "/" & $sTenantId & "/")
					$sTokenUrl = StringReplace($sTokenUrl, "/common/", "/" & $sTenantId & "/")
				EndIf

				; B2: "Custom" uses the URLs/scope entered in the dialog.
				Local $sScope = $aPreset[2]
				If $bIsCustom Then
					$sPermissionUrl = $sAuthUrlIn
					$sTokenUrl = $sTokenUrlIn
					$sScope = $sScopeIn
				EndIf

				GUIDelete($hGui)

				Local $oAcc = ObjCreate("Scripting.Dictionary")
				$oAcc.Item("Username") = $sEmail
				$oAcc.Item("Provider") = $sProviderKey
				$oAcc.Item("PermissionURL") = $sPermissionUrl
				$oAcc.Item("TokenURL") = $sTokenUrl
				$oAcc.Item("Scope") = $sScope
				$oAcc.Item("ClientID") = $sClientId
				$oAcc.Item("TenantID") = $sTenantId
				$oAcc.Item("ClientSecret") = $sClientSecret
				$oAcc.Item("UsePKCE") = $aPreset[6]
				$oAcc.Item("LocalPassword") = $sLocalPassword
				; Set for real inside _RunInteractiveAuth() below, which picks a
				; fresh local port for every sign-in attempt (see its header
				; comment) - left empty here since it is not used before then.
				$oAcc.Item("RedirectURI") = ""
				$oAcc.Item("IniSection") = "Account:" & $sEmail
				$oAcc.Item("AccessToken") = ""
				$oAcc.Item("AccessTokenExpiry") = 0
				$oAcc.Item("RefreshToken") = ""
				$oAcc.Item("NeedsReauth") = True

				_SaveNewListenerAndAccount($iPort, $sLocalAddress, $sServerAddr, $iServerPort, $bStartTls, $sEmail, $oAcc)
				_RunInteractiveAuth($oAcc)

				_LoadAllListeners()
				_StartAllListeners()
				_RebuildTrayMenu()
				_DialogClosed()
				Return $sEmail
		EndSwitch

		If Not _ServiceConnections() Then Sleep($g_iMainLoopTickMs)
	WEnd
EndFunc   ;==>_ShowAddAccountDialog

; ============================================================================
; _ApplyProviderDefaults
; ----------------------------------------------------------------------------
; Description : Pre-fills the server address/port/STARTTLS fields in the
;               "Add account" dialog based on the currently selected
;               provider. For "Custom", this applies the "custom" preset
;               from _GetProviderPreset() too, which clears the server
;               address field (empty ServerAddress) rather than leaving
;               whatever a previously selected provider had filled in -
;               switching to "Custom" should never leave a misleading
;               server address like smtp-mail.outlook.com behind. Also
;               clears Client ID, Directory (tenant) ID and Client secret
;               on every call, for the same reason: a Microsoft client ID
;               left behind after switching to "Google" (or a tenant ID
;               left behind after switching away from "Microsoft", where
;               it is meaningless) would be confusing and easy to
;               accidentally submit unchanged.
;               Also fills in the provider's authorize URL, token URL and
;               scope and makes these three fields editable only for
;               "Custom".
; Parameters  : $idProvider     - Control ID of the provider Combo.
;               $idServerAddr   - Control ID of the server-address Input.
;               $idServerPort   - Control ID of the server-port Input.
;               $idStartTls     - Control ID of the STARTTLS Checkbox.
;               $idClientId     - Control ID of the Client ID Input.
;               $idTenantId     - Control ID of the Directory (tenant) ID
;               Input.
;               $idClientSecret - Control ID of the Client secret Input.
;               $idAuthUrl, $idTokenUrl, $idScope - Control IDs of the
;               Authorize URL, Token URL and Scope Inputs.
; Returns     : (nothing - updates the GUI controls as a side effect)
; ============================================================================
Func _ApplyProviderDefaults($idProvider, $idServerAddr, $idServerPort, $idStartTls, $idClientId, $idTenantId, $idClientSecret, $idAuthUrl, $idTokenUrl, $idScope)
	Local $sSel = GUICtrlRead($idProvider)
	Local $sKey = "custom"
	If StringInStr($sSel, "Microsoft") Then $sKey = "microsoft"
	If StringInStr($sSel, "Google") Then $sKey = "google"

	Local $aPreset = _GetProviderPreset($sKey)
	GUICtrlSetData($idServerAddr, $aPreset[3])
	GUICtrlSetData($idServerPort, String($aPreset[4]))
	If Number($aPreset[5]) = 1 Then
		GUICtrlSetState($idStartTls, $GUI_CHECKED)
	Else
		GUICtrlSetState($idStartTls, $GUI_UNCHECKED)
	EndIf

	GUICtrlSetData($idClientId, "")
	GUICtrlSetData($idTenantId, "")
	GUICtrlSetData($idClientSecret, "")
	; B2: show the provider's OAuth2 endpoints and scope; only editable for "Custom".
	GUICtrlSetData($idAuthUrl, $aPreset[0])
	GUICtrlSetData($idTokenUrl, $aPreset[1])
	GUICtrlSetData($idScope, $aPreset[2])
	_SetEndpointFieldsState($sKey = "custom", $idAuthUrl, $idTokenUrl, $idScope)
EndFunc   ;==>_ApplyProviderDefaults

; ============================================================================
; _SetEndpointFieldsState
; ----------------------------------------------------------------------------
; Description : Enables the "Authorize URL", "Token URL" and "Scope" fields
;               of the Add/Edit account dialogs only for the "Custom"
;               provider. For Microsoft and Google they stay visible (so the
;               values in use can be seen) but cannot be edited - those
;               come from the provider preset.
; Parameters  : $bEnable    - True to make the fields editable.
;               $idAuthUrl, $idTokenUrl, $idScope - The three input controls.
; Returns     : (nothing)
; ============================================================================
Func _SetEndpointFieldsState($bEnable, $idAuthUrl, $idTokenUrl, $idScope)
	Local $iState = $GUI_DISABLE
	If $bEnable Then $iState = $GUI_ENABLE
	GUICtrlSetState($idAuthUrl, $iState)
	GUICtrlSetState($idTokenUrl, $iState)
	GUICtrlSetState($idScope, $iState)
EndFunc   ;==>_SetEndpointFieldsState

; ============================================================================
; _ValidateCustomEndpoints
; ----------------------------------------------------------------------------
; Description : Checks the three OAuth2 fields of a "Custom" account: both
;               URLs must be filled in and start with https://, the scope
;               must not be empty. Shows a message and returns False if not.
; Parameters  : $sAuthUrl, $sTokenUrl, $sScope - The values entered.
;               $hGui - Parent window for the message.
; Returns     : True if everything is usable, False otherwise.
; ============================================================================
Func _ValidateCustomEndpoints($sAuthUrl, $sTokenUrl, $sScope, $hGui)
	If StringLeft(StringLower($sAuthUrl), 8) <> "https://" Or StringLeft(StringLower($sTokenUrl), 8) <> "https://" Or $sScope = "" Then
		_ProxyMsgBox(48, "Incomplete input", _
				"For the ""Custom"" provider, please enter the authorize URL and the token URL" & @CRLF & _
				"(both starting with https://) and the OAuth2 scope required for SMTP sending." & @CRLF & @CRLF & _
				"You will find these values in your provider's OAuth2 documentation.", $hGui)
		Return False
	EndIf
	Return True
EndFunc   ;==>_ValidateCustomEndpoints

; ============================================================================
; _ValidateConnectionInputs
; ----------------------------------------------------------------------------
; Description : Range and format checks for the Add/Edit account dialogs:
;               local port 1024-65535, local address a valid IPv4 address
;               (0.0.0.0 and 127.0.0.1 included), server address without
;               spaces, server port 1-65535. Shows a message and returns
;               False on the first problem found.
; Parameters  : $iLocalPort, $sLocalAddress, $sServerAddr, $iServerPort -
;               The values entered. $hGui - Parent window for the message.
; Returns     : True if everything is valid, False otherwise.
; ============================================================================
Func _ValidateConnectionInputs($iLocalPort, $sLocalAddress, $sServerAddr, $iServerPort, $hGui)
	If $iLocalPort < 1024 Or $iLocalPort > 65535 Then
		_ProxyMsgBox(48, "Invalid local port", "The local port must be a number from 1024 to 65535.", $hGui)
		Return False
	EndIf
	If Not _IsValidIPv4($sLocalAddress) Then
		_ProxyMsgBox(48, "Invalid local address", _
				"The local address must be an IPv4 address, e.g. 127.0.0.1 (this PC only)," & @CRLF & _
				"0.0.0.0 (all network interfaces) or one IP address of this PC.", $hGui)
		Return False
	EndIf
	If $sServerAddr = "" Or StringInStr($sServerAddr, " ") Then
		_ProxyMsgBox(48, "Invalid server address", "The server address must not be empty or contain spaces.", $hGui)
		Return False
	EndIf
	If $iServerPort < 1 Or $iServerPort > 65535 Then
		_ProxyMsgBox(48, "Invalid server port", "The server port must be a number from 1 to 65535 (usually 587 or 465).", $hGui)
		Return False
	EndIf
	Return True
EndFunc   ;==>_ValidateConnectionInputs

; ============================================================================
; _IsValidIPv4
; ----------------------------------------------------------------------------
; Description : True if $sAddress is a dotted IPv4 address (four numbers
;               0-255).
; Parameters  : $sAddress - Text to check.
; Returns     : True or False.
; ============================================================================
Func _IsValidIPv4($sAddress)
	Local $aParts = StringRegExp($sAddress, "^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$", 1)
	If @error Then Return False
	Local $i = 0
	For $i = 0 To 3
		If Number($aParts[$i]) > 255 Then Return False
	Next
	Return True
EndFunc   ;==>_IsValidIPv4

; ============================================================================
; _AccountExistsNoCase
; ----------------------------------------------------------------------------
; Description : True if an account with this e-mail address already exists,
;               ignoring upper/lower case. The account dictionary itself
;               compares exactly, but INI section names do not - so
;               "Info@x.de" and "info@x.de" would otherwise end up as two
;               accounts sharing (and overwriting) one INI section.
; Parameters  : $sEmail - Address to look for.
; Returns     : True or False.
; ============================================================================
Func _AccountExistsNoCase($sEmail)
	Local $aKeys = $g_oAccountsByEmail.Keys()
	Local $i = 0
	For $i = 0 To UBound($aKeys) - 1
		If StringLower($aKeys[$i]) == StringLower($sEmail) Then Return True
	Next
	Return False
EndFunc   ;==>_AccountExistsNoCase

; ============================================================================
; _SaveNewListenerAndAccount
; ----------------------------------------------------------------------------
; Description : Persists a newly configured listener and its associated
;               account to the INI configuration file: writes the
;               "SMTP-<port>" section (local/server address & port,
;               STARTTLS flag, linked account e-mail, Active=1) and the
;               "Account:<email>" section (provider, OAuth2 endpoints,
;               scope, redirect URI, client ID, tenant/directory ID,
;               DPAPI-encrypted client secret, PKCE flag, DPAPI-encrypted
;               local SMTP password via _SetLocalPassword()). Does not yet
;               touch any OAuth2 tokens - those are written later by
;               _SaveTokens() once the interactive sign-in completes.
; Parameters  : $iLocalPort  - Local TCP port for the new listener.
;               $sLocalAddr  - Local bind address (normally "127.0.0.1").
;               $sServerAddr - Real SMTP server hostname.
;               $iServerPort - Real SMTP server port.
;               $bStartTls   - True to use STARTTLS, False for implicit TLS.
;               $sEmail      - Account e-mail address.
;               $oAcc        - Account dictionary with the OAuth2 client
;               configuration to persist.
; Returns     : (nothing - writes to the INI file as a side effect)
; ============================================================================
Func _SaveNewListenerAndAccount($iLocalPort, $sLocalAddr, $sServerAddr, $iServerPort, $bStartTls, $sEmail, $oAcc)
	Local $sListenerSection = "SMTP-" & $iLocalPort
	IniWrite($g_sIniPath, $sListenerSection, "LocalAddress", $sLocalAddr)
	IniWrite($g_sIniPath, $sListenerSection, "LocalPort", $iLocalPort)
	IniWrite($g_sIniPath, $sListenerSection, "ServerAddress", $sServerAddr)
	IniWrite($g_sIniPath, $sListenerSection, "ServerPort", $iServerPort)
	Local $sTls = "0"
	If $bStartTls Then $sTls = "1"
	IniWrite($g_sIniPath, $sListenerSection, "ServerSTARTTLS", $sTls)
	IniWrite($g_sIniPath, $sListenerSection, "Account", $sEmail)
	IniWrite($g_sIniPath, $sListenerSection, "Active", "1")

	Local $sAccSection = $oAcc.Item("IniSection")
	IniWrite($g_sIniPath, $sAccSection, "Provider", $oAcc.Item("Provider"))
	IniWrite($g_sIniPath, $sAccSection, "PermissionURL", $oAcc.Item("PermissionURL"))
	IniWrite($g_sIniPath, $sAccSection, "TokenURL", $oAcc.Item("TokenURL"))
	IniWrite($g_sIniPath, $sAccSection, "Scope", $oAcc.Item("Scope"))
	IniWrite($g_sIniPath, $sAccSection, "RedirectURI", $oAcc.Item("RedirectURI"))
	IniWrite($g_sIniPath, $sAccSection, "ClientID", $oAcc.Item("ClientID"))
	IniWrite($g_sIniPath, $sAccSection, "TenantID", $oAcc.Item("TenantID"))
	IniWrite($g_sIniPath, $sAccSection, "ClientSecretEnc", _DPAPI_Protect($oAcc.Item("ClientSecret")))
	Local $sPkce = "0"
	If Number($oAcc.Item("UsePKCE")) = 1 Then $sPkce = "1"
	IniWrite($g_sIniPath, $sAccSection, "UsePKCE", $sPkce)
	_SetLocalPassword($oAcc, $oAcc.Item("LocalPassword"))
EndFunc   ;==>_SaveNewListenerAndAccount

; ============================================================================
; _SetListenerActive
; ----------------------------------------------------------------------------
; Description : Enables or disables a listener: persists the "Active" INI
;               key under its "SMTP-<port>" section. Does not itself
;               open/close any socket, touch $g_oListeners, or close any
;               in-progress connection - the caller is expected to follow
;               up with _LoadAllListeners() and _StartAllListeners() (which
;               close the socket for a listener that just became inactive,
;               or open one for a listener that just became active), and,
;               when disabling, with _CloseConnectionsForAccount() to
;               forcibly end any connection already in progress (see
;               _ShowSettingsDialog()'s "Enable/Disable" handler for the
;               full sequence).
; Parameters  : $sListenerSection - The "SMTP-<port>" INI section name.
;               $bActive          - True to enable, False to disable.
; Returns     : (nothing - writes to the INI file as a side effect)
; ============================================================================
Func _SetListenerActive($sListenerSection, $bActive)
	Local $sVal = "0"
	If $bActive Then $sVal = "1"
	IniWrite($g_sIniPath, $sListenerSection, "Active", $sVal)
EndFunc   ;==>_SetListenerActive

; ============================================================================
; _DeleteAccount
; ----------------------------------------------------------------------------
; Description : Permanently removes an account and its listener: forcibly
;               closes any connection currently in progress for this
;               account (_CloseConnectionsForAccount()), closes the
;               listener's socket if it is currently open, then deletes
;               both its "SMTP-<port>" and the account's "Account:<email>"
;               INI sections outright (IniDelete - not just individual
;               keys). The caller is expected to follow up with
;               _LoadAllListeners()/_StartAllListeners() to refresh
;               $g_oListeners/$g_oAccountsByEmail from disk.
; Parameters  : $oAcc      - Account dictionary to delete (must contain
;               "IniSection" and "Username").
;               $oListener - The account's listener dictionary (must
;               contain "LocalPort" and "Socket"), or 0 if none was found.
; Returns     : (nothing - writes to the INI file as a side effect)
; ============================================================================
Func _DeleteAccount($oAcc, $oListener)
	_CloseConnectionsForAccount($oAcc.Item("Username"))
	If IsObj($oListener) Then
		If $oListener.Item("Socket") <> -1 Then TCPCloseSocket($oListener.Item("Socket"))
		IniDelete($g_sIniPath, "SMTP-" & $oListener.Item("LocalPort"))
	EndIf
	IniDelete($g_sIniPath, $oAcc.Item("IniSection"))
	LogFile("Account " & $oAcc.Item("Username") & " was deleted.")
EndFunc   ;==>_DeleteAccount

; ============================================================================
; _SetLocalPassword
; ----------------------------------------------------------------------------
; Description : Sets (or changes) the local SMTP password an account
;               requires from its local client (see
;               _CheckLocalCredentials()): updates the in-memory account
;               dictionary and persists the DPAPI-encrypted value to the
;               account's INI section immediately, so it survives a
;               restart without requiring the rest of the account to be
;               re-saved. Used both when a new account is first created
;               (from _SaveNewListenerAndAccount()) and when an existing
;               account's password is changed via the "Edit" dialog's
;               Save button (_ShowEditAccountDialog()).
; Parameters  : $oAcc         - Account dictionary (must contain
;               "IniSection").
;               $sNewPassword - The new local SMTP password, in plain text.
; Returns     : (nothing - mutates $oAcc and writes to the INI file as a
;               side effect)
; ============================================================================
Func _SetLocalPassword($oAcc, $sNewPassword)
	$oAcc.Item("LocalPassword") = $sNewPassword
	IniWrite($g_sIniPath, $oAcc.Item("IniSection"), "LocalPasswordEnc", _DPAPI_Protect($sNewPassword))
EndFunc   ;==>_SetLocalPassword

; ############################################################################
; #  TRAY MENU
; ############################################################################

; ============================================================================
; _RebuildTrayMenu
; ----------------------------------------------------------------------------
; Description : Fully tears down and rebuilds the entire tray menu from
;               scratch: deletes every tray item created on a previous
;               call (tracked in $g_aAllTrayItemIds), then recreates the
;               title item (program name + version - opens About), one entry per configured account
;               (labelled "[disabled]" if its listener's Active flag is
;               off, else "[sign-in required]" or "[signed in]" depending
;               on NeedsReauth - see _FindListenerForAccount()), and
;               finally the bottom action group "Settings" (submenu:
;               "Accounts", "Advanced", "Notifications", separator,
;               "Autostart") / "Open Log
;               File" / Exit - each of the three sections
;               (title, accounts, action group) is separated from its
;               neighbour by a blank separator item, with the one before
;               the accounts only created when at least one account
;               exists (so there is never a redundant separator with
;               nothing between it and the next one).
;               The title item (the program's main icon), "Settings" (set by
;               its position, since a submenu entry has no command ID - see
;               _TrayMenuPosOfSubmenu()), "Accounts", "Advanced" and
;               "Notifications" (each its own icon, W1), the accounts (icon of
;               their provider type, _TrayProviderIcon()), "Open Log File" and "Exit" each get an icon via
;               TrayItemSetIcon() -
;               extracted from the compiled .exe's own embedded resources
;               (see the #AutoIt3Wrapper_Res_Icon_Add directives near the
;               top of the script) when @Compiled, or straight from the
;               loose .ico file under "icons\" next to the script
;               otherwise, so this works identically whether run compiled
;               or as a raw .au3 script. "Autostart" deliberately has no
;               icon of its own - it is a checkable item (see
;               _IsAutostartEnabled()/_ToggleAutostart()), and the
;               checkmark itself already shows its state. DeleteAllhBitmaps()
;               is called first, before the old tray items are torn down,
;               to free the previous run's icon bitmaps - without this,
;               every rebuild would leak GDI bitmap handles, since a new
;               set of tray item IDs (and therefore new $mhBitmapStorage
;               keys) is created every time this function runs, orphaning
;               the previous ones.
;               Called once at startup and again whenever the account
;               list or an account's status changes. Rebuilding from
;               scratch (rather than patching individual items) avoids
;               having to reason about tray item ordering and insertion
;               positions. Toggling "Autostart" itself does NOT trigger a
;               full rebuild - see its own Case in _Main()'s tray message
;               handling, which updates just that one item's checkmark
;               directly instead.
;               The tooltip is reset to the program name here and rebuilt
;               with the current status by _UpdateTrayTooltip() on its next
;               run.
; Parameters  : (none)
; Returns     : (nothing - rebuilds the tray menu as a side effect)
; ============================================================================
Func _RebuildTrayMenu()
	DeleteAllhBitmaps()
	Local $hMenu = TrayItemGetHandle(0)

	Local $i = 0
	For $i = 0 To UBound($g_aAllTrayItemIds) - 1
		TrayItemDelete($g_aAllTrayItemIds[$i])
	Next
	Local $aEmpty[0]
	$g_aAllTrayItemIds = $aEmpty
	$g_oAccountMenuItems.RemoveAll()

	; Title item: program name and version. R1 (v61): clicking it opens the
	; About dialog (Case $g_idTrayTitle in _Main()); like every other item it
	; is disabled while a dialog is open (_SetTrayMenuEnabled()).
	Local $idTitle = TrayCreateItem($g_sAppName & "  v" & _GetScriptVersion()) ; with version (since v56)
	$g_idTrayTitle = $idTitle
	_ArrayAdd($g_aAllTrayItemIds, $idTitle)
	; The app's own main icon (index 0 - no $iIconOffset adjustment needed,
	; unlike the other, separately-added tray icons below, since this is
	; the primary icon embedded via #AutoIt3Wrapper_Icon, not one of the
	; extra #AutoIt3Wrapper_Res_Icon_Add resources), matching how
	; TraySetIcon(@ScriptFullPath) and _SetDialogIcon() both already pick
	; up this same icon elsewhere without needing an index at all.
	If @Compiled Then
		TrayItemSetIcon($hMenu, $idTitle, @ScriptFullPath, 0, $iTrayIconSize)
	Else
		TrayItemSetIcon($hMenu, $idTitle, @ScriptDir & "\icons\default.ico", 0, $iTrayIconSize)
	EndIf

	If $g_oAccountsByEmail.Count > 0 Then
		Local $idSep1 = TrayCreateItem("")
		_ArrayAdd($g_aAllTrayItemIds, $idSep1)

		Local $aEmails = $g_oAccountsByEmail.Keys()
		For $i = 0 To UBound($aEmails) - 1
			Local $sEmail = $aEmails[$i]
			Local $oAcc = $g_oAccountsByEmail.Item($sEmail)
			Local $sLabel = $sEmail
			Local $oL2 = _FindListenerForAccount($sEmail)
			If IsObj($oL2) And Not $oL2.Item("Active") Then
				$sLabel &= "   [disabled]"
			ElseIf $oAcc.Item("NeedsReauth") Then
				$sLabel &= "   [sign-in required]"
			Else
				$sLabel &= "   [signed in]"
			EndIf
			Local $idItem = TrayCreateItem($sLabel)
			_ArrayAdd($g_aAllTrayItemIds, $idItem)
			$g_oAccountMenuItems.Item(String($idItem)) = $sEmail
			; U1 (v74): icon of the account's provider type (M365 / Google /
			; custom), so the kind of account is visible at a glance.
			_TrayProviderIcon($hMenu, $idItem, $oAcc.Item("Provider"))
		Next
	EndIf

	;Local $idSep3 = TrayCreateItem("")
	;_ArrayAdd($g_aAllTrayItemIds, $idSep3)

	Local $idSep4 = TrayCreateItem("")
	_ArrayAdd($g_aAllTrayItemIds, $idSep4)

	; R2 (v61): "Settings" is a submenu with "Accounts" (the account list,
	; _ShowSettingsDialog()) and "Advanced" (_ShowAdvancedSettingsDialog()).
	; The child items are added to $g_aAllTrayItemIds BEFORE the submenu
	; itself, so the next rebuild deletes them before their parent.
	; R3 (v62): "Autostart" moved into this submenu (below a separator), and
	; "Settings" now comes before "Open Log File".
	$g_idMenuSettings = TrayCreateMenu("Settings")
	$g_idMenuAccounts = TrayCreateItem("Accounts", $g_idMenuSettings)
	$g_idMenuAdvanced = TrayCreateItem("Advanced", $g_idMenuSettings)
	$g_idMenuNotifications = TrayCreateItem("Notifications", $g_idMenuSettings) ; E1
	$g_idMenuSettingsSep = TrayCreateItem("", $g_idMenuSettings)
	; No dedicated icon for Autostart - the checkmark itself is the state
	; indicator, matching how simple on/off toggle items are commonly
	; shown in a tray menu. Reflects the CURRENT registry state fresh on
	; every rebuild (see _IsAutostartEnabled()'s own header comment for
	; why this is not a separately-tracked flag of our own) - always
	; unchecked when not @Compiled, since _ToggleAutostart() never
	; writes anything in that case either.
	$g_idMenuAutostart = TrayCreateItem("Autostart", $g_idMenuSettings)
	If @Compiled And _IsAutostartEnabled() Then
		TrayItemSetState($g_idMenuAutostart, $TRAY_CHECKED)
	Else
		TrayItemSetState($g_idMenuAutostart, $TRAY_UNCHECKED)
	EndIf
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuAccounts)
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuAdvanced)
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuNotifications)
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuSettingsSep)
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuAutostart)
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuSettings)
	; A submenu entry has no command ID of its own in the parent menu, so its
	; icon is set by its position there (see _TrayMenuPosOfSubmenu()).
	Local $iSettingsPos = _TrayMenuPosOfSubmenu($hMenu, TrayItemGetHandle($g_idMenuSettings))
	If $iSettingsPos >= 0 Then
		If @Compiled Then
			TrayItemSetIcon($hMenu, $iSettingsPos, @ScriptFullPath, $iIconNumberSettings - $iIconOffset, $iTrayIconSize, True, "SettingsMenu")
		Else
			TrayItemSetIcon($hMenu, $iSettingsPos, @ScriptDir & "\icons\Settings.ico", 0, $iTrayIconSize, True, "SettingsMenu")
		EndIf
	EndIf
	; W1 (v77): each item inside the submenu has its own icon - Accounts
	; (people), Advanced (sliders), Notifications (bell). These are normal
	; items with a command ID, addressed in the submenu's own menu handle.
	; (Autostart keeps no icon: its checkmark is the state.)
	Local $hSettingsSub = TrayItemGetHandle($g_idMenuSettings)
	If $hSettingsSub <> 0 Then
		If @Compiled Then
			TrayItemSetIcon($hSettingsSub, $g_idMenuAccounts, @ScriptFullPath, $iIconNumberAccounts - $iIconOffset, $iTrayIconSize)
			TrayItemSetIcon($hSettingsSub, $g_idMenuAdvanced, @ScriptFullPath, $iIconNumberAdvanced - $iIconOffset, $iTrayIconSize)
			TrayItemSetIcon($hSettingsSub, $g_idMenuNotifications, @ScriptFullPath, $iIconNumberNotify - $iIconOffset, $iTrayIconSize)
		Else
			TrayItemSetIcon($hSettingsSub, $g_idMenuAccounts, @ScriptDir & "\icons\Accounts.ico", 0, $iTrayIconSize)
			TrayItemSetIcon($hSettingsSub, $g_idMenuAdvanced, @ScriptDir & "\icons\Advanced.ico", 0, $iTrayIconSize)
			TrayItemSetIcon($hSettingsSub, $g_idMenuNotifications, @ScriptDir & "\icons\Notify.ico", 0, $iTrayIconSize)
		EndIf
	EndIf

	$g_idMenuOpenLog = TrayCreateItem("Open Log File")
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuOpenLog)
	If @Compiled Then
		TrayItemSetIcon($hMenu, $g_idMenuOpenLog, @ScriptFullPath, $iIconNumberLog - $iIconOffset, $iTrayIconSize)
	Else
		TrayItemSetIcon($hMenu, $g_idMenuOpenLog, @ScriptDir & "\icons\Log.ico", 0, $iTrayIconSize)
	EndIf

	Local $idSep5 = TrayCreateItem("")
	_ArrayAdd($g_aAllTrayItemIds, $idSep5)
	$g_idMenuExit = TrayCreateItem("Exit")
	_ArrayAdd($g_aAllTrayItemIds, $g_idMenuExit)
	If @Compiled Then
		TrayItemSetIcon($hMenu, $g_idMenuExit, @ScriptFullPath, $iIconNumberExit - $iIconOffset, $iTrayIconSize)
	Else
		TrayItemSetIcon($hMenu, $g_idMenuExit, @ScriptDir & "\icons\Exit.ico", 0, $iTrayIconSize)
	EndIf

	If @Compiled then
		TraySetIcon(@ScriptFullPath)
	Else
		TraySetIcon(@ScriptDir & "\icons\default.ico")
	EndIf
	TraySetToolTip($g_sAppName)
	$g_bTooltipDirty = True ; E8: the status tooltip is rebuilt on the next update
	TraySetState($TRAY_ICONSTATE_SHOW)

	; A rebuild can happen while a dialog is already open (e.g. toggling
	; Enable/Disable from within Settings) and creates entirely new,
	; enabled-by-default item IDs - re-apply the disabled state
	; immediately in that case, or the fresh items would be clickable
	; again despite a dialog still being open. See _DialogOpened()'s
	; header comment for why that matters.
	If $g_iOpenDialogCount > 0 Then _SetTrayMenuEnabled(False)
EndFunc   ;==>_RebuildTrayMenu

; ============================================================================
; _TrayProviderIcon
; ----------------------------------------------------------------------------
; Description : U1 (v74): gives an account entry of the tray menu the icon
;               of its provider type: "microsoft" (Microsoft 365 /
;               Outlook.com) -> ProviderMicrosoft.ico (blue, "M"), "google"
;               -> ProviderGoogle.ico (red, "G"), anything else ("custom",
;               own OAuth2 endpoints) -> ProviderCustom.ico (grey, envelope).
;               These are simple icons of their own, deliberately not the
;               providers' official logos. Compiled, the icons are taken
;               from the .exe's resources ($iIconNumberProvider...);
;               uncompiled, from the .ico files in "icons\" next to the
;               script.
; Parameters  : $hMenu     - Handle of the tray menu (TrayItemGetHandle(0)).
;               $idItem    - Control ID of the account's tray item.
;               $sProvider - The account's "Provider" value from the INI.
; Returns     : (nothing)
; ============================================================================
Func _TrayProviderIcon($hMenu, $idItem, $sProvider)
	Local $iNumber = $iIconNumberProviderCustom, $sFile = "ProviderCustom.ico"
	Switch StringLower($sProvider)
		Case "microsoft"
			$iNumber = $iIconNumberProviderMicrosoft
			$sFile = "ProviderMicrosoft.ico"
		Case "google"
			$iNumber = $iIconNumberProviderGoogle
			$sFile = "ProviderGoogle.ico"
	EndSwitch
	If @Compiled Then
		TrayItemSetIcon($hMenu, $idItem, @ScriptFullPath, $iNumber - $iIconOffset, $iTrayIconSize)
	Else
		TrayItemSetIcon($hMenu, $idItem, @ScriptDir & "\icons\" & $sFile, 0, $iTrayIconSize)
	EndIf
EndFunc   ;==>_TrayProviderIcon

; ############################################################################
; #  HELPER FUNCTIONS: LOGGING, TIME, ENCODING, ENCRYPTION, HTTP
; ############################################################################

; ============================================================================
; _NowLocalMs
; ----------------------------------------------------------------------------
; Description : Reads the current LOCAL date/time, including milliseconds,
;               via the Win32 GetLocalTime API (the @YEAR/@MON/.../@SEC
;               macros do not offer millisecond precision). Used by
;               LogFile()/LogFile() so log timestamps can distinguish
;               events that happen within the same second - useful when
;               diagnosing timing-sensitive issues (e.g. figuring out
;               which of several rapid log lines came first).
; Parameters  : (none)
; Returns     : A 7-element array: [0]=year, [1]=month, [2]=day,
;               [3]=hour, [4]=minute, [5]=second, [6]=millisecond.
; ============================================================================
Func _NowLocalMs()
	Local $tST = DllStructCreate("ushort wYear;ushort wMonth;ushort wDayOfWeek;ushort wDay;" & _
			"ushort wHour;ushort wMinute;ushort wSecond;ushort wMilliseconds")
	DllCall("kernel32.dll", "none", "GetLocalTime", "struct*", $tST)

	Local $aOut[7]
	$aOut[0] = DllStructGetData($tST, "wYear")
	$aOut[1] = DllStructGetData($tST, "wMonth")
	$aOut[2] = DllStructGetData($tST, "wDay")
	$aOut[3] = DllStructGetData($tST, "wHour")
	$aOut[4] = DllStructGetData($tST, "wMinute")
	$aOut[5] = DllStructGetData($tST, "wSecond")
	$aOut[6] = DllStructGetData($tST, "wMilliseconds")
	Return $aOut
EndFunc   ;==>_NowLocalMs

; ============================================================================
; _FormatBytes
; ----------------------------------------------------------------------------
; Description : J1: formats a byte count for the log - "850 bytes",
;               "210.4 KB" or "5.03 MB" (1 KB = 1024 bytes).
; Parameters  : $iBytes - Number of bytes.
; Returns     : The formatted string.
; ============================================================================
Func _FormatBytes($iBytes)
	If $iBytes < 1024 Then Return $iBytes & " bytes"
	If $iBytes < 1048576 Then Return StringFormat("%.1f KB", $iBytes / 1024)
	Return StringFormat("%.2f MB", $iBytes / 1048576)
EndFunc   ;==>_FormatBytes

; ============================================================================
; _ClockTimeAgo
; ----------------------------------------------------------------------------
; Description : J1: the local clock time ("HH:MM:SS") of a moment that lies
;               $iMsAgo milliseconds in the past - so a timestamp only has
;               to be stored as a cheap TimerInit() and is turned into a
;               clock time once, when it is actually written to the log.
;               Wraps correctly past midnight.
; Parameters  : $iMsAgo - How many milliseconds ago.
; Returns     : The time as "HH:MM:SS".
; ============================================================================
Func _ClockTimeAgo($iMsAgo)
	Local $iSec = Mod(@HOUR * 3600 + @MIN * 60 + @SEC - Round($iMsAgo / 1000), 86400)
	If $iSec < 0 Then $iSec += 86400
	Return StringFormat("%02d:%02d:%02d", Int($iSec / 3600), Int(Mod($iSec, 3600) / 60), Mod($iSec, 60))
EndFunc   ;==>_ClockTimeAgo

; ============================================================================
; _FormatDurationMs
; ----------------------------------------------------------------------------
; Description : Formats an elapsed-time value (in whole milliseconds) for
;               display and logging: plain "Nms" for anything under a
;               minute (the common case, and the clearest to read at a
;               glance), or "M:SS.mmm" (minutes:seconds.milliseconds,
;               seconds and milliseconds zero-padded, minutes not) once a
;               minute or more has elapsed - e.g. an unusually slow send
;               of a large attachment. "94000ms" takes noticeably longer
;               to parse at a glance than "1:34.000". Used for the test
;               e-mail timing shown in _ShowSendTestEmailDialog()/
;               _SendTestEmail() and their matching log lines.
; Parameters  : $iMs - Elapsed time in whole milliseconds (e.g. from
;               Round(TimerDiff(...))).
; Returns     : The formatted string.
; ============================================================================
Func _FormatDurationMs($iMs)
	If $iMs < 60000 Then Return $iMs & "ms"
	Local $iMinutes = Int($iMs / 60000)
	Local $iSeconds = Int(Mod($iMs, 60000) / 1000)
	Local $iMillis = Mod($iMs, 1000)
	Return $iMinutes & ":" & StringFormat("%02d", $iSeconds) & "." & StringFormat("%03d", $iMillis)
EndFunc   ;==>_FormatDurationMs

; ============================================================================
; LogFile
; ----------------------------------------------------------------------------
; Description : Combines what used to be two separate functions (_Log() and
;               LogFile()) into one: writes a timestamped line to the
;               log file (unless disabled via $g_bUseLogSetting) and echoes
;               it to the console (only when run as a raw script, not
;               compiled - a compiled GUI-mode .exe has no console attached
;               unless launched from one anyway, so building/writing that
;               output would be pointless overhead there) - but only if
;               $iLevel is at or below the configured $g_iLogLevel
;               threshold ("I want to see everything up to this level" -
;               0 is the most important/always-shown end, 9 the most
;               verbose). This replaces the previous fixed split (_Log()
;               for infrequent, important events, always shown;
;               LogFile() for high-frequency byte-level tracing, an
;               all-or-nothing on/off toggle) with graduated levels
;               instead - see LEVEL CONVENTIONS below for how this script
;               uses them.
;
;               LEVEL CONVENTIONS USED IN THIS SCRIPT:
;                 0 (the default - omit $iLevel entirely for these)
;                   Coarse, infrequent, important events - what _Log() used
;                   to handle: connections opening/closing, sign-in
;                   results, e-mails relayed, warnings, errors. Always
;                   logged, since $g_iLogLevel (5 compiled / 9 raw script,
;                   by default) is never set below 0 in practice.
;                 6
;                   High-frequency, byte-/line-level tracing - what
;                   _ConsoleLog() used to handle. Off by default when
;                   compiled (5 < 6), on by default when run as a raw
;                   script (9 >= 6) - raise "LogLevel" to 6 or higher in
;                   the INI (compiled) to re-enable this level of detail
;                   for troubleshooting.
;                 8
;                   Performance/timing diagnostics - how long specific
;                   phases of sending a message took (obtaining an
;                   access token, the XOAUTH2 sign-in round trip, the
;                   client uploading a message, the real server
;                   acknowledging it afterward - see
;                   _Auth_GetValidAccessToken()'s caller in
;                   _OnServerLine(), and _SniffClientData()/
;                   _SniffServerData()). Off by default when compiled
;                   (5 < 8); raise "LogLevel" to 8 or 9 in the INI to
;                   narrow down where a slow send is actually spending
;                   its time.
;               Nothing stops a future call from using an intermediate
;               level for something between these.
;
;               If the log file can't be opened, it is tried again up to
;               two more times after a short pause (about 10-15 ms each):
;               another process may hold the file for a moment - a virus
;               scanner, an editor, the log rotation, later perhaps a
;               second process of this program. (The /notify sender of the
;               notifications does not write into the log itself - see
;               _NotifyProcessMain().) Only if
;               all three attempts fail does file logging disable
;               itself for the rest of the session ($g_bUseLogSetting set
;               to False) rather than repeatedly retrying a write that is
;               just going to keep failing - console output (if
;               applicable) is unaffected by this. A single, one-time
;               TrayTip() (not a blocking MsgBox/_ProxyMsgBox()) notes
;               this happened, so it is visible without interrupting
;               whatever the proxy is doing at that moment - this can be
;               called from deep within connection-handling code, not just
;               from GUI code, so anything that would need
;               _DialogOpened()/_DialogClosed() handling is deliberately
;               avoided here.
;               The log file is opened in UTF-8 append mode (FileOpen mode
;               137 = 1 append + 8 create the folder + 128 write-as-UTF-8), so non-ASCII
;               characters (e.g. in an account's e-mail subject - see
;               _SniffClientData()) are stored correctly rather than
;               getting mangled.
; Parameters  : $sLogText       - Message text to log (a local date/time
;               stamp is prepended automatically).
;               $iLevel         - This message's own level, 0 (default) to
;               9 - see LEVEL CONVENTIONS above. Values outside 0-9 are
;               normalised to 0.
;               $sCustomLogFile - Log file path; defaults to $g_sLogPath.
;               Passing "" suppresses the file-writing step entirely
;               (console output, if applicable, still happens).
; Returns     : (nothing)
; ============================================================================
Func LogFile($sLogText, $iLevel = 0, $sCustomLogFile = $g_sLogPath)
	If $iLevel < 0 Or $iLevel > 9 Then $iLevel = 0
	If $g_iLogLevel < $iLevel Then Return

	Local $aT = _NowLocalMs()
	Local $sTimeStr = StringFormat("%02d:%02d:%02d.%03d", $aT[3], $aT[4], $aT[5], $aT[6])

	If $sCustomLogFile <> "" And $g_bUseLogSetting Then
		Local $hFile = FileOpen($sCustomLogFile, 137) ; 1 (append) + 8 (create the folder if missing, E3) + 128 (write as UTF-8)
		; The file may be held by another process for a moment - try again
		; twice before giving up (see the header comment).
		Local $iLogTry = 0
		For $iLogTry = 1 To 2
			If $hFile <> -1 Then ExitLoop
			Sleep(10)
			$hFile = FileOpen($sCustomLogFile, 137)
		Next
		If $hFile = -1 Then
			$g_bUseLogSetting = False
			TrayTip($g_sAppName, "The log file could not be written to and has been disabled for the " & _
					"rest of this session. Check that " & $g_sAppName & " has write permission for:" & @CRLF & _
					$sCustomLogFile, 15)
		Else
			FileWriteLine($hFile, $aT[0] & "-" & StringFormat("%02d", $aT[1]) & "-" & StringFormat("%02d", $aT[2]) & _
					" " & $sTimeStr & "  " & $sLogText)
			FileClose($hFile)
		EndIf
	EndIf

	If Not @Compiled Then ConsoleWrite("[" & $sTimeStr & "] " & $sLogText & @CRLF)
EndFunc   ;==>LogFile

; ============================================================================
; _ComErrorHandler
; ----------------------------------------------------------------------------
; Description : Registered once (via ObjEvent) as the global COM error
;               handler for the whole script, so that a COM error (e.g.
;               from the WinHttp object) is logged instead of crashing the
;               process. AutoIt calls this automatically whenever a COM
;               call raises an error.
; Parameters  : $oError - COM error object supplied by AutoIt, exposing
;               "number" and "windescription" among other properties.
; Returns     : (nothing - logs the error and sets @error = 1 as a side
;               effect)
; ============================================================================
Func _ComErrorHandler($oError)
	$g_sLastComError = $oError.windescription ; E1: for the result lines of the /notify process
	LogFile("COM error: 0x" & Hex($oError.number, 8) & " - " & $oError.windescription)
	SetError(1)
EndFunc   ;==>_ComErrorHandler

; ============================================================================
; _UnixTimeNow
; ----------------------------------------------------------------------------
; Description : Returns the current time as a Unix timestamp (seconds
;               since 1970-01-01 UTC), computed from the Win32
;               GetSystemTimeAsFileTime API. Used for token-expiry and
;               timeout calculations throughout the script, since it is
;               always UTC-based and therefore immune to local time zone /
;               daylight saving time changes.
; Parameters  : (none)
; Returns     : The current Unix time in whole seconds (Integer).
; ============================================================================
Func _UnixTimeNow()
	Local $tFileTime = DllStructCreate("uint64 val")
	DllCall("kernel32.dll", "none", "GetSystemTimeAsFileTime", "struct*", $tFileTime)
	Local $iFT = DllStructGetData($tFileTime, "val")
	Return Int($iFT / 10000000 - 11644473600)
EndFunc   ;==>_UnixTimeNow

; ============================================================================
; _SplitCRLF
; ----------------------------------------------------------------------------
; Description : Splits a text block into an array of lines on CRLF (@CRLF)
;               boundaries. Unlike _ExtractLines(), this consumes the
;               entire input in one call (no ByRef buffering across
;               calls) and also returns a final, non-CRLF-terminated
;               trailing fragment (if any) as the last array element.
;               Used by _FinishEhlo() to re-process the already-fully-
;               received EHLO response.
; Parameters  : $sText - Text to split.
; Returns     : An array of line strings (CRLF terminators removed).
; ============================================================================
Func _SplitCRLF($sText)
	Local $aLines[0]
	Local $sBuf = $sText
	While 1
		Local $iPos = StringInStr($sBuf, @CRLF)
		If $iPos = 0 Then
			If $sBuf <> "" Then _ArrayAdd($aLines, $sBuf)
			ExitLoop
		EndIf
		_ArrayAdd($aLines, StringLeft($sBuf, $iPos - 1))
		$sBuf = StringMid($sBuf, $iPos + 2)
	WEnd
	Return $aLines
EndFunc   ;==>_SplitCRLF

; ============================================================================
; _ExtractLines
; ----------------------------------------------------------------------------
; Description : Extracts complete CRLF-terminated lines out of $bNewData
;               (binary data just received from a socket/pipe), taking
;               into account any leftover partial line buffered from
;               previous calls in $sBuffer (ByRef, updated in place with
;               whatever remains after the last complete line). ASCII
;               decoding is safe here because the result only drives the
;               SMTP state machine before authentication (plain SMTP
;               control traffic) or, after authentication, the read-only
;               sniffing for the log (_SniffClientData()/
;               _SniffServerData()) - the data actually relayed after
;               authentication goes through binary-safe raw pass-through
;               in _PumpConnection() and never through this function. If more
;               than $MAX_LINE_BUFFER_BYTES accumulate without a CRLF ever
;               being found (a malfunctioning or malicious peer sending an
;               unterminated line), the buffered fragment is discarded and
;               SetError(1) is returned, so the caller can close the
;               connection instead of letting memory usage grow without
;               bound.
; Parameters  : $sBuffer  - ByRef: leftover bytes (as text) from previous
;               calls; updated in place to hold whatever is left after the
;               last complete line found this call.
;               $bNewData - Newly received binary data to append and scan.
; Returns     : An array of complete line strings (CRLF terminators
;               removed). May be an empty array if no complete line is
;               available yet. SetError(1, 0, $aLines) if the buffer
;               overflowed $MAX_LINE_BUFFER_BYTES (any complete lines
;               already found before the overflow are still returned).
; ============================================================================
Func _ExtractLines(ByRef $sBuffer, $bNewData)
	$sBuffer &= BinaryToString($bNewData, 1)
	Local $aLines[0]
	While 1
		Local $iPos = StringInStr($sBuffer, @CRLF)
		If $iPos = 0 Then ExitLoop
		_ArrayAdd($aLines, StringLeft($sBuffer, $iPos - 1))
		$sBuffer = StringMid($sBuffer, $iPos + 2)
	WEnd

	If StringLen($sBuffer) > $MAX_LINE_BUFFER_BYTES Then
		$sBuffer = ""
		Return SetError(1, 0, $aLines)
	EndIf

	Return $aLines
EndFunc   ;==>_ExtractLines

; ============================================================================
; _SniffClientData
; ----------------------------------------------------------------------------
; Description : Logs one line per e-mail relayed through an authenticated
;               connection (Sender/Recipient(s)/Subject), by lightly
;               inspecting the SAME client->upstream bytes that
;               _PumpConnection() already relays via raw pass-through -
;               entirely separate from, and with zero effect on, that
;               relay itself, which happens on its own regardless of
;               anything here. Once authenticated, the proxy no longer
;               needs to interpret SMTP commands for its own purposes
;               (unlike before sign-in - see _OnClientLine()), so this is
;               the one place that still looks at line-level content
;               post-authentication, purely to produce this log entry.
;               Watches for MAIL FROM / RCPT TO (always short, single
;               lines) and, once a DATA command starts a message body,
;               for a "Subject:" header near the top of it, then logs
;               everything collected once it sees the "." line that ends
;               the message (RFC 5321) - meaning the message was fully
;               relayed to the real server, not necessarily that the
;               real server has finished accepting/queuing it (see
;               _SniffServerData() for that other half).
;               Also logs level-8 timing for performance troubleshooting:
;               how long the client itself took, from sending "DATA" to
;               sending the final ".", to push the whole message to this
;               proxy. Because $STATE_AUTHENTICATED relays bytes to the
;               real server in real time as they arrive (not "receive the
;               whole message, then forward it"), this duration already
;               reflects the slower of the client's own upload speed and
;               whatever the real server's connection can absorb as fast
;               as it arrives - it does not mean the proxy itself sat
;               idle for that long doing nothing.
;
;               TWO INTERNAL MODES, for performance:
;               While still looking for a Subject header (SniffHeaderBytes
;               below $iSniffHeaderCap), every chunk is split into
;               complete lines via the general-purpose _ExtractLines()
;               and each is inspected individually, same as the pre-auth
;               command parsing this mirrors. Once that cap is reached (the
;               Subject is looked for within it), SniffFastMode switches on
;               and every SUBSEQUENT chunk instead gets a single, cheap
;               StringInStr() check for the "." terminator against a
;               small trailing buffer - it is never split into lines,
;               and _ExtractLines() is not called again for the rest of
;               this message. This two-mode split exists because the
;               original always-line-based version turned out to cost
;               many SECONDS on its own for a message with any sizeable
;               attachment: a 64KB chunk of (typically base64, ~76
;               characters per line) attachment content is on the order
;               of 800 individual lines, and _ExtractLines() was paying
;               that cost on EVERY chunk for the ENTIRE remainder of a
;               multi-megabyte message, not just the first one or two
;               chunks where a Subject header could actually still
;               appear. This was found and confirmed using a dedicated,
;               standalone diagnostic tool built specifically to isolate
;               which part of the proxy a slow send was actually spending
;               its time in - this function turned out to be the single
;               largest contributor for any message with a real
;               attachment, dwarfing every other candidate that had been
;               suspected before it (TCP-level effects, the receiving
;               loop's own structure, the relay-to-real-server leg).
;               Deliberately bounded and fails open either way: if the
;               sniff buffer itself were ever to overflow
;               $MAX_LINE_BUFFER_BYTES (see _ExtractLines()) while still
;               in the line-based mode, sniffing is simply switched off
;               for the rest of this connection (SniffActive = False)
;               rather than risking the connection over what is, after
;               all, only a logging feature - the surrounding relay is
;               entirely unaffected either way.
;               Command words seen after the login are added to the
;               connection's command trail, and the message content after
;               DATA is counted (bytes, time of the last chunk) for the
;               "MESSAGE INCOMPLETE" note of _ConnectionSummary() (J1); the "E-mail relayed" line itself,
;               the counter for the tray tooltip and the summary remembered
;               for a later server rejection come from _SniffLogRelayed().
; Parameters  : $oConn       - Connection dictionary (see
;               _AcceptNewConnections() for the Sniff* fields this uses).
;               $bClientData - The same raw bytes _PumpConnection() just
;               relayed to the upstream helper.
; Returns     : (nothing)
; ============================================================================
Func _SniffClientData($oConn, $bClientData)
	If Not $oConn.Item("SniffActive") Then Return

	; J1: count the message content and remember (as a timer only - cheap) when
	; the last part of it arrived (the chunk that contains the DATA command itself is not
	; counted - SniffInData is only set while its lines are processed below).
	If $oConn.Item("SniffInData") Then
		$oConn.Item("SniffDataBytes") = $oConn.Item("SniffDataBytes") + BinaryLen($bClientData)
		$oConn.Item("SniffDataLastTimer") = TimerInit() ; clock time is only worked out once, at close (_ClockTimeAgo())
	EndIf

	Local $iSniffHeaderCap = 16384

	; Fast path - see this function's own header comment for why this
	; exists. Only a single substring search per chunk, no line
	; splitting, and $oConn.Item("SniffBuf") only ever holds a handful of
	; trailing bytes here (just enough to catch a terminator split across
	; two chunks), never the whole remaining message.
	If $oConn.Item("SniffFastMode") Then
		Local $sTail = $oConn.Item("SniffBuf") & BinaryToString($bClientData, 1)
		Local $iDotPos = StringInStr($sTail, @CRLF & "." & @CRLF)
		If $iDotPos > 0 Then
			_SniffMessageEnd($oConn)
			; N1: whatever follows the end of the message in the same chunk
			; (typically "QUIT", or the next "MAIL FROM" when the client
			; sends several messages on one connection) goes through the
			; normal line-based handling, so it shows up in the command trail.
			Local $sRest = StringMid($sTail, $iDotPos + 5)
			If $sRest <> "" Then _SniffClientData($oConn, StringToBinary($sRest, 1))
		Else
			If StringLen($sTail) > 8 Then $sTail = StringRight($sTail, 5)
			$oConn.Item("SniffBuf") = $sTail
		EndIf
		Return
	EndIf

	; Line-based mode - used before authentication commands are done, and
	; for the header portion of a message's DATA content (until
	; $iSniffHeaderCap bytes have been read - the Subject is looked for within them - at which point
	; SniffFastMode switches on below and every chunk from then on takes
	; the cheap path above instead).
	Local $sBuf = $oConn.Item("SniffBuf")
	Local $aLines = _ExtractLines($sBuf, $bClientData)
	Local $bOverflow = @error
	$oConn.Item("SniffBuf") = $sBuf

	If $bOverflow Then
		$oConn.Item("SniffActive") = False
		$oConn.Item("SniffBuf") = ""
		Return
	EndIf

	Local $i = 0
	For $i = 0 To UBound($aLines) - 1
		Local $sLine = $aLines[$i]
		Local $sLower = StringLower($sLine)

		If Not $oConn.Item("SniffInData") Then
			; Last command + short trail for the log (see _ConnectionSummary(),
			; _SniffServerData()); only the command word, never any arguments.
			$oConn.Item("SniffLastCmd") = _ClientCmdLabel($sLine, $STATE_AUTHENTICATED)
			_TrailAdd($oConn, $oConn.Item("SniffLastCmd"))
			If StringLeft($sLower, 10) = "mail from:" Then
				$oConn.Item("SniffMailFrom") = _SniffExtractAddress($sLine)
			ElseIf StringLeft($sLower, 8) = "rcpt to:" Then
				Local $sAddr = _SniffExtractAddress($sLine)
				If $oConn.Item("SniffRcptTo") = "" Then
					$oConn.Item("SniffRcptTo") = $sAddr
				Else
					$oConn.Item("SniffRcptTo") &= ", " & $sAddr
				EndIf
			ElseIf $sLower = "data" Then
				$oConn.Item("SniffInData") = True
				$oConn.Item("SniffSubject") = ""
				$oConn.Item("SniffHeaderBytes") = 0
				$oConn.Item("SniffDataBytes") = 0      ; J1
				$oConn.Item("SniffDataLastTimer") = 0
				$oConn.Item("SniffData354Seen") = False ; N1
				; Level 8 timing starts here - see _SniffServerData()'s
				; own header comment for the other half of this (how long
				; the server then takes to acknowledge it).
				$oConn.Item("SniffDataStartedAt") = TimerInit()
			EndIf
		Else
			If $sLine = "." Then
				; N1: same end handling as the fast path. It also switches the
				; fast mode off again - before v54 this branch left it on when
				; the 16 KB cap was crossed in the same chunk as the ".", so the
				; NEXT message on the same connection was sniffed in fast mode
				; from its MAIL FROM on (sender/recipients/subject missing).
				; SniffBuf is NOT cleared here: it holds the (possibly partial)
				; next line of this very chunk.
				Local $sKeepBuf = $oConn.Item("SniffBuf")
				_SniffMessageEnd($oConn)
				$oConn.Item("SniffBuf") = $sKeepBuf
			ElseIf $oConn.Item("SniffHeaderBytes") < $iSniffHeaderCap Then
				$oConn.Item("SniffHeaderBytes") = $oConn.Item("SniffHeaderBytes") + StringLen($sLine) + 2
				If StringLeft($sLower, 8) = "subject:" Then
					; Decode RFC 2047 "=?charset?B/Q?...?=" encoded-word(s)
					; (see _DecodeMimeHeader()'s own header comment) so a
					; non-ASCII subject shows up readable in the log
					; instead of as raw encoded gibberish - left as-is if
					; the subject was already plain ASCII to begin with.
					$oConn.Item("SniffSubject") = _DecodeMimeHeader(StringStripWS(StringMid($sLine, 9), 3))
				EndIf
				; Just crossed the cap while processing this chunk's
				; lines (finding the Subject alone does not switch) -
				; the remaining, already-extracted lines in THIS chunk
				; still get checked normally below (cheap - extraction
				; already happened), but every FUTURE chunk will use the
				; fast path above instead of calling _ExtractLines()
				; again.
				If $oConn.Item("SniffHeaderBytes") >= $iSniffHeaderCap Then $oConn.Item("SniffFastMode") = True
			EndIf
		EndIf
	Next

	; N1 (bug fix v54): the fast path looks for CRLF "." CRLF across chunk
	; boundaries using the last few bytes kept in SniffBuf. But when the fast
	; mode has JUST been switched on in this chunk, SniffBuf only holds the
	; unfinished last line WITHOUT the line break before it (_ExtractLines()
	; removes the CRLFs of complete lines). If this chunk ended exactly at a
	; line end and the client then sent ".<CRLF>" as a separate write - which
	; many clients do - the next chunk was just ".<CRLF>" and the terminator
	; was never found: no "E-mail relayed" line, no counter, and a wrong
	; "MESSAGE INCOMPLETE" note on close (seen 24.10.2026 with a 41 KB mail).
	; The unfinished line in SniffBuf always starts right after a CRLF, so
	; putting that CRLF back in front is always correct.
	If $oConn.Item("SniffInData") And $oConn.Item("SniffFastMode") Then $oConn.Item("SniffBuf") = @CRLF & $oConn.Item("SniffBuf")
EndFunc   ;==>_SniffClientData

; ============================================================================
; _SniffMessageEnd
; ----------------------------------------------------------------------------
; Description : N1: everything that happens when the end of a message has
;               been recognised - from the client's "." line
;               (_SniffClientData(), line-based or fast path) or, as a
;               fallback, from the real server's reply to the message
;               (_SniffServerData()): level-8 timing, waiting for the
;               server's acknowledgement, the "E-mail relayed" line and
;               counter (_SniffLogRelayed()), and resetting the per-message
;               sniffing state (also the fast mode and SniffBuf).
; Parameters  : $oConn - Connection dictionary.
; Returns     : (nothing)
; ============================================================================
Func _SniffMessageEnd($oConn)
	$oConn.Item("SniffClientSendDoneAt") = TimerInit()
	LogFile("Timing: client finished sending the message body " & _
			_FormatDurationMs(Round(TimerDiff($oConn.Item("SniffDataStartedAt")))) & " after starting DATA.", 8)
	$oConn.Item("SniffAwaitingDataAck") = True
	_SniffLogRelayed($oConn)
	$oConn.Item("SniffInData") = False
	$oConn.Item("SniffFastMode") = False
	$oConn.Item("SniffData354Seen") = False
	$oConn.Item("SniffMailFrom") = ""
	$oConn.Item("SniffRcptTo") = ""
	$oConn.Item("SniffSubject") = ""
	$oConn.Item("SniffBuf") = ""
EndFunc   ;==>_SniffMessageEnd

; ============================================================================
; _SniffServerData
; ----------------------------------------------------------------------------
; Description : Reads the real server's replies on a signed-in connection:
;               logs every 4xx/5xx error (for the reply to the end of a
;               message as "did NOT accept the e-mail" with sender,
;               recipients and subject), keeps the last reply for the
;               "Connection closed" summary, updates the tooltip counters,
;               and is the other half of _SniffClientData()'s level-8
;               DATA-phase timing: once the client has finished sending a message
;               (SniffAwaitingDataAck set True there), watches the
;               upstream helper's own raw pass-through bytes - the SAME
;               ones _PumpConnection() already relays back to the client
;               unmodified, entirely unaffected by anything here, exactly
;               like _SniffClientData() - for the real server's own
;               response line, and logs how long that took to arrive
;               after the client was done. This isolates the real
;               server's own network round trip and processing/queuing
;               time (e.g. anti-spam/anti-malware scanning) from how long
;               the client itself took to upload the message
;               (_SniffClientData()'s own timing) - two very different
;               things that a single "the whole send felt slow" report
;               cannot distinguish between on its own.
;               A response can be multi-line ("250-..." continuation
;               lines followed by a final "250 ..." line) - only a line
;               whose 4th character is not "-" actually completes it;
;               anything before that is skipped rather than logged as if
;               it were the answer.
;               Bounded and fails open the same way _SniffClientData()
;               does: on a sniff-buffer overflow, this simply stops
;               waiting (SniffAwaitingDataAck = False) without logging
;               anything for that one message, rather than risking the
;               connection - the actual relay back to the client, done by
;               _PumpConnection() itself before this ever runs, is
;               unaffected either way.
; Parameters  : $oConn       - Connection dictionary (see
;               _AcceptNewConnections() for the Sniff* fields this uses).
;               $bServerData - The same raw bytes _PumpConnection() just
;               relayed back to the client.
; Returns     : (nothing)
; ============================================================================
Func _SniffServerData($oConn, $bServerData)
	Local $sBuf = $oConn.Item("SniffServerBuf")
	Local $aLines = _ExtractLines($sBuf, $bServerData)
	Local $bOverflow = @error
	$oConn.Item("SniffServerBuf") = $sBuf

	If $bOverflow Then
		$oConn.Item("SniffAwaitingDataAck") = False
		$oConn.Item("SniffServerBuf") = ""
		Return
	EndIf

	Local $i = 0
	For $i = 0 To UBound($aLines) - 1
		Local $sLine = $aLines[$i]
		If StringLen($sLine) < 4 Then ContinueLoop
		$oConn.Item("LastServerLine") = StringLeft($sLine, 100)

		Local $bFinalLine = (StringMid($sLine, 4, 1) <> "-")
		Local $sFirst = StringLeft($sLine, 1)
		Local $bIsError = (StringIsDigit(StringLeft($sLine, 3)) And ($sFirst = "4" Or $sFirst = "5"))

		; N1: the real server is the authority on where a message ends. While
		; the client is in the DATA phase, the server says nothing until it
		; has seen the end of the message - so ANY final reply after its 354
		; means the message is complete (250) or refused (4xx/5xx), even if
		; the client-side sniffing missed the "." line for whatever reason.
		; Replies BEFORE the 354 are ignored here: with PIPELINING the client
		; sends MAIL, RCPT and DATA at once, so the replies to MAIL/RCPT (250,
		; or an error for one rejected recipient) arrive while SniffInData is
		; already set - they say nothing about the end of the message.
		If $bFinalLine And $oConn.Item("SniffInData") Then
			If Not $oConn.Item("SniffData354Seen") Then
				If StringLeft($sLine, 3) = "354" Then $oConn.Item("SniffData354Seen") = True
			Else
				LogFile("Note: the end of the message was recognised from the real server's reply (" & StringLeft($sLine, 3) & _
						"), not from the client's data - the e-mail is logged anyway.", 6)
				_SniffMessageEnd($oConn)
			EndIf
		EndIf

		; Every error reply (4xx/5xx) of the real server is written to the
		; log - at any log level - together with what it is the answer to.
		; The reply to the end of a message is the one that says whether
		; the real server accepted it at all (the "E-mail relayed" line is
		; written when the CLIENT is done, before the server has answered).
		If $bIsError Then
			If $oConn.Item("SniffAwaitingDataAck") Then
				If _ShortenServerReply($sLine) <> $sLine Then LogFile("Full server reply: " & $sLine, 6) ; S3
				LogFile("Warning: the real server did NOT accept the e-mail (" & $oConn.Item("SniffLastMail") & "): " & StringLeft(_ShortenServerReply($sLine), 300) & _
						StringReplace(_SendAsHint($sLine, "", $oConn.Item("Account").Item("Username")), @CRLF, " "))
				_StatsCountRejected() ; E8
				_StatsNoteError("mail refused: " & StringLeft($sLine, 40))
				_NotifyEvent("refused", __ConnAccountName($oConn), "The mail server did not accept an e-mail (" & $oConn.Item("SniffLastMail") & _
						"): " & StringLeft(_ShortenServerReply($sLine), 250)) ; E1
			Else
				LogFile("Warning: the real server answered with an error (after the client command " & $oConn.Item("SniffLastCmd") & "): " & StringLeft($sLine, 300))
				_StatsNoteError("server: " & StringLeft($sLine, 40)) ; E8
				_NotifyCountError(__ConnAccountName($oConn), StringLeft($sLine, 150)) ; E1
			EndIf
		EndIf

		If $bFinalLine And $oConn.Item("SniffAwaitingDataAck") Then
			LogFile("Timing: real server acknowledged the message (" & StringLeft($sLine, 3) & ") " & _
					_FormatDurationMs(Round(TimerDiff($oConn.Item("SniffClientSendDoneAt")))) & _
					" after the client finished sending it.", 8)
			$oConn.Item("SniffAwaitingDataAck") = False
			If Not $bIsError Then
				; E1: an accepted e-mail ends the problems "refused" and "errors"
				_NotifyResolved("refused", __ConnAccountName($oConn), "The mail server accepts e-mail from this account again.")
				_NotifyResolved("errors", __ConnAccountName($oConn), "E-mail from this account is being accepted again.")
			EndIf
		EndIf
	Next
EndFunc   ;==>_SniffServerData

; ============================================================================
; _SniffExtractAddress
; ----------------------------------------------------------------------------
; Description : Pulls the e-mail address out of a "MAIL FROM:<addr>" or
;               "RCPT TO:<addr> SIZE=..."-style SMTP command line, for
;               _SniffClientData(). Handles the angle-bracket form (used
;               by every real mail client) and falls back to everything
;               after the colon, up to the next space, for a
;               non-conformant client that omits the brackets.
; Parameters  : $sLine - The full "MAIL FROM:..."/"RCPT TO:..." line.
; Returns     : The extracted address, or "" if none could be found.
; ============================================================================
Func _SniffExtractAddress($sLine)
	Local $aMatch = StringRegExp($sLine, "<([^>]*)>", 1)
	If Not @error Then Return $aMatch[0]

	Local $iColon = StringInStr($sLine, ":")
	If $iColon = 0 Then Return ""
	Local $sRest = StringStripWS(StringMid($sLine, $iColon + 1), 3)
	Local $iSpace = StringInStr($sRest, " ")
	If $iSpace > 0 Then $sRest = StringLeft($sRest, $iSpace - 1)
	Return $sRest
EndFunc   ;==>_SniffExtractAddress

; ============================================================================
; _Base64Encode
; ----------------------------------------------------------------------------
; Description : Base64-encodes binary data using the Win32 CryptBinaryToStringW
;               API (CRYPT_STRING_BASE64, no line breaks). Calls the API
;               twice, once to determine the required output buffer size
;               and once to actually fill it - the standard usage pattern
;               for this API.
; Parameters  : $bData - Binary data to encode.
; Returns     : The base64-encoded string, or "" for empty input.
;               On a Win32 API failure: SetError(1 or 2, 0, "").
; ============================================================================
Func _Base64Encode($bData)
	Local $iLen = BinaryLen($bData)
	If $iLen = 0 Then Return ""
	Local $tData = DllStructCreate("byte val[" & $iLen & "]")
	DllStructSetData($tData, "val", $bData)

	Local $aRet = DllCall("crypt32.dll", "bool", "CryptBinaryToStringW", "struct*", $tData, "dword", $iLen, _
			"dword", BitOR(0x1, 0x40000000), "ptr", 0, "dword*", 0)
	If @error Or Not $aRet[0] Then Return SetError(1, 0, "")
	Local $iOutLen = $aRet[5]

	Local $tOut = DllStructCreate("wchar val[" & ($iOutLen + 1) & "]")
	$aRet = DllCall("crypt32.dll", "bool", "CryptBinaryToStringW", "struct*", $tData, "dword", $iLen, _
			"dword", BitOR(0x1, 0x40000000), "struct*", $tOut, "dword*", $iOutLen)
	If @error Or Not $aRet[0] Then Return SetError(2, 0, "")

	Return DllStructGetData($tOut, "val")
EndFunc   ;==>_Base64Encode

; ============================================================================
; _Base64EncodeMime
; ----------------------------------------------------------------------------
; Description : Base64-encodes binary data for use as a MIME body part
;               (e.g. an e-mail attachment): gets the flat, single-line
;               encoding from the already-proven _Base64Encode() (used
;               throughout this script for DPAPI blobs and the XOAUTH2
;               string), then inserts a CRLF every 76 characters itself
;               (RFC 2045's maximum line length for MIME content) via a
;               plain StringMid() loop - deliberately not relying on
;               CryptBinaryToStringW's own automatic line-insertion (as
;               an earlier version of this function did, by omitting the
;               CRYPT_STRING_NOCRLF flag), to remove that as a variable
;               while tracking down why generated file attachments were
;               coming through empty/truncated.
; Parameters  : $bData - Binary data to encode.
; Returns     : The base64-encoded, CRLF-wrapped string, or "" for empty
;               input.
; ============================================================================
Func _Base64EncodeMime($bData)
	Local $sFlat = _Base64Encode($bData)
	If $sFlat = "" Then Return ""

	Local $sResult = ""
	Local $iLen = StringLen($sFlat)
	Local $i = 1
	While $i <= $iLen
		$sResult &= StringMid($sFlat, $i, 76) & @CRLF
		$i += 76
	WEnd
	Return $sResult
EndFunc   ;==>_Base64EncodeMime

; ============================================================================
; _Base64Decode
; ----------------------------------------------------------------------------
; Description : Decodes a base64 string back to binary data, using the
;               Win32 CryptStringToBinaryW API (CRYPT_STRING_BASE64). Calls
;               the API twice (size query, then fill), matching the
;               standard usage pattern for this API.
; Parameters  : $sB64 - Base64-encoded string to decode.
; Returns     : The decoded binary data, or an empty Binary("") for empty
;               input.
;               On a Win32 API failure: SetError(1 or 2, 0, Binary("")).
; ============================================================================
Func _Base64Decode($sB64)
	If $sB64 = "" Then Return Binary("")
	Local $aRet = DllCall("crypt32.dll", "bool", "CryptStringToBinaryW", "wstr", $sB64, "dword", 0, _
			"dword", 0x1, "ptr", 0, "dword*", 0, "ptr", 0, "ptr", 0)
	If @error Or Not $aRet[0] Then Return SetError(1, 0, Binary(""))
	Local $iOutLen = $aRet[5]
	If $iOutLen = 0 Then Return Binary("")

	Local $tOut = DllStructCreate("byte val[" & $iOutLen & "]")
	$aRet = DllCall("crypt32.dll", "bool", "CryptStringToBinaryW", "wstr", $sB64, "dword", 0, _
			"dword", 0x1, "struct*", $tOut, "dword*", $iOutLen, "ptr", 0, "ptr", 0)
	If @error Or Not $aRet[0] Then Return SetError(2, 0, Binary(""))

	Return DllStructGetData($tOut, "val")
EndFunc   ;==>_Base64Decode

; ============================================================================
; _Base64UrlEncode
; ----------------------------------------------------------------------------
; Description : Base64url-encodes binary data per RFC 4648 section 5
;               (used for the OAuth2 "state" value and for PKCE
;               code_verifier/code_challenge): takes the standard base64
;               encoding from _Base64Encode() and replaces "+" with "-",
;               "/" with "_", and strips "=" padding.
; Parameters  : $bData - Binary data to encode.
; Returns     : The base64url-encoded string.
; ============================================================================
Func _Base64UrlEncode($bData)
	Local $s = _Base64Encode($bData)
	$s = StringReplace($s, "+", "-")
	$s = StringReplace($s, "/", "_")
	$s = StringReplace($s, "=", "")
	Return $s
EndFunc   ;==>_Base64UrlEncode

; ============================================================================
; _DPAPI_Protect
; ----------------------------------------------------------------------------
; Description : Encrypts a plain-text secret using the Windows Data
;               Protection API (DPAPI, CryptProtectData), scoped to the
;               current Windows user account and machine (comparable to
;               how browsers protect saved passwords). The result is
;               base64-encoded so it can be stored as a plain INI value.
;               Used for the OAuth2 refresh/access tokens, the client
;               secret and the local SMTP password before writing them to
;               the INI file. Called with CRYPTPROTECT_UI_FORBIDDEN, so
;               Windows can never show a dialog that would stop this
;               single-threaded, unattended program.
; Parameters  : $sPlainText - The secret to encrypt (UTF-8 text).
; Returns     : The base64-encoded, DPAPI-protected blob, or "" for empty
;               input.
;               On a Win32 API failure: SetError(1, 0, "").
; ============================================================================
Func _DPAPI_Protect($sPlainText)
	If $sPlainText = "" Then Return ""
	Local $bData = StringToBinary($sPlainText, 4)
	Local $iLen = BinaryLen($bData)
	Local $tIn = DllStructCreate("byte val[" & $iLen & "]")
	DllStructSetData($tIn, "val", $bData)

	Local $tInBlob = DllStructCreate("dword cbData;ptr pbData")
	DllStructSetData($tInBlob, "cbData", $iLen)
	DllStructSetData($tInBlob, "pbData", DllStructGetPtr($tIn))

	Local $tOutBlob = DllStructCreate("dword cbData;ptr pbData")

	Local $aRet = DllCall("crypt32.dll", "bool", "CryptProtectData", "struct*", $tInBlob, "wstr", $g_sAppName, "ptr", 0, "ptr", 0, "ptr", 0, "dword", $CRYPTPROTECT_UI_FORBIDDEN, "struct*", $tOutBlob)
	If @error Or Not $aRet[0] Then Return SetError(1, 0, "")

	Local $iOutLen = DllStructGetData($tOutBlob, "cbData")
	Local $pOut = DllStructGetData($tOutBlob, "pbData")
	Local $tOutData = DllStructCreate("byte val[" & $iOutLen & "]", $pOut)
	Local $bOut = DllStructGetData($tOutData, "val")

	DllCall("kernel32.dll", "ptr", "LocalFree", "ptr", $pOut)

	Return _Base64Encode($bOut)
EndFunc   ;==>_DPAPI_Protect

; ============================================================================
; _DPAPI_Unprotect
; ----------------------------------------------------------------------------
; Description : Reverses _DPAPI_Protect(): decrypts a base64-encoded DPAPI
;               blob back to its original plain text, using
;               CryptUnprotectData. Only succeeds if run under the same
;               Windows user account (and typically the same machine) that
;               originally encrypted the data.
; Parameters  : $sBase64 - Base64-encoded, DPAPI-protected blob (as
;               produced by _DPAPI_Protect()).
;               $sWhat   - What the value is, for the log (e.g. "local SMTP
;               password of info@example.com").
;               E4: if decryption fails, a clear error is written to the log
;               (once per value and session) - otherwise a copied INI file
;               only shows up later as misleading follow-up errors such as
;               "no local SMTP password is configured".
; Returns     : The decrypted plain-text string, or "" for empty input.
;               On a Win32 API failure (e.g. wrong user account):
;               SetError(2, 0, "").
; ============================================================================
Func _DPAPI_Unprotect($sBase64, $sWhat = "a stored value")
	If $sBase64 = "" Then Return ""
	Local $bData = _Base64Decode($sBase64)
	Local $iLen = BinaryLen($bData)
	If $iLen = 0 Then Return ""

	Local $tIn = DllStructCreate("byte val[" & $iLen & "]")
	DllStructSetData($tIn, "val", $bData)

	Local $tInBlob = DllStructCreate("dword cbData;ptr pbData")
	DllStructSetData($tInBlob, "cbData", $iLen)
	DllStructSetData($tInBlob, "pbData", DllStructGetPtr($tIn))

	Local $tOutBlob = DllStructCreate("dword cbData;ptr pbData")

	Local $aRet = DllCall("crypt32.dll", "bool", "CryptUnprotectData", "struct*", $tInBlob, "ptr", 0, "ptr", 0, _
			"ptr", 0, "ptr", 0, "dword", $CRYPTPROTECT_UI_FORBIDDEN, "struct*", $tOutBlob)
	If @error Or Not $aRet[0] Then
		Local $iDpapiErr = _WinAPI_GetLastError()
		If Not $g_oDpapiWarned.Exists($sWhat) Then
			$g_oDpapiWarned.Item($sWhat) = True
			LogFile("Error: could not decrypt the " & $sWhat & " (DPAPI, Windows error " & $iDpapiErr & "). Stored secrets " & _
					"can only be read by the Windows user on the PC that saved them - this happens when the INI file was " & _
					"copied from another PC or user account, or the user profile was reset. Enter the value again via " & _
					"Settings -> Edit (local password, client secret) or sign in again via the tray menu (tokens).")
		EndIf
		Return SetError(2, 0, "")
	EndIf

	Local $iOutLen = DllStructGetData($tOutBlob, "cbData")
	Local $pOut = DllStructGetData($tOutBlob, "pbData")
	Local $tOutData = DllStructCreate("byte val[" & $iOutLen & "]", $pOut)
	Local $bOut = DllStructGetData($tOutData, "val")

	DllCall("kernel32.dll", "ptr", "LocalFree", "ptr", $pOut)

	Return BinaryToString($bOut, 4)
EndFunc   ;==>_DPAPI_Unprotect

; ============================================================================
; _URLEncode
; ----------------------------------------------------------------------------
; Description : Percent-encodes a UTF-8 string for safe use in a URL query
;               string or an application/x-www-form-urlencoded request
;               body, leaving only RFC 3986 "unreserved" characters
;               (letters, digits, "-", ".", "_", "~") unescaped.
; Parameters  : $sText - Text to encode.
; Returns     : The percent-encoded string.
; ============================================================================
Func _URLEncode($sText)
	Local $bBytes = StringToBinary($sText, 4)
	Local $iLen = BinaryLen($bBytes)
	Local $sResult = ""
	Local $sUnreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	Local $i = 0
	For $i = 1 To $iLen
		Local $iByte = Number(BinaryMid($bBytes, $i, 1))
		Local $sChar = Chr($iByte)
		If StringInStr($sUnreserved, $sChar, 1) > 0 Then
			$sResult &= $sChar
		Else
			$sResult &= "%" & Hex($iByte, 2)
		EndIf
	Next
	Return $sResult
EndFunc   ;==>_URLEncode

; ============================================================================
; _URLDecode
; ----------------------------------------------------------------------------
; Description : Decodes a percent-encoded (and "+"-as-space) URL-encoded
;               string back to plain text. Used to decode the
;               authorization code received in the OAuth2 redirect's query
;               string, and its "error"/"error_description" parameters.
;               Builds the raw decoded byte sequence as a hex string first,
;               then converts the complete sequence to a proper Unicode
;               string in a single step at the end via BinaryToString(...,
;               4) (UTF-8) - decoding each byte straight into a String via
;               Chr() one at a time (the previous approach) mishandles any
;               multi-byte UTF-8 character (e.g. a non-ASCII character in
;               a localised "error_description"), since each of its bytes
;               gets turned into its own separate, wrong character instead
;               of being reassembled together; it would also have been
;               vulnerable to Windows' ANSI codepage not mapping every
;               byte value 1:1 (notably 0x80-0x9F under Windows-1252) had
;               Chr()/StringToBinary() been used to rebuild the byte
;               sequence instead - working directly in hex sidesteps any
;               codepage involvement entirely.
; Parameters  : $sText - Percent-encoded text to decode.
; Returns     : The decoded string.
; ============================================================================
Func _URLDecode($sText)
	Local $sHex = ""
	Local $i = 1
	Local $iLen = StringLen($sText)
	While $i <= $iLen
		Local $c = StringMid($sText, $i, 1)
		If $c = "%" And $i + 2 <= $iLen Then
			$sHex &= StringMid($sText, $i + 1, 2)
			$i += 3
		ElseIf $c = "+" Then
			$sHex &= Hex(Asc(" "), 2)
			$i += 1
		Else
			$sHex &= Hex(Asc($c), 2)
			$i += 1
		EndIf
	WEnd
	If $sHex = "" Then Return ""
	Return BinaryToString(Binary("0x" & $sHex), 4)
EndFunc   ;==>_URLDecode

; ============================================================================
; _BuildFormBody
; ----------------------------------------------------------------------------
; Description : Builds an application/x-www-form-urlencoded request body
;               from a list of key/value pairs, URL-encoding each value.
;               Pairs whose value is an empty string are skipped entirely
;               (used to omit optional OAuth2 parameters such as
;               client_secret or code_verifier when they are not
;               applicable).
; Parameters  : $aParams - Two-dimensional array with one row per
;               parameter: [n][0] = key, [n][1] = value.
; Returns     : The encoded body string, e.g. "key1=value1&key2=value2".
; ============================================================================
Func _BuildFormBody($aParams)
	Local $sBody = ""
	Local $i = 0
	For $i = 0 To UBound($aParams) - 1
		If $aParams[$i][1] <> "" Then
			If $sBody <> "" Then $sBody &= "&"
			$sBody &= $aParams[$i][0] & "=" & _URLEncode($aParams[$i][1])
		EndIf
	Next
	Return $sBody
EndFunc   ;==>_BuildFormBody

; ============================================================================
; _HttpPostForm
; ----------------------------------------------------------------------------
; Description : Performs a synchronous HTTPS POST request with an
;               application/x-www-form-urlencoded body, using the WinHTTP
;               COM object (which handles TLS natively). Used for all
;               OAuth2 token-endpoint calls (authorization_code and
;               refresh_token grants). All four WinHTTP timeout phases
;               (resolve/connect/send/receive) use the same "HttpTimeoutMs"
;               INI setting (default 15000 - see _LoadGeneralSettings()) -
;               one combined setting rather than four separate ones, since
;               this call only ever targets one well-known, fast endpoint
;               (the account's own OAuth2 token URL) and does not need
;               each phase tuned independently.
; Parameters  : $sUrl        - Target URL (the OAuth2 token endpoint).
;               $sBody       - Pre-encoded request body (see
;               _BuildFormBody()).
;               $iStatusCode - ByRef: receives the HTTP status code of the
;               response (0 if the request could not be sent at all).
; Returns     : The response body text (typically JSON). Returns "" if the
;               WinHTTP object could not be created or the request failed
;               (check $iStatusCode / @error for details).
; ============================================================================
Func _HttpPostForm($sUrl, $sBody, ByRef $iStatusCode)
	$iStatusCode = 0
	Local $oHttp = ObjCreate("WinHttp.WinHttpRequest.5.1")
	If Not IsObj($oHttp) Then Return ""

	$oHttp.Open("POST", $sUrl, False)
	$oHttp.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")
	$oHttp.SetRequestHeader("User-Agent", $g_sAppName)
	$oHttp.SetTimeouts($g_iHttpTimeoutMs, $g_iHttpTimeoutMs, $g_iHttpTimeoutMs, $g_iHttpTimeoutMs)
	Local $hOpTimer = TimerInit()
	$oHttp.Send($sBody)
	Local $iSendErr = @error
	_OpEnd($hOpTimer, "HTTPS request to", $sUrl)

	If $iSendErr Then Return ""

	$iStatusCode = $oHttp.Status
	Return $oHttp.ResponseText
EndFunc   ;==>_HttpPostForm

; ============================================================================
; _JsonGetString
; ----------------------------------------------------------------------------
; Description : Extracts a single string value for a given key from a flat
;               JSON object, using a regular expression (a full JSON
;               parser is not needed since only the well-known,
;               flat-shaped OAuth2 token-endpoint responses are parsed).
;               Un-escapes the result via _JsonUnescape().
; Parameters  : $sJson - JSON text to search (typically an OAuth2 token
;               response body).
;               $sKey  - Name of the key to look for (must be a literal
;               key name, not user-controlled, since it is inserted
;               directly into the regular expression).
; Returns     : The string value for $sKey, or "" if the key was not
;               found.
; ============================================================================
Func _JsonGetString($sJson, $sKey)
	Local $aMatch = StringRegExp($sJson, '"' & $sKey & '"\s*:\s*"((?:[^"\\]|\\.)*)"', 1)
	If @error Then Return ""
	Return _JsonUnescape($aMatch[0])
EndFunc   ;==>_JsonGetString

; ============================================================================
; _JsonUnescape
; ----------------------------------------------------------------------------
; Description : Un-escapes a JSON string's content (\", \\, \/, \n, \r, \t)
;               in a single left-to-right pass. Three sequential
;               StringReplace() calls (the previous approach) has a subtle
;               ordering bug: unescaping "\\" before "\/" can turn an
;               already-decoded "\\" + a literal "/" into a NEWLY-formed
;               two-character "\/" sequence, which the next replacement
;               pass then wrongly treats as an original escape sequence
;               and strips the backslash from - e.g. the raw sequence
;               "\\/" (escaped backslash, then a literal slash) would
;               incorrectly come out as just "/" instead of "\/". Walking
;               the string once, byte by byte, and immediately advancing
;               past each handled escape pair avoids this entirely, since
;               nothing already emitted into the result is ever
;               re-scanned. Unicode escapes (\uXXXX) are not supported
;               (not needed for the OAuth2 fields this script reads) - an
;               unrecognised escape is passed through unchanged (backslash
;               kept) rather than silently dropped, so unsupported input
;               is preserved as-is instead of corrupted.
; Parameters  : $sVal - Raw (still escaped) JSON string content, without
;               the surrounding quotes.
; Returns     : The un-escaped text.
; ============================================================================
Func _JsonUnescape($sVal)
	Local $sResult = ""
	Local $iLen = StringLen($sVal)
	Local $i = 1
	While $i <= $iLen
		Local $c = StringMid($sVal, $i, 1)
		If $c = "\" And $i < $iLen Then
			Local $cNext = StringMid($sVal, $i + 1, 1)
			Switch $cNext
				Case '"'
					$sResult &= '"'
				Case "\"
					$sResult &= "\"
				Case "/"
					$sResult &= "/"
				Case "n"
					$sResult &= @LF
				Case "r"
					$sResult &= @CR
				Case "t"
					$sResult &= @TAB
				Case Else
					; Unsupported escape (e.g. \uXXXX) - keep both
					; characters as-is rather than dropping the backslash.
					$sResult &= $c & $cNext
			EndSwitch
			$i += 2
		Else
			$sResult &= $c
			$i += 1
		EndIf
	WEnd
	Return $sResult
EndFunc   ;==>_JsonUnescape

; ============================================================================
; _JsonGetNumber
; ----------------------------------------------------------------------------
; Description : Extracts a single numeric value for a given key from a
;               flat JSON object, using a regular expression (see
;               _JsonGetString() for why a full parser is not used here).
; Parameters  : $sJson - JSON text to search.
;               $sKey  - Name of the key to look for (literal key name
;               only, see _JsonGetString()).
; Returns     : The numeric value for $sKey, or -1 if the key was not
;               found.
; ============================================================================
Func _JsonGetNumber($sJson, $sKey)
	Local $aMatch = StringRegExp($sJson, '"' & $sKey & '"\s*:\s*(-?[0-9]+(?:\.[0-9]+)?)', 1)
	If @error Then Return -1
	Return Number($aMatch[0])
EndFunc   ;==>_JsonGetNumber

; ============================================================================
; _GenerateRandomBytes
; ----------------------------------------------------------------------------
; Description : Generates $iSize cryptographically random bytes via
;               _Crypt_GenRandom() (part of AutoIt's own Crypt.au3 UDF,
;               already included). _Crypt_GenRandom()'s actual signature
;               is _Crypt_GenRandom($pBuffer, $iSize) - it FILLS a
;               caller-supplied buffer, it does not itself return one.
;               An earlier version of _RandomToken() (and
;               _PKCE_NewVerifier()) called it the wrong way round -
;               _Crypt_GenRandom($iBytes, 0) - passing the byte COUNT
;               where a buffer POINTER was expected, and 0 (meaning
;               "generate zero bytes") as the size; AutoIt would have
;               coerced that stray integer into some pointer-shaped
;               value, and the call would have quietly "succeeded" at
;               writing nothing anywhere meaningful, leaving both
;               functions returning something not actually random at all.
;               This single, correctly-implemented function now backs
;               both of those AND the random file attachment content
;               (_BuildAttachmentPart()) - a native Win32 CryptoAPI call
;               filling the whole buffer in one go, not an AutoIt-level
;               per-byte loop, so this stays fast even for a multi-
;               megabyte attachment.
; Parameters  : $iSize - Number of random bytes to generate.
; Returns     : The random bytes, as Binary. On failure: SetError(1, 0,
;               Binary("")).
; ============================================================================
Func _GenerateRandomBytes($iSize)
	Local $tBuf = DllStructCreate("byte[" & $iSize & "]")
	_Crypt_Startup()
	Local $bOk = _Crypt_GenRandom($tBuf, $iSize)
	_Crypt_Shutdown()
	If Not $bOk Then Return SetError(1, 0, Binary(""))
	Return DllStructGetData($tBuf, 1)
EndFunc   ;==>_GenerateRandomBytes

; ============================================================================
; _RandomToken
; ----------------------------------------------------------------------------
; Description : Generates a cryptographically random, base64url-encoded
;               token, via _GenerateRandomBytes(). Used for the OAuth2
;               "state" CSRF-protection value and for MIME part
;               boundaries (see _BuildTestEmailContent()).
; Parameters  : $iBytes - Number of random bytes to generate (the encoded
;               string will be somewhat longer).
; Returns     : The base64url-encoded random token.
; ============================================================================
Func _RandomToken($iBytes)
	Return _Base64UrlEncode(_GenerateRandomBytes($iBytes))
EndFunc   ;==>_RandomToken

; ============================================================================
; _PKCE_NewVerifier
; ----------------------------------------------------------------------------
; Description : Generates a new PKCE (RFC 7636) code_verifier: 64
;               cryptographically random bytes (via _GenerateRandomBytes()
;               - see its header comment for a past bug this fixed here
;               too), base64url-encoded.
; Parameters  : (none)
; Returns     : The base64url-encoded code_verifier string.
; ============================================================================
Func _PKCE_NewVerifier()
	Return _Base64UrlEncode(_GenerateRandomBytes(64))
EndFunc   ;==>_PKCE_NewVerifier

; ============================================================================
; _PKCE_Challenge
; ----------------------------------------------------------------------------
; Description : Derives the PKCE (RFC 7636) "S256" code_challenge from a
;               code_verifier: SHA-256 hash, then base64url-encoded. The
;               SHA-256 algorithm ID is hard-coded as a numeric literal
;               (rather than using the $CALG_SHA_256 constant) because the
;               CryptConstants.au3 include file that would normally define
;               it is missing on some AutoIt installations; the numeric
;               value is the standard Windows ALG_ID for SHA-256 as
;               defined in wincrypt.h.
; Parameters  : $sVerifier - The code_verifier to hash (as produced by
;               _PKCE_NewVerifier()).
; Returns     : The base64url-encoded code_challenge string.
; ============================================================================
Func _PKCE_Challenge($sVerifier)
	Local Const $iCALG_SHA_256 = 0x0000800C
	_Crypt_Startup()
	Local $bHash = _Crypt_HashData(StringToBinary($sVerifier, 4), $iCALG_SHA_256)
	_Crypt_Shutdown()
	Return _Base64UrlEncode($bHash)
EndFunc   ;==>_PKCE_Challenge

; ============================================================================
; _FindFreePort
; ----------------------------------------------------------------------------
; Description : Finds the first available (not-yet-in-use) TCP port on
;               127.0.0.1, starting at $iStart and trying up to 200
;               consecutive port numbers, by briefly opening and
;               immediately closing a test listening socket on each
;               candidate port.
; Parameters  : $iStart - First port number to try.
; Returns     : The first free port number found, or $iStart itself if no
;               free port was found in the searched range (as a
;               best-effort fallback).
; ============================================================================
Func _FindFreePort($iStart)
	Local $iPort = $iStart
	While $iPort < $iStart + 200
		Local $iSock = TCPListen("127.0.0.1", $iPort)
		If $iSock <> -1 Then
			TCPCloseSocket($iSock)
			Return $iPort
		EndIf
		$iPort += 1
	WEnd
	Return $iStart
EndFunc   ;==>_FindFreePort

; ============================================================================
; _FindFreeSmtpPort
; ----------------------------------------------------------------------------
; Description : Convenience wrapper around _FindFreePort() used to suggest
;               a default local port (starting at $g_iSmtpPortStart, which
;               mirrors the "SmtpPortStart" INI setting under [General], see
;               _LoadGeneralSettings()) when pre-filling the "Add account"
;               dialog.
; Parameters  : (none)
; Returns     : The first free port at or after the configured starting
;               port.
; ============================================================================
Func _FindFreeSmtpPort()
	Return _FindFreePort($g_iSmtpPortStart)
EndFunc   ;==>_FindFreeSmtpPort

; ====================================================================================================
; Function: DeleteAllhBitmaps
; Description: Releases all stored GDI bitmap handles with _WinAPI_DeleteObject. Routine progress is
;              logged via LogFile(..., 6) - the higher, off-by-default-when-compiled level (see
;              LogFile()'s own header comment) rather than the default level 0 - since this runs on
;              every tray menu rebuild and would otherwise dilute the persistent log file with
;              low-value bitmap-handle bookkeeping over a long-running session; an actual deletion
;              failure is still logged at the default level, since that is a real problem worth
;              keeping a permanent record of.
; Parameters: None.
; Returns: None. If the Dictionary contains no entries, the function returns without performing cleanup.
; ====================================================================================================
Func DeleteAllhBitmaps()
	If $mhBitmapStorage.Count = 0 Then
		LogFile("DeleteAllhBitmaps: no entries in the hBitmap storage.", 6)
		Return
	EndIf
	Local $aKeys = $mhBitmapStorage.Keys()
	Local $sKey, $bResult
	For $sKey In $aKeys
		Local $iValue = $mhBitmapStorage.Item($sKey)
		LogFile("DeleteAllhBitmaps: deleting " & $sKey & ": " & $iValue, 6)
		$bResult = _WinAPI_DeleteObject($iValue)
		If Not $bResult Then LogFile("Error: could not delete old hBitmap for menu item " & $sKey & ".")
	Next
	;Reset the Dictionary itself so stale entries (now pointing to already-deleted handles) do not
	;accumulate across repeated menu rebuilds (e.g. toggling big icons, reloading the INI)
	$mhBitmapStorage.RemoveAll()
EndFunc   ;==>DeleteAllhBitmaps

; ====================================================================================================
; Function: TrayItemSetIcon
; Description: Extracts an icon from an icon file, converts it to a 32-bit bitmap with alpha, and
;              assigns it to a tray menu item. Does NOT itself look up or release any bitmap
;              previously assigned to $iMenuId - the caller is expected to have already cleared
;              $mhBitmapStorage via DeleteAllhBitmaps() first if that matters (as _RebuildTrayMenu(),
;              this function's only caller, already does before recreating every tray item with a
;              fresh ID each time - so there is never actually an old bitmap left over FOR THAT
;              SPECIFIC ID to find and release at this point; an earlier version of this function
;              carried that per-ID check anyway, which was always a no-op in practice here and has
;              been removed). Routine progress is logged via LogFile(..., 6) - the higher, off-by-
;              default-when-compiled level - for the same "avoid diluting the persistent log with
;              routine bitmap bookkeeping" reason as DeleteAllhBitmaps(); actual failures are still
;              logged at the default level.
; Parameters:
;   $hMenu      - Handle of the tray menu.
;   $iMenuId    - Menu item ID that receives the bitmap.
;   $sIconFile  - Path to the file containing the icon.
;   $iIconIndex - Zero-based icon index to extract.
;   $iIconSize  - Width and height of the icon in pixels.
; Returns: 1 on success; 0 with @error set to 1 (icon extraction failed), 2 (bitmap creation failed),
;          or 3 (_GUICtrlMenu_SetItemBmp failed to assign the bitmap to the menu item) on failure.
;
; Known Issues:
;	As soon as a bitmap is assigned to an AutoIt tray item via _GUICtrlMenu_SetItemBmp(),
;	TrayItemGetText() and TrayItemSetText() no longer work reliably for that item
;	This can be worked around using the following construction:
;	$iCalcMenuId = _GUICtrlMenu_GetItemID($hMenu, $idCalc, False)
;	TrayItemSetIcon($hMenu, $iCalcMenuId, @SystemDir & "\calc.exe", 0)  or alternatively TrayItemSetIcon($hMenu, $idCalc, @SystemDir & "\calc.exe", 0)
;	_GUICtrlMenu_SetItemText($hMenu, $iCalcMenuId, "Test", False)
; ====================================================================================================
Func TrayItemSetIcon($hMenu, $iMenuId, $sIconFile, $iIconIndex = 0, $iIconSize = 16, $bByPosition = False, $sStorageKey = "")
	Local $hIcon = _WinAPI_ShellExtractIcon($sIconFile, $iIconIndex, $iIconSize, $iIconSize)
	If @error Or $hIcon = 0 Then
		LogFile("Error: Icon #" & $iIconIndex & " from icon file " & $sIconFile & " could not be extracted")
		Return SetError(1, 0, 0)
	EndIf

	Local $hBitmap = _WinAPI_Create32BitHBITMAP($hIcon, True)
	If @error Or $hBitmap = 0 Then
		LogFile("Error: Bitmap could not be created")
		_WinAPI_DestroyIcon($hIcon)
		Return SetError(2, 0, 0)
	EndIf
	_WinAPI_DestroyIcon($hIcon)

	;we hand over the reference to $hBitmap and BitmapPremultiplyAlpha changes the content adressed by $hBitmap
	If Not BitmapPremultiplyAlpha($hBitmap, $iIconSize, $iIconSize) Then
		LogFile("TrayItemSetIcon: premultiply failed, GetLastError=" & _WinAPI_GetLastError(), 6)
		; Do not abort: use the bitmap anyway
	EndIf

	LogFile("TrayItemSetIcon: assigning icon #" & $iIconIndex & " from " & $sIconFile & " to menu item " & $iMenuId, 6)
	If Not _GUICtrlMenu_SetItemBmp($hMenu, $iMenuId, $hBitmap, $bByPosition) Then
		LogFile("Error: _GUICtrlMenu_SetItemBmp failed for menu item " & $iMenuId & " (icon file " & $sIconFile & ")")
		_WinAPI_DeleteObject($hBitmap)
		Return SetError(3, 0, 0)
	EndIf

	;save in Dictionary to delete later when no longer needed
	If $sStorageKey = "" Then $sStorageKey = String($iMenuId)
	$mhBitmapStorage.Item($sStorageKey) = $hBitmap
	Return 1
EndFunc   ;==>TrayItemSetIcon

; ============================================================================
; _TrayMenuPosOfSubmenu
; ----------------------------------------------------------------------------
; Description : R2: position (0-based) of the entry in $hMenu that opens the
;               submenu $hSubMenu - needed to give a submenu entry an icon,
;               because such an entry has no command ID to address it by.
; Parameters  : $hMenu    - Handle of the menu that contains the entry.
;               $hSubMenu - Handle of the submenu (TrayItemGetHandle()).
; Returns     : The position, or -1 if not found.
; ============================================================================
Func _TrayMenuPosOfSubmenu($hMenu, $hSubMenu)
	If $hSubMenu = 0 Then Return -1
	Local $i = 0
	For $i = 0 To _GUICtrlMenu_GetItemCount($hMenu) - 1
		If _GUICtrlMenu_GetItemSubMenu($hMenu, $i) = $hSubMenu Then Return $i
	Next
	Return -1
EndFunc   ;==>_TrayMenuPosOfSubmenu

; ====================================================================================================
; Function: BitmapPremultiplyAlpha
; Description: Reads a 32-bit bitmap, premultiplies its RGB channels by the alpha channel,
;              and writes the adjusted pixel data back to the bitmap.
; Parameters:
;   $hBitmap - Handle of the 32-bit bitmap to process.
;   $iW      - Bitmap width in pixels.
;   $iH      - Bitmap height in pixels.
; Returns: True if the bitmap was processed successfully; otherwise False.
; ====================================================================================================
Func BitmapPremultiplyAlpha($hBitmap, $iW, $iH)
	; BITMAPV5HEADER with BI_BITFIELDS -> alpha channel is preserved
	Local $tBIV5 = DllStructCreate($tagBITMAPV5HEADER)
	DllStructSetData($tBIV5, 'bV5Size', DllStructGetSize($tBIV5))
	DllStructSetData($tBIV5, 'bV5Width', $iW)
	DllStructSetData($tBIV5, 'bV5Height', $iH)       ; positive = bottom-up (more reliable with GetDIBits)
	DllStructSetData($tBIV5, 'bV5Planes', 1)
	DllStructSetData($tBIV5, 'bV5BitCount', 32)
	DllStructSetData($tBIV5, 'bV5Compression', $BI_BITFIELDS)
	DllStructSetData($tBIV5, 'bV5RedMask', 0x00FF0000)
	DllStructSetData($tBIV5, 'bV5GreenMask', 0x0000FF00)
	DllStructSetData($tBIV5, 'bV5BlueMask', 0x000000FF)
	DllStructSetData($tBIV5, 'bV5AlphaMask', 0xFF000000)

	Local $tPixels = DllStructCreate("byte[" & ($iW * $iH * 4) & "]")
	Local $hDC = _WinAPI_GetDC(0)

	Local $aRet = DllCall('gdi32.dll', 'int', 'GetDIBits', 'handle', $hDC, 'handle', $hBitmap, 'uint', 0, 'uint', $iH, 'struct*', $tPixels, 'struct*', $tBIV5, 'uint', 0)
	If @error Or Not $aRet[0] Then
		_WinAPI_ReleaseDC(0, $hDC)
		Return False
	EndIf

	; BGRA: alpha is located at byte offset +3
	Local $iSize = $iW * $iH * 4
	Local $i
	For $i = 1 To $iSize Step 4
		Local $iA = DllStructGetData($tPixels, 1, $i + 3)
		If $iA < 255 Then
			DllStructSetData($tPixels, 1, Int(DllStructGetData($tPixels, 1, $i) * $iA / 255), $i)
			DllStructSetData($tPixels, 1, Int(DllStructGetData($tPixels, 1, $i + 1) * $iA / 255), $i + 1)
			DllStructSetData($tPixels, 1, Int(DllStructGetData($tPixels, 1, $i + 2) * $iA / 255), $i + 2)
		EndIf
	Next

	Local $aSetRet = DllCall('gdi32.dll', 'int', 'SetDIBits', 'handle', $hDC, 'handle', $hBitmap, 'uint', 0, 'uint', $iH, 'struct*', $tPixels, 'struct*', $tBIV5, 'uint', 0)
	_WinAPI_ReleaseDC(0, $hDC)
	If @error Or Not $aSetRet[0] Then Return False

	Return True
EndFunc   ;==>BitmapPremultiplyAlpha

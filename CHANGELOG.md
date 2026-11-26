# Changelog

Version numbers: "vN" is the development version of the script, the number
in brackets the `#AutoIt3Wrapper_Res_Fileversion` (shown in the tray menu
and the log). The open items and ideas are kept in the roadmap
(README.txt, section 16).

## v82 (1.0.0.64)
- Version info of the .exe: description, product name and version,
  company and copyright are now the program's own (before: the AutoIt
  defaults "Aut2Exe", "3.3.18.0" and the AutoIt copyright) - visible in
  the file properties, the Task Manager and the Windows Firewall prompt.

## v81 (1.0.0.63)
- Notifications: **Telegram** as a new channel (a bot of your own, bot
  token + chat ID, "Find chat ID" button; problems with sound, "OK again"
  and start/stop silently). ntfy and Telegram side by side in the window.

## v80 (1.0.0.62)
- Notifications window 606 px high instead of 712 px, so it fits above the
  taskbar on small screens: Command and Heartbeat side by side, grey hint
  texts in the empty Command / Ping URL fields.
- Advanced settings: hint text says "clearing the log" (there is only one
  log since v71).

## v79 (1.0.0.61)
- The TODO list moved from the script header into README.txt, section 16
  ("Roadmap") - one place for all open items.
- README: test e-mail and connection test do not trigger the "E-mail
  refused" / "Repeated errors" notifications (and why).

## v78 (1.0.0.60)
- Notifications: a random ntfy topic is suggested
  (`CCSMTPOAuth2Proxy-` + 8 letters/digits) as long as none is saved.

## v77 (1.0.0.59)
- Own icons for Settings > Accounts, Advanced and Notifications.

## v76 (1.0.0.58)
- **Notifications** (Settings > Notifications): ntfy, webhook (presets for
  Teams Workflows, Slack, Discord, generic JSON), command, heartbeat;
  events sign-in required, token renewal failed, e-mail refused, repeated
  errors, proxy blocked, started/stopped; "OK again" messages; rate limit;
  test button per channel. Sending is done by a separate short-lived
  process (`/notify`), whose results are written into the log.

## v75 (1.0.0.57)
- "Test Connection" shows "Testing ..." and a wait cursor while it runs.

## v74 (1.0.0.56)
- Provider icons (Microsoft / Google / custom) for the account entries in
  the tray menu.

## v73 (1.0.0.55)
- Message boxes size themselves to their text.

## v72 (1.0.0.54)
- Unused About icon removed; icon numbers adjusted.

## v71 (1.0.0.53)
- Only ONE log file: the lines of the PowerShell helpers are written into
  the main log ("Helper [...]", errors always, the rest at log level 6);
  `RelayHelper.log` and `ClearRelayLogOnStart` removed. Review of all
  comments and the README.

## v70 (1.0.0.52)
- The PowerShell helpers report their log lines over stderr.

## v61 - v69
- Tray menu reorganised: the title item (name + version) opens the About
  window; "Settings" submenu with Accounts, Advanced, Autostart; icons.
- Test e-mail: "Sender (From)" field for "Send As" checks, scrollable
  result field, shortened Microsoft diagnostic replies, explanation for
  "SendAsDenied".

## v57 - v60
- AuthResultTimeoutMs: a sign-in the mail server does not answer is ended
  with a temporary error (454) instead of letting the device time out.
- Clearer log messages for blocked main loop and slow token renewal.
- Advanced settings window (all general settings with tooltips, Save /
  Cancel / Defaults).

## v45 - v56
- Log rotation (MaxLogSizeMB / LogGenerations) in a "log" folder; helper
  script renamed to `CCSMTPOAuth2Proxy-RelayHelper.ps1`.
- More robust log writing; fixed end-of-message detection; version in the
  tray title and the error date in the tooltip.

## v37 - v44
- TcpTimeoutMs = 0: no more 100 ms waits per accept/receive check - large
  e-mails about twice as fast (5 MB in about 6 s).
- "MESSAGE INCOMPLETE" notes, tray tooltip with daily statistics.

## v1 - v36
- Initial development: SMTP listener and state machine, OAuth2 with PKCE,
  token renewal, PowerShell TLS helper, DPAPI encryption, account
  dialogs, test e-mail, diagnostics and watchdogs.

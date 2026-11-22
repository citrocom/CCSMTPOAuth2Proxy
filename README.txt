===============================================================================
 CCSMTPOAuth2Proxy - README
===============================================================================

CCSMTPOAuth2Proxy is a small Windows tray application that lets e-mail
clients and devices which only support old-fashioned username/password SMTP
login send mail through modern providers - Microsoft 365 / Outlook.com and
Google Workspace / Gmail - that now require OAuth2 sign-in instead.

This document explains what the program does, how to use it, and how to
set up the required app registration on the Microsoft and Google side.

This project was inspired by the ideas behind email-oauth2-proxy by Simon
Robinson (https://github.com/simonrob/email-oauth2-proxy) - the general
concept of a local SMTP-to-OAuth2 proxy comes from there. The code itself
is entirely new: a from-scratch AutoIt implementation, not a port or
translation of that project's own source code. Since email-oauth2-proxy
is licensed under the Apache License, Version 2.0, this project is
released under the same license, so that anyone receiving this program
has the same rights that project's license already gave to this one - see
LICENSE.txt.


-------------------------------------------------------------------------------
 1. WHY DO I NEED THIS?
-------------------------------------------------------------------------------

Microsoft and Google have both switched off (or are switching off) plain
"username + password" SMTP login for their mail servers. Instead, you now
have to sign in with OAuth2, which involves a browser-based login and a
short-lived access token instead of a fixed password.

Modern e-mail programs (Outlook, Thunderbird, Apple Mail, ...) support this
directly. Many older devices and pieces of software do not - printers and
scanners with a "scan to e-mail" feature, network-attached storage devices,
backup software, monitoring tools, in-house applications, and so on. These
only know how to send a plain username and password.

CCSMTPOAuth2Proxy sits in between: your old device talks to it exactly as
it always has (a local SMTP server, plain username/password), and the
proxy handles the OAuth2 sign-in and token refreshing with the real mail
server behind the scenes.


-------------------------------------------------------------------------------
 2. REQUIREMENTS
-------------------------------------------------------------------------------

  - Windows 10, Windows 11, or Windows Server 2019 / 2022 / 2025 with the
    "Desktop Experience" installed. This program uses a tray icon, which
    needs the normal Windows shell (Explorer) to dock into - a "Server
    Core" installation (no Desktop Experience) does not provide this.
    Server support is based on a technical review of what this program
    actually uses (Windows PowerShell, DPAPI, and other components that
    are present on Server the same way as on desktop Windows), not on
    testing on an actual Windows Server installation - if you run into
    anything different there, please report it.
  - Windows PowerShell (included with Windows) - used internally to make
    the actual encrypted connection to the mail server (TLS 1.2, or TLS
    1.3 on Windows 11 / Server 2022 and later). If a Group Policy only
    allows signed PowerShell scripts, the helper cannot start; the log
    then shows "Helper error output: ..." with PowerShell's message
    (see "No connection works ... PowerShell" in section 10).
    The program writes this small helper script
    (CCSMTPOAuth2Proxy-RelayHelper.ps1) next to itself on every start -
    so the program's folder must be writable for the user it runs as
    (the same applies to the INI file and the "log" folder).
  - A Windows user who stays signed in: the program runs in that user's
    session (tray icon). With "Autostart" (section 5) it starts when that
    user signs in - after a restart of the PC it is therefore not running
    until someone signs in.
  - A Microsoft 365 / Outlook.com account, or a Google Workspace / Gmail
    account, that you want to send mail through
  - For each such account, an "app registration" you create yourself in
    the Microsoft or Google admin console - see sections 12 and 13 below.
    This is a one-time setup step per provider (not per account), and it
    is required by Microsoft and Google, not something this program adds.


-------------------------------------------------------------------------------
 3. HOW IT WORKS
-------------------------------------------------------------------------------

For each e-mail account you configure, the program opens a small local
SMTP listener on your PC (e.g. 127.0.0.1, port 1587). You point your old
device or software at that address and port instead of the real mail
server, and give it a locally-chosen username/password (see section 8).

When your device connects and sends mail, the proxy:
  1. Checks the local username/password you configured.
  2. Obtains a valid OAuth2 access token for the real account (signing in
     via your browser the first time, and silently refreshing the token
     automatically afterwards - no repeated logins needed).
  3. Opens its own encrypted (TLS) connection to the real mail server and
     relays your message through it.

Your device never sees the real password or the OAuth2 tokens - it only
ever talks to the proxy on your own PC.


-------------------------------------------------------------------------------
 4. FIRST START
-------------------------------------------------------------------------------

When you start the program for the first time (no account configured
yet), the Account Settings window opens automatically as a prompt to add your
first account. See section 7 for what to fill in.

After that, the program keeps running quietly with just an icon in the
Windows notification area (system tray) - closing the Account Settings window
does not close the program itself.


-------------------------------------------------------------------------------
 5. THE TRAY ICON AND MENU
-------------------------------------------------------------------------------

Right-click (or left-click, depending on your Windows settings) the tray
icon to open the menu. From top to bottom:

  - The program name and version (e.g. "CCSMTPOAuth2Proxy  v1.0.0.53") -
    clicking it shows the About window (version, a short description and
    the credits).
  - One entry per configured account, showing its current status. The
    icon in front of it shows the account's provider type: blue "M" =
    Microsoft 365 / Outlook.com, red "G" = Google, grey envelope = custom
    OAuth2 provider. (These are simple icons of the program's own, not the
    providers' logos.)

      [disabled]          The account is currently switched off (see
                           "Enable/Disable" in Account Settings) and will
                           not accept any connections. Clicking it shows a
                           reminder to enable it first in Account Settings.

      [sign-in required]  The account needs a fresh OAuth2 sign-in -
                           either it was just added, or a previous sign-in
                           has expired or been revoked. Clicking it opens
                           your browser to sign in.

      [signed in]         The account is ready and working. Clicking it
                           asks whether you really want to sign in again
                           (useful if you want to switch to a different
                           account in the browser, for example), rather
                           than doing it silently.

  - Settings   A submenu with these entries:
                 Accounts  Opens the Account Settings window (section 6)
                           - the list of accounts and everything you can
                           do with them.
                 Advanced  Opens the window for the general settings that
                           apply to all accounts: logging (detail level,
                           log rotation, clearing the log on start),
                           ports, connection and time limits, and the
                           warnings written to the log - see section 14.
                           Every field explains itself when you hover
                           over it. "Save" writes the values to the INI
                           file and the running program uses them right
                           away; "Cancel" (or the X) discards all
                           changes; "Defaults" fills in the default
                           values (saved only with "Save").
                 Notifications  Opens the window for notifications to
                           the phone (ntfy), to a webhook (Teams, Slack,
                           ...), to a command of your own, and for the
                           heartbeat that raises an alarm when the proxy
                           stops - see section 15.
                 Autostart A checkable item - tick it to have this
                           program start automatically the next time you
                           sign in to Windows, untick it to stop that.
                           Only has any effect for the compiled program
                           (the .exe); if you are running the raw script
                           instead, clicking it does nothing (this is
                           logged, but not shown as an error, since a raw
                           script cannot be autostarted the same way).
  - Open Log File   Opens the log file (see section 10) in whatever
               program is associated with .log files on your PC
               (Notepad, by default).
  - Exit       Shuts the program down completely. If connections are
               active at that moment (an e-mail may be in transfer), you
               are asked first; confirming closes them immediately.

Hovering over the tray icon shows a short status: how many e-mails were
sent today (and refused by the mail server, if any), how many connections
are active right now, and the most recent error with its time - if the
error did not happen today, with its date as well, written the same way
as in the log ("2026-10-12 14:23"), so you can search the log for it. On the day
the program was started the counter only covers the time since the start,
so it says "Since HH:MM: ... sent" then, and "Today: ... sent" from the
next day on.

Note: while the tray menu is open, the program is paused (a limitation of
AutoIt) - no device is served during that time, and after about 3 seconds
a "main loop was not serviced" warning is logged (section 10). So do not
leave the menu open longer than necessary.


-------------------------------------------------------------------------------
 6. THE ACCOUNT SETTINGS WINDOW
-------------------------------------------------------------------------------

The Account Settings window (tray menu: Settings -> Accounts) lists every
configured account with its provider, local port, local address, server,
whether STARTTLS is used, whether a local password is set, and its
sign-in status - so you can see everything at a glance. Select a row
and use the buttons below the list (or double-click a row as a shortcut
for "Edit"):

  New              Add a new account - see section 7.

  Edit             Change an existing account's settings (server address,
                    client ID, local password, ...). The e-mail address
                    itself cannot be changed here; delete and re-add the
                    account instead if you need to.

  Enable/Disable    Temporarily switch an account's local listener on or
                    off, without deleting its configuration. Any
                    connection already in progress for that account is
                    closed immediately when you disable it.

  Delete            Permanently remove an account and its local listener.
                    You are asked to confirm first, since this cannot be
                    undone.

  Test E-Mail       Send a test message through the selected account -
                    see section 9.

  Test Connection   Check the whole chain for the selected account -
                    connection and encryption to the mail server, the
                    sign-in token and the sign-in itself - WITHOUT sending
                    an e-mail. This takes a few seconds; meanwhile the
                    button reads "Testing ..." and the mouse pointer
                    shows the wait cursor. The result (and how long it
                    took) is then shown and written to the log.


-------------------------------------------------------------------------------
 7. ADDING A NEW ACCOUNT - FIELD BY FIELD
-------------------------------------------------------------------------------

Click "New" in Account Settings to open the Add Account window:

  Provider              Choose "Microsoft 365 / Outlook.com", "Google
                          Workspace / Gmail", or "Custom" for anything
                          else that offers a standard OAuth2 SMTP login.
                          Choosing Microsoft or Google fills in the
                          server address, port and OAuth2 endpoints for
                          you automatically.

  Authorize URL, Token    The provider's OAuth2 endpoints and the scope
  URL, Scope              needed for sending mail via SMTP. Filled in
                          (and locked) for Microsoft and Google; only for
                          "Custom" do you enter them yourself - both URLs
                          must start with https://. You find these values
                          in your provider's OAuth2 documentation.

  E-mail address         The real mailbox address you want to send
                          through (e.g. name@yourcompany.com).

  Local SMTP password    This is NOT your Microsoft or Google password.
                          It is a password you make up yourself, used
                          only between your local device and this proxy,
                          on your own PC. Must be at least 8 characters.
                          You will enter this (together with the e-mail
                          address above) into your old device or
                          software's own SMTP settings - see section 8.

  Local port             The port the proxy listens on for this account
                          on your own PC (a sensible free port is
                          suggested automatically). This is the port you
                          will point your device at. Allowed: 1024-65535.

  Local address           127.0.0.1 by default - only your own PC can
                          connect. See section 8 below and section 11
                          (Security notes) before changing this to allow
                          other devices on your network to reach it -
                          either to 0.0.0.0 (every network interface this
                          PC has), or to one specific IP address of this
                          PC (e.g. 192.168.1.50) to allow connections on
                          just that one network interface. A specific IP
                          address only works reliably if it is fixed
                          (statically assigned) on that network adapter -
                          if it comes from DHCP and changes, the listener
                          will fail to start until this field is updated
                          to match. Only IPv4 addresses are accepted.

  Server address / port  The real mail server to relay to. Filled in
                          automatically for Microsoft and Google.

  Use STARTTLS            Leave this at its default for Microsoft/Google
                          presets; only change it if you know your
                          "Custom" provider needs something different.

  Client ID, Directory   These identify your own app registration with
  (tenant) ID, Client     the provider - see sections 12 (Microsoft) and
  secret                  13 (Google) for how to obtain them. The tenant
                          ID field is Microsoft-only and can usually stay
                          empty. The client secret is optional for
                          Microsoft when using the recommended PKCE
                          sign-in method, but Google issues one for every
                          "Desktop app" credential and it should be
                          entered. It is shown hidden while you type.

Click "Save & sign in" - the account is saved, and your browser opens for
you to sign in and grant access. Once that succeeds, the account is ready
to use.


-------------------------------------------------------------------------------
 8. CONFIGURING YOUR E-MAIL CLIENT OR DEVICE
-------------------------------------------------------------------------------

In whatever old device or software you are connecting, use these SMTP
settings:

  Server / host      The IP address of the PC running this program - use
                       the literal address 127.0.0.1 if the software is
                       running on that same PC (see the IPv6 note below
                       for why "localhost" is best avoided here).
  Port                The "Local port" you set (or were given) when
                       adding the account.
  Encryption           None / plain (do not enable SSL or STARTTLS on the
                       device's own connection to the proxy - the
                       connection between your device and the proxy stays
                       on your own PC/network; the proxy itself makes its
                       own separate, properly encrypted connection to the
                       real mail server).
  Username             The account's e-mail address.
  Password              The Local SMTP password you chose when adding the
                       account (not your real Microsoft/Google password).

If your device is on a different PC on the same network, this needs two
changes: set the account's "Local address" (see section 7) to 0.0.0.0
(all network interfaces) or the specific LAN IP address of the PC running
CCSMTPOAuth2Proxy, and make sure Windows Firewall allows incoming
connections to that port. Read section 11 (Security notes) first - by
default (127.0.0.1), no other device can reach the proxy at all, and
changing this trades that away.

A note on IPv6: this program's local listener only understands IPv4
addresses (127.0.0.1, 0.0.0.0, or a specific IPv4 LAN address - see
section 7) - it cannot be reached over IPv6. This normally does not
matter, but on a PC that has both an IPv4 and an IPv6 address, some
e-mail-sending tools try IPv6 first when given a hostname like
"localhost" (which can resolve to the IPv6 address ::1 before 127.0.0.1)
and then simply fail to connect, rather than falling back to IPv4. The
command-line tool mailsend.exe is one example - it tries IPv6 first and
needs to be told not to, either by giving it the literal IPv4 address
127.0.0.1 instead of "localhost" (usually the simpler fix), or with its
own "-4" (force IPv4) option. If a device or piece of software cannot
reach the proxy despite the settings above looking correct, and that PC
has an IPv6 address, this is worth checking - point the software at
127.0.0.1 (or the specific IPv4 LAN address in use) directly rather than
a hostname, and look for a "force IPv4" style option if it still fails.


-------------------------------------------------------------------------------
 9. SENDING A TEST E-MAIL
-------------------------------------------------------------------------------

Select an account in Account Settings and click "Test E-Mail". Enter a
recipient address (pre-filled with the account's own address, for sending
a test to yourself) and click "Send test e-mail". The "Sender (From)"
field is pre-filled with the account's own address as well - see
"Sending with another address" below for what it is for. The result (success, or
the exact error reported by the server) is shown directly in the window,
together with how long the send took. A duration under one minute is
shown in milliseconds (e.g. "5342ms"); from one minute upwards it is shown
as minutes:seconds.milliseconds (e.g. "1:34.250"), which is easier to
read for a very large attachment. The same value is also written to the
log file.

Two optional extras are useful for testing how well a large or unusual
message comes through end to end:

  Send large test e-mail    Sends a much bigger message with generated
                              text and HTML content, instead of the
                              normal short one.

  Attach random file         Attaches a randomly-generated file of a size
                              you pick from the dropdown (500 KB up to
                              20 MB), to test how attachments of that
                              size behave.

Sending a large e-mail or a large attachment can take noticeably longer
than a normal test - this is expected and depends on your own connection
speed and the mail server's own processing time. For comparison, measured
with Microsoft 365: a test e-mail without attachment takes about 2-3
seconds (most of it is starting the helper and signing in), one with a
5 MB attachment about 6 seconds.

Sending with another address (shared mailbox, "Send As")

The proxy always signs in at the mail server with the account it is set
up for (e.g. info@...). The sender address of an e-mail - the SMTP
"MAIL FROM" and the "From:" line - is passed through unchanged, so a
device may also send with another address, e.g. a shared mailbox such as
invoices@... - but only if the mail server allows the signed-in account
to do that. The proxy itself does not check or change the sender; it
needs no extra account for a shared mailbox.

For Microsoft 365 the account needs the "Send As" permission for that
mailbox:
  - Exchange admin center: Recipients -> Mailboxes (or the shared
    mailboxes) -> the shared mailbox -> Delegation -> "Send as" -> add
    the account the proxy signs in with.
  - Or in Exchange Online PowerShell:
      Add-RecipientPermission -Identity invoices@your-domain `
          -Trustee info@your-domain -AccessRights SendAs
  - It can take up to about an hour until a new permission is active.
  - "Send on behalf" is NOT enough for sending over SMTP - only
    "Send As" works there.

To check it: open "Test E-Mail", enter the other address under "Sender
(From)" and send. If the permission is missing, the server refuses the
message (typically "554 5.2.252 SendAsDenied" or "550 5.7.60 ... not
have permissions to send as this sender"); the result in the window
then adds a hint on what to change. If it works, the window says
"Send As works" - check in the received e-mail that it shows the other
address as the sender. When a device's own e-mail is refused for this
reason, the "did NOT accept the e-mail" warning in the log carries the
same hint.

Copies in "Sent Items": the copy of such an e-mail is normally kept in
the signed-in account's mailbox. To also keep one in the shared mailbox,
switch on in Exchange Online PowerShell:
    Set-Mailbox invoices@your-domain -MessageCopyForSentAsEnabled $true
Whether a copy is kept at all for e-mail sent over SMTP is best checked
with a test e-mail.

For other addresses of the account's OWN mailbox (aliases), Exchange
Online has a separate organisation setting ("send from aliases"); check
with a test e-mail whether your tenant allows it for SMTP.


-------------------------------------------------------------------------------
 10. LOG FILES AND TROUBLESHOOTING
-------------------------------------------------------------------------------

The program keeps its log in a "log" folder next to itself:
log\CCSMTPOAuth2Proxy.log. There is only this ONE log file - the
messages of the PowerShell helper that talks to the mail server are
written into it as well (up to version 1.0.0.52 they had a separate
file, CCSMTPOAuth2Proxy-RelayHelper.log; an old copy of it can simply
be deleted).
When the log reaches "MaxLogSizeMB" (default 10 MB, section 14), it
is renamed to CCSMTPOAuth2Proxy.1.log (older parts move up to .2, .3,
...; "LogGenerations", default 5, are kept) and a new file is started -
so the log never grows without limit.

Lines from the PowerShell helper start with "Helper" and the
connection they belong to, e.g.
  Helper [socket 1752 | 192.168.1.5:50639 | PID 1280]: TLS upgrade
    successful (Tls13).
  Helper error [socket 1752 | 192.168.1.5:50639 | PID 1280]: Error
    sending to server: ...
or "[test e-mail | ...]" / "[connection test | ...]" for the tests in
Account Settings. "Helper error" lines are always written; the normal
"Helper" lines (start, connection, TLS, end with byte totals) only with
"LogLevel" 6 or higher (section 14). When several devices send at the
same time, their lines stand next to each other in the file; to see a
single connection, search for its socket number (e.g. in PowerShell:
Select-String "socket 1752" .\log\CCSMTPOAuth2Proxy.log).

The main log records things like
accounts signing in, connections being handled, and any errors. If
something isn't working, this is the first place to look. You can also
open it directly via "Open Log File" in the tray menu.

Besides errors, you may see a few other line types that are not
themselves a problem:

  "E-mail relayed: From=... To=... Subject=..."
    A normal record of a message that was passed through the proxy - see
    the privacy note in section 11 about this. The line is written as soon
    as your device has finished sending the message to the proxy; the real
    mail server's own answer arrives a moment later (with LogLevel 8 you
    can see it, including the server's reply code, in a separate "Timing:
    real server acknowledged the message ..." line).

    If a subject contains accented letters, umlauts, other non-English
    characters or emoji, the sending software transmits it in an encoded
    form that looks like =?UTF-8?B?...?= or =?UTF-8?Q?...?=. The proxy
    decodes this for the log, so the Subject= part is shown as readable
    text. Only the log line is affected - the message itself is passed on
    to the mail server completely unchanged. Decoding covers UTF-8 and the
    common Western single-byte character sets (e.g. ISO-8859-1,
    Windows-1252); a subject in some other character set, or one that
    cannot be decoded, is simply logged in its original encoded form.

  "Warning: connection ... has been open for over Ns without completing
  authentication"
    Appears once for a connection that took unusually long to sign in
    (or never did) - often just a slow network, but worth checking if it
    happens a lot.

  "Note: authenticated connection ... has been idle for over Ns"
    Appears (and can repeat) for a connection that is still open but not
    currently sending anything - normal if the sending software simply
    keeps the connection open for later use.

  "Notification queued ..." / "Notification [...]: ..."
    A notification was handed over for sending, and the result of the
    sending (section 15). A failed sending is logged as "Notification
    error [...]: ..." with the reason.

  "Timing: ..."
    Only appears once "LogLevel" (see section 14) is raised to 8 or
    higher - breaks down where the time actually went while sending an
    e-mail (obtaining a sign-in token, the exchange with the server,
    the upload itself, the server's own acknowledgement). Useful if a
    send feels unusually slow and you want to narrow down why; not shown
    by default since it adds a line for practically every step.

    Durations are written like the one in the test e-mail window (section
    9): in milliseconds ("812ms") below one minute, and as
    minutes:seconds.milliseconds ("1:34.250") from one minute upwards.

    For an e-mail passing through the proxy, the two lines most useful
    for judging a slow send are:

      "Timing: client finished sending the message body ... after
      starting DATA"
        How long your device needed to hand the message over. Because the
        proxy forwards the data to the real server while it arrives, this
        also includes any time the server connection needed to keep up.

      "Timing: real server acknowledged the message (250) ... after the
      client finished sending it"
        How long the real mail server took to accept the message once the
        last byte was sent - for example for its own virus or spam
        checks. The number in brackets is the server's reply code (250
        means accepted).

  "Connection closed (...) - N connection(s) still active. Reason: ..."
    Written for every connection when it ends. After the first sentence
    it says why the connection ended, which device connected (its IP
    address and port - also shown in the "New connection" line), how long
    it lasted and in which state it ended, when the server greeting, the
    EHLO answer and the login reached the client ("Timeline"), which
    commands the client sent (only the command words - never passwords),
    and the last reply of the real mail server. If the client sent data
    the proxy could not read at all, that is noted too - a TLS handshake
    in particular means the device is set to use SSL/TLS towards the
    proxy, which it does not offer (see section 8). If the helper process
    itself reported an error before it ended (for example PowerShell
    refusing to run its script because of a Group Policy, see the
    Requirements), that text is included as "Helper error output: ...".
    If the connection ended in the middle of an e-mail - the client had
    started sending the message (DATA) but never sent its end - the line
    contains "MESSAGE INCOMPLETE" with how much of the message arrived
    and when the last part of it came. The mail server discards such a
    message, so nothing was delivered; almost always the sending program
    stopped or crashed while sending (check the Windows event log on that
    device - "Application Error" for the program). If the client did send
    the whole message but the connection ended before the mail server
    answered, the line says that it is unclear whether it was delivered.

  "Warning: the real server answered with an error ..." /
  "Warning: the real server did NOT accept the e-mail ..." /
  "Warning: the real server rejected the XOAUTH2 sign-in ..."
    The real mail server's own error message (any reply starting with 4
    or 5), always logged, together with what it answered. Earlier
    versions only passed a generic error on to the device.

  "Token refresh for ... started (...)" /
  "Token refresh for ... succeeded after ..." /
  "Token refresh failed (...) after ..."
    The program renews the account's sign-in token with Microsoft/Google
    roughly once an hour, normally about 10 minutes before it runs out
    ("proactive"), or right when a device needs one ("on demand"). While
    that request runs, the program can do nothing else, so these lines
    (with the duration) let you check whether a device that got no
    answer happened to connect at the same time.

  "Warning: the main loop was not serviced for ..."
    The program works on one thing at a time. If something blocked it
    for longer than "LoopBlockWarnMs" (section 14) - a slow sign-in
    token request to Microsoft/Google, a stuck helper process, the PC
    being in standby - no device could be served during that time; it
    would see "connected, but no answer". This line says how long it
    lasted and which operation took longest. If no timed operation
    explains it, the most common cause is simply that the tray menu was
    open - the program is paused while it is shown. A block that never ends
    cannot be logged by the blocked program itself: if a device gets no
    answer at all, check whether the tray menu still reacts and how much
    CPU the program uses in Task Manager before restarting it.

  "Warning: connection from ... refused - the limit of N simultaneous
  connections (MaxConnections) is reached"
    More devices than allowed by "MaxConnections" (section 14) were
    connected at the same time; the extra one was turned away at once
    (it normally tries again a little later). Written at most every 10
    seconds, with the number of connections refused since the last one.

  "Connection test for ... succeeded / failed ..."
    The result of "Test Connection" in Account Settings (section 6).

  "Warning: connection ... did not complete the login within ..." /
  "Warning: signed-in connection ... had no data ... - closing it."
    A connection that stays stuck is closed after "PreAuthTimeoutMs" or
    "IdleCloseMs" (section 14), so it cannot block a helper process
    forever.

To keep a problem in the log until you get to look at it, set
"ClearLogOnStart" to 0 - in the tray menu Settings -> Advanced, untick
"Clear the log on every start" (section 14) -
otherwise restarting the program deletes exactly the
lines that would explain it. The log is then rotated automatically when
it gets large (see above), so it does not need to be deleted by hand.

A few common issues:

  A device reports a timeout, or connects but gets no answer
    The proxy only answers once its helper has reached the real mail
    server (normally about 1-2 seconds; longer if the PC is busy or the
    network is slow). Some tools wait only a few seconds - mailsend.exe
    1.20b for example waits 5 seconds by default (newer builds 10
    seconds); give it more time with "-read-timeout 30". The
    "Timeline" in the "Connection closed" line shows how long the
    greeting and the login actually took.

  The login hangs - "the real mail server did not answer the sign-in"
    After the device has logged in, the proxy signs in at the mail
    server with the OAuth2 token. Normally the server answers within a
    fraction of a second. During a disruption of the mail service
    (e.g. Microsoft 365) it may not answer at all for a long time - the
    device would then run into its own timeout without a clear reason.
    So after "AuthResultTimeoutMs" (default 20 seconds, section 14) the
    proxy gives the device a temporary error ("454 4.7.0 Temporary
    authentication failure ...") and closes the connection; many
    devices then try again by themselves. The log shows a warning "the
    real mail server did not answer the sign-in", and the "Connection
    closed" line says how long the proxy waited. A new attempt a little
    later usually works; if it keeps happening, check the service
    status of the mail provider (for Microsoft 365: Admin Center ->
    Health -> Service health).

  An e-mail with a large attachment takes a long time to send
    How long this takes depends mostly on your internet connection's
    upload speed and on how quickly the mail server accepts the message.
    To see where the time goes, set "LogLevel" to 8 (section 14) and send
    the message again - the "Timing: ..." lines described above show the
    sign-in, the upload and the server's acknowledgement separately. You
    can also try the "Attach random file" option of the test e-mail
    (section 9) with different sizes. Also check that "TcpTimeoutMs"
    (section 14) is 0 - with the old value 100, every SMTP command took
    about a quarter of a second longer and large uploads ran at only
    about 1 MB/s (5 MB took about 12 s instead of about 6 s).
    "RelayDebugLog" hardly matters for the speed (measured: 5 MB in
    5.9 s with it, 6.2 s without it), but should still be 0 in normal
    operation to keep the log small.

    The proxy does not read through the contents of a message while
    relaying it: only the first part of the message (up to about 16 KB,
    which covers the sender, the recipients and the Subject header) is
    examined for the "E-mail relayed" log line. Everything after that,
    in particular the attachment data, is passed on without any further
    inspection. For the same reason, a Subject header that only appears
    after the first 16 KB of a message would show up as empty in the log
    line (the message itself is sent normally either way).

  A token refresh fails, but the account stays "signed in"
    Only an "invalid_grant" answer from Microsoft/Google means the
    stored sign-in itself is no longer valid (revoked, expired, password
    changed); only then is a new sign-in required. Other errors keep the
    sign-in and the refresh is retried with growing pauses (30 seconds
    up to 10 minutes). "invalid_client" in the log usually means the
    client secret of the app registration has expired - enter the new
    one via Account Settings -> Edit; a new browser sign-in is not needed.

  "Error: could not decrypt the ..." in the log
    Passwords, the client secret and the sign-in tokens are stored
    encrypted for the Windows user on the PC that saved them (section
    11). If the INI file was copied from another PC or user account, or
    the user profile was reset, they cannot be read any more. Enter the
    local password and the client secret again via Account Settings ->
    Edit and
    sign in again via the tray menu.

  "Sign-in required" keeps coming back
    Your organization (for Microsoft 365) may have Conditional Access or
    a similar policy blocking "Authenticated SMTP" for your account - ask
    your IT administrator to confirm SMTP AUTH is allowed for the
    mailbox. This is a Microsoft 365 setting, separate from the app
    registration in section 12.

  The account's local port can't be used / another account already
  uses it
    Each account needs its own local port; the Add/Edit Account window
    will tell you if the one you chose is already taken by another
    configured account.

  No connection works - "Helper error output" mentions PowerShell
  scripts being disabled, not signed, or not allowed
    The proxy starts a small PowerShell script for every connection
    (CCSMTPOAuth2Proxy-RelayHelper.ps1, next to the program) with
    "-ExecutionPolicy Bypass". That switch normally lets the script run
    whatever PowerShell's own setting is - but NOT if the execution
    policy is set by a Group Policy: a policy from Group Policy always
    wins. Typical messages in the log: "... cannot be loaded because
    running scripts is disabled on this system" or "... is not digitally
    signed". The connection then ends right away ("the upstream helper
    process (PowerShell) ended").

    To check: open PowerShell on that PC and run
        Get-ExecutionPolicy -List
    If "MachinePolicy" or "UserPolicy" shows a value (not "Undefined"),
    it comes from a Group Policy. "AllSigned" or "Restricted" there stop
    the helper; "RemoteSigned", "Unrestricted" and "Bypass" do not
    (the helper is a local file, not one downloaded from the internet).

    What an administrator can do (one of these):
      - Change the policy: Computer Configuration > Administrative
        Templates > Windows Components > Windows PowerShell > "Turn on
        Script Execution" - set it to "Allow local scripts and remote
        signed scripts" (RemoteSigned). This is the usual setting and
        still blocks unsigned scripts downloaded from the internet.
      - Exclude only this PC from the policy: move it to its own OU, or
        use security filtering / a WMI filter on the Group Policy object,
        and give that PC a policy with "RemoteSigned" instead.
      - Do not rely on signing this one script: the program writes the
        helper script anew on every start, so a signature added by hand
        would be lost at the next start.
    After the Group Policy was changed, run "gpupdate /force" (or
    restart the PC) and restart the program.

    Related: AppLocker or Windows Defender Application Control (WDAC)
    script rules can put PowerShell into "Constrained Language Mode",
    in which the helper cannot use the network functions it needs - the
    log then shows errors about types or methods not being allowed. The
    remedy is a rule that allows scripts from the program's folder (a
    path rule), set up by whoever manages AppLocker/WDAC.

  Your device gets "connection refused"
    Make sure the account is not shown as [disabled] in the tray menu,
    and that Windows Firewall allows the connection if your device is on
    a different PC. If the PC running this program has both an IPv4 and
    an IPv6 address, also see the IPv6 note in section 8 - some software
    tries IPv6 first against "localhost" and never falls back to IPv4.


-------------------------------------------------------------------------------
 11. SECURITY NOTES
-------------------------------------------------------------------------------

  - Client secrets, local SMTP passwords, and OAuth2 tokens are stored
    encrypted (via Windows' own DPAPI), tied to the Windows user account
    running the program - they cannot be read by simply opening the
    configuration file in a text editor, and cannot be decrypted under a
    different Windows user account or on a different PC.
  - The local SMTP listener only accepts connections after a correct
    local username/password.
  - Each account's "Local address" (set in the Add/Edit Account window,
    see section 7) defaults to 127.0.0.1 - the loopback address, which
    only your own PC can ever reach; no other device on your network can
    connect to it, regardless of firewall settings, because a loopback
    connection never actually leaves your PC's own network stack. Two
    other values are possible: 0.0.0.0 allows connections on every
    network interface this PC has, while a specific IP address of this
    PC (e.g. 192.168.1.50) restricts it to only the one network
    interface that address belongs to - useful if this PC has more than
    one network connection and you want to allow access from only one of
    them. A specific IP address only works reliably if it is fixed
    (statically assigned) on that network adapter, rather than handed
    out by DHCP and liable to change later. Only change this away from
    127.0.0.1 if you genuinely need another device to reach this
    account, and keep in mind the next point below once you do: from
    that point on, the local password is the only thing protecting that
    account.
  - Because the connection between your device and the proxy is not
    itself encrypted, only use a non-default "Local address" across a
    trusted local network - never across the open internet.
  - The log file records the sender, recipient(s) and subject line of
    every e-mail relayed through the proxy (not the message body or any
    attachments) - useful for troubleshooting, but worth knowing if the
    log file's contents matter to you from a privacy point of view. The
    subject line is written as readable text, even if it was transmitted
    in encoded form (see section 10).
  - Passwords and sign-in tokens never appear in the log, not even at
    the most detailed LogLevel - login data is replaced by a note.
  - At most "MaxConnections" (default 5) devices can be connected at the
    same time (section 14). Further connections are refused before the
    program does any work for them, so a flood of connections - e.g.
    from a faulty device or a network scanner - cannot overload the PC.
  - Turning on "Autostart" (tray menu, Settings) adds a value to your own
    Windows user account's registry ("Run" key under HKEY_CURRENT_USER)
    pointing at this program's .exe - nothing system-wide, and nothing
    requiring administrator rights. Turning it off removes that value again.


===============================================================================
 12. SETTING UP AN OAUTH2 APP IN MICROSOFT ENTRA ID (Microsoft 365 / Outlook.com)
===============================================================================

You need to do this once per organization (not once per mailbox). You
need permission to register applications in your Microsoft Entra tenant -
ask your IT administrator if you are not sure, or if a step below asks
for admin consent you cannot grant yourself.

  1. Go to https://entra.microsoft.com and sign in.

  2. In the left-hand menu, go to Applications > App registrations, then
     click "+ New registration".

  3. Give it a name (e.g. "CCSMTPOAuth2Proxy"). Under "Supported account
     types", choose the option matching your situation - "Accounts in
     this organizational directory only" for a normal single-company
     setup is the most common choice.

  4. Under "Redirect URI", choose the platform "Public client/native"
     (sometimes shown as "Mobile and desktop applications") and enter:

         http://localhost

     (exactly this, with no port number - the proxy picks a free port
     for itself automatically on every sign-in).

  5. Click "Register". On the app's Overview page, note down the
     "Application (client) ID" and the "Directory (tenant) ID" - you
     will enter these into the Add Account window in this program.

  6. Go to "Authentication" in the left-hand menu of your new app. Under
     "Advanced settings", set "Allow public client flows" to Yes, then
     save. This is required for the browser-based sign-in this program
     uses without needing a client secret.

  7. This step is not always strictly required: when you sign in later,
     the browser will normally prompt you to consent to the SMTP.Send and
     offline_access permissions right there, without needing anything
     pre-configured here. However, many organizations restrict whether
     users are allowed to consent to permissions on their own - if that
     is the case here, the sign-in will fail unless an administrator has
     already approved the permissions in advance, which is what this step
     does. It also matches Microsoft's own recommended practice of
     declaring permissions here even when they are requested dynamically
     at sign-in. To do this: go to "API permissions", click "+ Add a
     permission", choose "Microsoft Graph", then "Delegated permissions",
     and add:

         SMTP > SMTP.Send
         OpenId permissions > offline_access

     If your organization requires admin approval for these permissions,
     click "Grant admin consent for [your organization]" (you may need
     an administrator to do this for you).

  8. Make sure "Authenticated SMTP" is actually allowed for the mailbox
     you want to send from. Many Microsoft 365 tenants disable this by
     default. An administrator can check and enable it per mailbox, or
     via an authentication policy, in the Exchange admin center.

You now have everything needed for the "Client ID" and "Directory
(tenant) ID" fields in this program (see section 7). The client secret
field can be left empty - this setup uses the PKCE sign-in method, which
does not need one. It is possible to use the non-PKCE method as well,
which does need a client secret, but this is not recommended.


===============================================================================
 13. SETTING UP AN OAUTH2 APP IN GOOGLE CLOUD CONSOLE (Gmail / Google Workspace)
===============================================================================

You only need to complete this setup once, not once per mailbox. A free
Google account is sufficient; no paid Google Cloud subscription is
required.

  1. Sign in to Google Cloud

     Go to https://console.cloud.google.com and sign in with your
     Google account.

  2. Create a Google Cloud project

     In the top bar, to the right of the Google Cloud logo, click the
     Project Picker, then select "New Project". Enter a recognizable
     project name, for example "Gmail-CCSmtpOAuthProxy". Alternatively,
     select an existing project that you want to use for
     CCSMTPOAuth2Proxy.

  3. Enable the Gmail API

     From the Google Cloud dashboard, open "APIs & Services" > "Library".
     Search for "Gmail API" and click "Enable".

     Enabling the Gmail API makes its Gmail-related OAuth scopes
     available in the scope selection interface. CCSMTPOAuth2Proxy
     itself sends mail through Google's standard SMTP service using
     OAuth2/XOAUTH2; it does not use the Gmail REST API to send
     messages.

  4. Configure the OAuth consent screen

     Open "Google Auth Platform". If this is the first time OAuth has
     been configured for the project, click "Get started". Enter the
     following information:
       - App name: a recognizable name, for example "CCSMTPOAuth2Proxy".
       - User support email: select your own e-mail address.
     Click "Next".

     Under "Audience", select:
       - "Internal" if you are using Google Workspace and the
         application will only be used by accounts within your own
         organization.
       - "External" for a personal Gmail account, or if accounts outside
         your own Google Workspace organization need to use the
         application. A user with a regular free @gmail.com account
         should select "External".

     Under "Contact information", enter your e-mail address again.
     Accept the required agreement and click "Create".

  5. Create an OAuth client

     In the Google Auth Platform menu, open "Clients" and click "Create
     Client". Select Application type: "Desktop app". Enter a
     recognizable name, for example "CCSMTPOAuth2Proxy", and create the
     client.

     Google will display a Client ID and a Client secret - copy and
     save both values. You will need them later when configuring the
     Google account in CCSMTPOAuth2Proxy.

  6. Add the Gmail OAuth scope

     Open "Google Auth Platform" > "Data Access" and click "Add or
     remove scopes". Add the following scope:

         https://mail.google.com/

     This is the OAuth scope Google specifies for IMAP, POP and SMTP
     access using OAuth2/XOAUTH2. It is classified as a Restricted
     Scope.

     Google normally requires verification for applications using
     restricted scopes. However, Google provides an exception for
     personal use: if you are the only user of the application, or it
     is used only by a small number of people personally known to you,
     you do not need to submit the application for verification. An
     unverified-app warning will be shown during sign-in instead. Save
     the changes.

  7. Add a test user

     If the application's Publishing status is still set to "Testing",
     open "Google Auth Platform" > "Audience" and add the Gmail account
     that CCSMTPOAuth2Proxy will use under "Test users".

     If Google displays "Ineligible accounts not added [...]", check
     whether the intended Gmail account is actually shown in the Test
     users list. The message can only be ignored if the required
     account has been added successfully.

  8. Set the publishing status

     For an External application in Testing status, Google limits
     authorizations and refresh tokens to seven days when scopes such
     as https://mail.google.com/ are used. After that, a new
     interactive sign-in would be required.

     For continuous operation of CCSMTPOAuth2Proxy, open "Google Auth
     Platform" > "Audience" and change the Publishing status to "In
     production". This removes the special seven-day expiration
     associated with Testing mode. Access tokens will still expire
     normally, but CCSMTPOAuth2Proxy can obtain new access tokens using
     the stored refresh token as long as that refresh token remains
     valid.

     For personal use, you can leave the application unverified. Google
     will display an unverified-app warning and apply a user cap. An
     External application in production is no longer restricted to the
     accounts previously listed as Test users.

  9. Sign in to Google

     Return to CCSMTPOAuth2Proxy and enter the generated Client ID and
     Client secret. Leave the "Directory (tenant) ID" field empty - this
     setting is only used for Microsoft accounts. Save the account and
     start the Google sign-in process.

     Google asks for your consent on every sign-in through this program -
     that is intended: only then does Google issue a new refresh token,
     which the program needs to keep sending without further sign-ins.

     When using an External, unverified application, Google may display
     "Google hasn't verified this app". This is expected for a personal
     application that has not been submitted for verification. Click
     "Advanced", then "Go to [your app name] (unsafe)" to continue and
     grant your Google account access to the application.

     Once the sign-in has completed successfully, CCSMTPOAuth2Proxy can
     use the OAuth refresh token to obtain new access tokens
     automatically when required.


===============================================================================
 14. ADVANCED SETTINGS (INI FILE)
===============================================================================

The program stores its configuration in CCSMTPOAuth2Proxy.ini, next to the
program itself. Account settings are edited through the program's own
windows (see sections 6-8); the general settings live under the
"[General]" section of that file (the notification settings are in
"[Notify]", see section 15). Most of them can be changed in the
tray menu under Settings -> Advanced (section 5) - the change is used
right away, no restart needed. A few low-level ones (MainLoopTickMs,
AcceptCheckIntervalMs, RelayPollMs, TcpTimeoutMs) are deliberately not
in that window and can only be changed by editing the file directly,
then restarting the program. None of these need to be touched for
normal use - the defaults are sensible - but they are documented here in
case you do want to tune them (in the "Advanced" window, times are
shown in seconds; in the INI file, settings ending in "Ms" are in
milliseconds):

  ClearLogOnStart          (default 1) Clear the log file every time
                             the program starts, instead of appending to
                             it. Older parts (.1.log, .2.log ...) are kept.
                             (The former setting "ClearRelayLogOnStart"
                             is no longer used since there is only one
                             log; if it is still in your INI file, it is
                             ignored and can be deleted by hand.)
  AuthPortStart            (default 8462) The first port tried when
                             picking a free local port for the OAuth2
                             sign-in redirect. Change this only if that
                             range conflicts with something else on your
                             PC.
  SmtpPortStart            (default 1587) The first port suggested when
                             adding a new account - just a starting
                             point for the suggestion, not a limit.
  UseLogFile               (default 1) Whether the program writes to its
                             log file at all. Console output (only
                             visible when running the raw script, not the
                             compiled .exe) is unaffected by this.
  LogLevel                 (default 5 compiled, always 9 when running the
                             raw script - see below) How much detail goes
                             into the log file:
                             0-5 = normal operation: start/stop,
                             connections with their summary, sign-in
                             results, e-mails relayed, token refreshes,
                             warnings and errors (including "Helper
                             error" lines) - always logged.
                             6 = in addition every SMTP command
                             (passwords and tokens are always hidden)
                             and the normal "Helper" lines of the
                             PowerShell helpers (section 10).
                             8 = in addition timing information for where
                             the time goes when sending an e-mail
                             (obtaining a sign-in token, the XOAUTH2
                             exchange, the client uploading the message,
                             the server acknowledging it) - see the
                             "Timing: ..." lines in section 10.
                             9 = everything (debug).
                             Raise it only for troubleshooting - the log
                             grows much faster. In Settings -> Advanced
                             the change applies at once; after editing
                             the INI file by hand, restart the program.
                             This setting is only read from the INI when
                             running the compiled .exe - the raw script
                             always uses level 9 regardless of what is
                             saved here, so the two do not interfere with
                             each other if you use both at different
                             times.
  AcceptCheckIntervalMs    (default 200) How often, in milliseconds, the
                             program checks for new incoming connections.
  MainLoopTickMs           (default 5) The longest the program's main
                             loop ever waits before checking again when
                             there is nothing to do - while a connection
                             is actively relaying data, the loop does not
                             wait at all, so this mainly affects how
                             quickly the program notices something new
                             (a fresh connection, a tray click) during an
                             otherwise quiet moment.
  RelayPollMs              (default 2) Same idea as MainLoopTickMs, but
                             inside the PowerShell helper process that
                             handles each connection's actual data
                             transfer.
  StallWatchdogMs          (default 15000) How long a connection may take
                             to sign in before a one-time warning is
                             logged (see section 10).
  IdleWatchdogMs           (default 120000) How long an already
                             signed-in connection may sit idle before a
                             (repeatable) note is logged (see section 10).
  AuthRedirectTimeoutSec   (default 180) How long the program waits for
                             you to finish signing in in the browser
                             before giving up.
  HttpTimeoutMs            (default 15000) Timeout used for the
                             background calls this program makes to
                             Microsoft/Google to obtain or refresh a
                             sign-in token.
  ProactiveRefreshLeadSec  (default 600) How long before a sign-in token
                             actually expires the program refreshes it in
                             the background, ahead of time, rather than
                             waiting until a device connects and needs
                             one right away.
  LoopBlockWarnMs          (default 3000) If the program was blocked for
                             longer than this many milliseconds, a
                             "Warning: the main loop was not serviced"
                             line is logged (section 10). 0 turns it off.
  PreAuthTimeoutMs         (default 60000) A connection that has not
                             completed its login after this many
                             milliseconds is closed. 0 = never.
  AuthResultTimeoutMs      (default 20000) If the mail server has not
                             answered the proxy's sign-in (OAuth2/
                             XOAUTH2) after this many milliseconds, the
                             device gets a temporary error (454) and the
                             connection is closed (section 10, "The
                             login hangs"). Keep it below the device's
                             own timeout (often 30 s). 0 = never.
  IdleCloseMs              (default 600000) A signed-in connection with
                             no data in either direction for this many
                             milliseconds is closed (Microsoft itself
                             closes idle connections after about 10
                             minutes). 0 = never.

  MaxConnections           (default 5) At most this many devices can be
                             connected to the proxy at the same time; a
                             further connection is refused at once with
                             "421 too many connections", before anything
                             else happens (no helper process is started, no
                             connection to the mail server is made). This
                             protects the PC against a flood of connections,
                             e.g. from a faulty device or a network scanner.
                             Normal devices simply try again a little later.
                             0 = no limit.

  RelayDebugLog            (default 0) 1 = the PowerShell helper also
                             writes a "Helper" line into the log for
                             every chunk of data it relays (visible with
                             LogLevel 6 or higher). Only for
                             troubleshooting: for a large e-mail that
                             means hundreds of lines (one per 64 KB). A
                             test with a 5 MB e-mail showed no measurable
                             slowdown.
                             With 0, the helper only logs start, connection,
                             TLS, errors and the end of each connection
                             (including how many bytes went each way) -
                             errors always, the rest at LogLevel 6.

  TcpTimeoutMs             (default 0) How long, in milliseconds, each
                             check for a new connection or for data from a
                             device may wait when nothing is there. AutoIt
                             itself uses 100 here, and up to version 36 this
                             program did too - because the program does one
                             thing at a time, every one of these waits held
                             up everything else (about 240 ms extra per SMTP
                             command, large e-mails at only about 1 MB/s).
                             0 = do not wait. Only change this for a
                             comparison test (100 = old behaviour). The
                             current value is written to the log right
                             after the "started" line.

  MaxLogSizeMB             (default 10) When the log reaches this size
                             (checked about once a minute), it is renamed
                             to ...1.log and a new file is started.
                             0 = never rotate (the file then grows
                             without limit).
  LogGenerations           (default 5) How many older parts of the log
                             are kept (...1.log is the newest, ...5.log the
                             oldest; anything older is deleted).

These settings are added to an existing INI file automatically, with
their default values, the first time this version starts.

A note on proxies: the sign-in token is renewed via Windows' WinHTTP
service, which does NOT use the proxy configured in your browser. If
your network only reaches the internet through a proxy, the sign-in in
the browser works but the token renewal fails ("Token refresh failed
... HTTP 0" in the log). Show the current WinHTTP setting with
"netsh winhttp show proxy"; copy the browser's setting over (in an
administrator command prompt) with "netsh winhttp import proxy
source=ie", or set one with "netsh winhttp set proxy <host>:<port>".

Every number above is checked when the program starts. A value that is
not a whole number, or lies outside a sensible range (for example 0 for
HttpTimeoutMs, which would mean "wait forever"), is replaced by its
default, and a "Warning: INI setting [General] ..." line in the log says
so. Only LoopBlockWarnMs, PreAuthTimeoutMs, AuthResultTimeoutMs,
IdleCloseMs, MaxConnections and MaxLogSizeMB accept 0, to switch that
function off; for
RelayDebugLog and TcpTimeoutMs, 0 is the normal value.


-------------------------------------------------------------------------------
 15. NOTIFICATIONS (ntfy, webhook, command, heartbeat)
-------------------------------------------------------------------------------

The program can tell you by itself when something is wrong - for example
when an account needs a new sign-in and the devices using it can no
longer send. Everything is set up in the tray menu under Settings ->
Notifications. Every field there explains itself when you hover over it,
and every channel has a "Test" button that sends a test message with the
values currently in the window (no need to save first); the result is
shown at the bottom of the window and written to the log. "Save" uses the
new settings right away, "Cancel" (or the X) discards all changes.

E-mail is deliberately NOT one of the channels: in the most important
case - the sign-in has expired - the proxy cannot send e-mail itself.

Four channels can be switched on independently of each other:

  ntfy        Push messages to the phone (ntfy app) - the simplest way.
  Webhook     An HTTPS POST with a JSON text to a service of your choice:
              Microsoft Teams, Slack, Discord, Mattermost, Home Assistant,
              n8n, Node-RED, Zapier/Make, SMS gateways with an HTTP API ...
  Command     Runs a program or script of your own for every message.
  Heartbeat   Works the other way round: the proxy calls a ping address
              regularly, and a monitoring service raises the alarm when the
              pings stop - see 15.4. This is the only way to hear about a
              proxy that has crashed, hangs or runs on a PC that is off.

These events are reported (each can be switched off; all are on by
default):

  Sign-in required         An account needs a new sign-in (revoked,
                           expired, password changed) - and at the start
                           of the program for every active account that
                           has no sign-in yet.
  Token renewal failed     The access token could not be renewed twice in
                           a row (a single failure is often just a short
                           hiccup at Microsoft/Google and is not
                           reported).
  E-mail refused           The real mail server did not accept an e-mail
                           (with sender, recipient, subject and the
                           server's reply - e.g. "Send As" not allowed,
                           section 9).
  Repeated errors          Three error answers of the mail server (or
                           sign-ins it did not answer) for the same
                           account within 15 minutes.

"E-mail refused" and "Repeated errors" only count e-mail relayed for your
devices and programs. The test e-mail (section 9) and "Test Connection"
(section 6) do NOT trigger them: you see their result in the window
anyway, and a test that fails on purpose (e.g. to check a "Send As"
permission) must not use up the rate limit - otherwise a real refusal
shortly afterwards would not be reported - nor lead to a misleading "OK
again" message later. "Sign-in required" and "Token renewal failed" can
also be triggered during a test, though: they describe the state of the
account, which affects normal operation just the same.
  Proxy blocked            Nothing could be accepted or relayed for at
                           least the given number of seconds (default 60;
                           sent when the block is over; not for a standby
                           of the PC). Needs "Warning: main loop blocked
                           for" in Settings -> Advanced to be on.
  Proxy started / stopped  When the program starts and when it is ended
                           via Exit.

"OK again" messages: when a problem that was reported is gone again (the
account is signed in again, the token was renewed, an e-mail was
accepted), a short "OK again: ..." message follows, so you know the
problem is solved. Can be switched off.

Rate limit: the same event for the same account is sent at most once in
"Same message at most every" minutes (default 60, 0 = no limit), so a
disruption at the provider does not flood your phone. Once a problem has
been reported as solved, its next occurrence is reported at once again.

How it works (and why it never slows down the e-mail): the proxy only
decides that a message is due. The sending itself is done by a second,
short-lived copy of this program ("CCSMTPOAuth2Proxy.exe /notify ...")
that runs hidden in the background and ends by itself, so a slow or
unreachable notification server never holds up the relaying. Its result
appears in the normal log:

  Notification queued (ntfy,webhook, PID 4711): Sign-in required (x@y) - ...
  Notification [reauth (x@y) | PID 4711]: ntfy: sent to ntfy.sh (HTTP 200)
  Notification error [reauth (x@y) | PID 4711]: webhook: ... answered HTTP 404 - ...

Webhook and ping URLs and the ntfy access token work like passwords:
they are stored encrypted in the INI file (like every other secret of
this program, section 11) and never written to the log - only the server
name is.

Note that the messages contain account names and, for a refused e-mail,
sender, recipient and subject. Keep that in mind when choosing a public
service (see the note on ntfy topics below).


 15.1 ntfy - push messages to the phone
 --------------------------------------

ntfy (https://ntfy.sh) is a free push service. On the public server
ntfy.sh no account and no registration are needed:

  1. Install the ntfy app on the phone (Android: Google Play or F-Droid;
     iPhone: App Store). On a PC, the web page https://ntfy.sh/app works
     too.
  2. Open Settings -> Notifications. As long as no topic has been saved,
     the "Topic" field already contains a suggestion: CCSMTPOAuth2Proxy-
     plus 8 random letters and digits (e.g. CCSMTPOAuth2Proxy-k7Qm2xPa).
     Anyone who knows the name of a topic on ntfy.sh can read its
     messages, so the name must not be guessable - the suggestion is
     (you can also enter a name of your own: letters, digits, - and _).
     The suggestion stays the same until the program is restarted, so you
     can close the window in between.
  3. In the app, tap "+" (Subscribe to topic) and enter exactly this topic
     name (upper/lower case matters). Leave "Use another server" off for
     ntfy.sh.
  4. Back in the window: tick "Send notifications via ntfy" (Server
     https://ntfy.sh), click "Test" - the test message should appear on
     the phone within seconds. Then "Save" - only now is the topic stored.

Problems are sent with high priority (the phone plays a sound even in
"quiet" notification settings, depending on the app's settings), "OK
again" and start/stop messages with normal priority.

Protected topics (optional): if the messages should not be readable by
anyone who guesses the topic, use your own ntfy server with user accounts
or a reserved topic of a paid ntfy.sh plan. Create an access token in the
ntfy web app (Account -> Access tokens, it starts with "tk_") and enter
it in "Access token". With your own server, enter its address as
"Server" (e.g. https://ntfy.example.com) - in the app, use "Use another
server" with the same address.


 15.2 Webhooks - Teams, Slack, Discord, Home Assistant and others
 ----------------------------------------------------------------

A webhook is an internet address of a service that accepts messages: the
service gives you the address (URL), the proxy sends every message there
as an HTTPS POST with a short JSON text. Which JSON the service expects
differs - the "Format" list fills in the right template for the common
ones; you can adjust it afterwards. General steps:

  1. Create the webhook in the service and copy its URL (see below).
  2. In Settings -> Notifications: tick "Send notifications to a webhook",
     paste the URL, choose the matching "Format", click "Test", then
     "Save".

The webhook URL is effectively a password - whoever has it can post into
your channel. If it ever gets out, delete the webhook in the service and
create a new one.

Microsoft Teams (Workflows):
  The old "Incoming Webhook" connectors of Microsoft 365 have been
  retired; Teams uses "Workflows" (Power Automate) for this now.
  1. In Teams, open the channel (or chat) that should receive the
     messages, click "..." next to its name -> "Workflows" (or open the
     Workflows app).
  2. Choose the template "Send webhook alerts to a channel" (in some
     tenants: "Post to a channel when a webhook request is received").
  3. Select the team and channel, click "Save". The details page then
     shows the webhook URL - copy it.
  4. Format: "Microsoft Teams (Workflows)" (an Adaptive Card with the
     headline, the message and the time).
  The workflow runs under the account that created it; if that account
  is removed, the messages stop. Teams answers HTTP 202 - that is a
  success.

Slack:
  1. https://api.slack.com/apps -> "Create New App" -> "From scratch",
     choose the workspace.
  2. "Incoming Webhooks" -> switch on -> "Add New Webhook to Workspace",
     choose the channel -> copy the URL (https://hooks.slack.com/...).
  3. Format: "Slack / Mattermost / Rocket.Chat".
  (Mattermost and Rocket.Chat: create an "Incoming Webhook" in the
  integrations of the server; same format.)

Discord:
  1. Server settings (or the channel's settings) -> "Integrations" ->
     "Webhooks" -> "New Webhook", choose the channel.
  2. "Copy Webhook URL".
  3. Format: "Discord".

Home Assistant:
  1. Create an automation with the trigger "Webhook". Home Assistant
     shows a webhook ID; the URL is
     https://<your Home Assistant>/api/webhook/<webhook ID>
     (from outside your network only if Home Assistant is reachable from
     there, e.g. via Nabu Casa; for the proxy on the same network, the
     local address works).
  2. Format: "All fields". In the automation's actions the values are
     available as {{ trigger.json.title }}, {{ trigger.json.message }},
     {{ trigger.json.account }}, {{ trigger.json.event }} etc. - e.g. for
     a notification to the Home Assistant app.

n8n, Node-RED, Zapier, Make and similar:
  Create a "Webhook" start node/trigger (method POST), copy its URL,
  Format "All fields". The JSON then contains these fields: text (a ready
  one-line message), title, message, event, account, time, host, app.

Placeholders in the template (inserted JSON-safe, so quotes or line
breaks in a value cannot break the JSON):

  {headline}  "<program> (<PC name>): <title>"
  {title}     e.g. "Sign-in required"
  {message}   "<account>: <description>" (only the description if no
              account is involved)
  {text}      the description only
  {account}   the account, or empty
  {event}     a short code: reauth, refreshfail, refused, errors,
              loopblock, start, stop, clear_<code> (the "OK again"
              message for a problem), test
  {time}      local time, YYYY-MM-DD hh:mm:ss
  {host}      the PC's name
  {app}       the program's name

A success is any HTTP answer from 200 to 299; anything else is logged as
"Notification error" with the service's answer.


 15.3 Command - your own program or script
 -----------------------------------------

For everything that has no channel of its own (Signal via signal-cli, a
monitoring agent, a mail tool that sends through another server, a
script that writes into a ticket system ...). The command line is run
hidden through cmd.exe, with the same placeholders as the webhook
template, for example:

  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\notify.ps1 "{event}" "{message}"

Characters that the command line would interpret (< > | & ^ % and ") are
removed from the inserted values, so a value can never turn into a
command of its own. The unchanged values are available to the program as
environment variables: CCSMTP_EVENT, CCSMTP_TITLE, CCSMTP_HEADLINE,
CCSMTP_TEXT, CCSMTP_MESSAGE, CCSMTP_ACCOUNT, CCSMTP_TIME, CCSMTP_HOST
(in PowerShell e.g. $env:CCSMTP_MESSAGE). Exit code 0 counts as success;
the program waits at most 30 seconds for it (a command still running
after that is left alone, and the log says so). The command runs under
the same Windows user as the proxy.


 15.4 Heartbeat - an alarm when the proxy itself stops working
 -------------------------------------------------------------

All other channels need a working proxy. If it has crashed, hangs, or
the PC is off or offline, it cannot report anything any more. The
heartbeat solves this: the proxy calls a "ping URL" of a monitoring
service every few minutes (default 5) - but only while its main loop is
really running. If the pings stop, the SERVICE raises the alarm (by
e-mail, app, SMS, Teams, ntfy ... - configured there).

Set the check's period at the service to the same interval as in the
proxy, and the grace time to at least as much again (e.g. 5 minutes
period, 10 minutes grace) - the tray menu pauses the program while it is
open (section 10), and a single ping can be lost on the way.

Note: a regular stop via Exit or a shutdown of the PC also stops the
pings and therefore leads to an alarm after period + grace time. Pause
the check at the service before planned maintenance, if you like.

healthchecks.io (free plan for a small number of checks):
  1. Sign up at https://healthchecks.io (an e-mail address is enough).
  2. "Add Check": name e.g. "SMTP proxy <PC name>", "Period" 5 minutes,
     "Grace Time" 10 minutes.
  3. Copy the ping URL of the check - https://hc-ping.com/<uuid>.
  4. Under "Integrations", choose how you want to be alerted (e-mail is
     set up already; others: Teams, Slack, Telegram, ntfy, SMS ...).
  5. In Settings -> Notifications: tick "Send a regular ping
     (heartbeat)", paste the URL, interval 5, click "Test" - the check at
     healthchecks.io changes to "up" - then "Save".
  (healthchecks.io can also be run on your own server - the software is
  open source.)

Uptime Kuma (your own monitoring server):
  1. "Add New Monitor", Monitor Type "Push", a name.
  2. Heartbeat Interval e.g. 360 seconds (a little more than the
     proxy's 5 minutes), retries as you like.
  3. Copy the Push URL - it looks like
     https://kuma.example.com/api/push/<token>?status=up&msg=OK&ping=
     and paste it unchanged.
  4. Set up the notification (e-mail, Teams, ntfy, ...) in Uptime Kuma.

Better Stack, Cronitor, PRTG, Zabbix, Checkmk and others offer the same
under names like "heartbeat", "push monitor", "HTTP push sensor" or
"passive check": wherever you get an address that is called regularly
(GET) and that raises an alarm when the calls stop, it works with this.

Successful pings are only written to the log at LogLevel 6 (otherwise
there would be a line every five minutes); a failed ping is always
logged.


 15.5 Settings in the INI file
 -----------------------------

All of this is stored in the [Notify] section of CCSMTPOAuth2Proxy.ini
and is normally only changed in the Notifications window:

  NtfyEnabled, NtfyServer (https://ntfy.sh), NtfyTopic, NtfyTokenEnc
  WebhookEnabled, WebhookUrlEnc, WebhookTemplate
  CommandEnabled, Command
  HeartbeatEnabled, HeartbeatUrlEnc, HeartbeatIntervalMin (5, 1-1440)
  MinIntervalMin (60, 0-1440), LoopBlockSec (60, 10-3600), AllClear (1)
  EventReauth, EventRefreshFail, EventRefused, EventErrors,
  EventLoopBlock, EventStartStop (all 1 = on)

The keys ending in "Enc" are encrypted (Windows DPAPI, readable only by
the same Windows user on the same PC) - they cannot be typed into the
INI file by hand; use the window for them.


-------------------------------------------------------------------------------
 16. ROADMAP (POSSIBLE FUTURE CHANGES)
-------------------------------------------------------------------------------

Ideas and planned improvements that have been discussed but are not done
yet - kept here, in one place, and updated with every version. Nothing
here is a promise; most items only become worth doing if the problem
they solve actually shows up. The short codes in brackets (C6, L1, ...)
are the names under which the items are referred to in the program's
comments. The effort is a rough estimate including tests.

1. Deferred
   1.1 Token renewal without stopping the proxy (C6). Renewing the access
       token is a short HTTPS request that normally takes about 0.3 s -
       during that time the proxy relays nothing. During the Microsoft 365
       disruption of 12/13 Nov 2026 it took 5.9 s and 12.3 s. Possible
       solutions: an asynchronous WinHTTP request polled from the main
       loop, or the renewal done by a short-lived separate process (like
       the notification sender) that hands the new tokens back. The
       interactive sign-in stays as it is. Effort: 2-3 h.
   1.2 Splitting the program into a Windows service and a tray program
       (L1). The proxy itself (accepting, relaying, token renewal, log,
       notifications) would run as a Windows service - without a tray menu
       and without windows, so nothing in the user interface could ever
       pause the relaying again, and it would also run without anyone
       signed in to Windows. A separate tray/settings program would only
       control it and show its status, and would run the browser sign-in.
       Open points: the encrypted secrets must be readable by the service
       account, settings changes must reach the running service, and the
       tokens must be handed over after a sign-in. Effort: about 15-25 h.
   1.3 A test with many e-mails sent quickly one after the other and at
       the same time. Effort: 1-2 h.
   1.4 PowerShell execution policy set by Group Policy (F2). A policy such
       as "AllSigned" overrides the "-ExecutionPolicy Bypass" the program
       uses and stops the helper (section 10 describes what an
       administrator can do today). Possible solutions: pass the helper
       script via -EncodedCommand instead of as a file, or ship it as a
       fixed, code-signed .ps1 (today it is rewritten on every start, so a
       signature would not survive). Effort: 2-4 h.
   1.5 Encryption towards the devices (G4): local STARTTLS with a
       certificate of its own, for devices that only send encrypted.
       Effort: 4-6 h.
   1.6 Automatic second sign-in attempt (O3). If the mail server does not
       answer the XOAUTH2 sign-in within about 12 s (seen during the
       Microsoft 365 disruption of 12 Nov 2026; a retry by hand worked at
       once), start a second connection in the background, sign in there
       and switch the waiting device over to it - about 16 s in total,
       well inside a device's usual 30 s timeout. Only worth it if such
       hangs happen more often (the log shows them clearly: "did not
       answer the sign-in"). Effort: 2-3 h.
   1.7 Additions to the notifications (section 15):
       1.7.1 Telegram as a further channel (bot token + chat ID).
             Effort: 0.5-1 h.
       1.7.2 A "fail" signal to the heartbeat service on a regular stop
             (Exit), so the service reports it at once instead of only
             after period + grace time. Effort: about 0.5 h.
   1.8 Installation via winget, the package manager built into Windows
       ("winget install CITRO.CCSMTPOAuth2Proxy", and later "winget
       upgrade" for updates). This needs a small description file (a
       "manifest") submitted to Microsoft's public winget repository
       (github.com/microsoft/winget-pkgs); it points to the ZIP of the
       GitHub release, so nothing else has to be hosted. The manifest is
       checked automatically and by Microsoft before it is accepted - the
       code signature of the .exe helps there. Every new release then
       needs an updated manifest (can be automated, e.g. with
       "wingetcreate update"). Note: winget installs the program into a
       folder of its own, which must stay writable for the INI file and
       the log (section 2). Effort: 1-2 h, plus the review by Microsoft.

2. Performance (good at the moment - only if problems show up again)
   2.1 Greet the device and answer its EHLO locally and at once, while the
       helper starts in parallel (G1; the helper start takes about 1 s
       today). Effort: 2-3 h.
   2.2 Start the helper only after the local password check (G2, builds
       on 2.1) - connections that never sign in would then cost almost
       nothing. Effort: 1-2 h.
   2.3 Keep one helper started in advance, connected and ready (G3), so a
       new connection does not wait for PowerShell to start (measured:
       about 0.8 s of the ~2.3 s of a small e-mail). Effort: 3-4 h.
   2.4 During an interactive sign-in, the program reads the browser's
       answer in a short inner loop that does not relay (G5) - up to 2 s
       per browser request. Solved by 1.2 anyway. Effort: 0.5-1 h.
   2.5 Measure where the remaining ~31 ms per 64 KB block of a large
       e-mail go (I1; today 5 MB take about 6 s). Effort: 1-2 h.
   2.6 Set the Windows timer resolution to 1 ms at the start (I2), if 2.5
       shows that the 31 ms are two steps of the standard 15.6 ms timer.
       Effort: about 0.5 h.


===============================================================================
 END OF README
===============================================================================

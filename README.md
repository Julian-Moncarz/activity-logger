# Activity Logger

A tiny macOS app that logs what's in front of you (app, window title, Chrome tab) to
`~/personal-tools/data/activity-logger/YYYY-MM-DD.jsonl.enc`. Raw data only, for analyzing
later (for example by pasting a week of logs into Claude).

- **Logs are encrypted on disk.** Nothing is stored as plain text. Reading them back takes one
  command and Touch ID (or your password).
- **You choose which Chrome profile is logged.** Windows of any other profile, and Incognito
  windows, are recorded as "Google Chrome" with no title and no URL.
- **Nothing leaves your Mac.** There is no network code.

## Install

Needs macOS 14+, a Mac with a Secure Enclave (Apple silicon, or Intel with a T2 chip) and the
Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/Julian-Moncarz/activity-logger.git
cd activity-logger && ./install.sh
```

The installer creates the encryption key, asks which Chrome profile to log, encrypts any
plain-text logs from an earlier version, and starts the logger (it also starts at login). Then
allow **Accessibility** when prompted (for window titles, which is also how the Chrome profile
is recognized), and click OK when asked to let it control Chrome (for tab URLs).

Uninstall with `./uninstall.sh` (your encrypted logs and their key are kept).

## Reading your logs

```bash
activity-logger export --days 7 --copy
```

Approve with Touch ID, then paste into Claude. The clipboard copy is hidden from clipboard
managers, isn't shared with your other Apple devices, and is cleared after two minutes.
Other ranges are `--from 2026-11-01 --to 2026-11-07` and `--all`.

Without `--copy` the rows print to the terminal, so `activity-logger export --days 7 > week.jsonl`
writes a plain-text file if you want one. Delete it afterwards, since that file is no longer
protected.

In Claude Code you can ask Claude to run `activity-logger export --days 7` and analyze the
result. You get the Touch ID prompt, so nothing is decrypted without you. The decrypted rows
then sit in that session's transcript on your Mac, in plain text.

If `activity-logger` isn't found, use the full path `~/.local/bin/activity-logger`.

## Choosing the Chrome profile

```bash
activity-logger profiles
```

```bash
activity-logger set-profile 2
```

`set-profile` takes the number from the list, the profile's name, its email or its domain
(`set-profile example.org`). `set-profile --all` logs every profile. Changes apply within a
second, with no restart.

How it works: when you have more than one profile, Chrome ends each window's title with the
profile's name ("Inbox - Google Chrome - Work"). The logger reads that label and only logs a
window whose label belongs to the chosen profile. When it can't tell, it records Chrome
without details instead of guessing. That covers:

- another profile, a Guest window or an Incognito window (Incognito is withheld in every mode)
- no profile chosen yet (with more than one profile, nothing in Chrome is logged until you choose)
- no Accessibility permission, so the title can't be read
- Chrome Beta, Chrome Canary and web apps installed from Chrome
- a profile that was renamed so that two profiles could show the same label

If your chosen profile shows up as `"private": true` in the logs, run `activity-logger status`.
It says which labels it accepts and what it has seen. If Chrome names your profile differently,
add that label with `activity-logger set-profile --label "<label>"`.

Limits worth knowing:

- Other browsers (Safari, Arc, Firefox, Brave, Edge) are not filtered. Their window titles,
  which usually contain the page title, are logged like any other app's, private windows
  included.
- The profile label comes from Accessibility and the URL from Chrome's scripting. The logger
  checks that both describe the same window before keeping a URL, and drops the URL when they
  don't.

## How the encryption works

- `setup` creates a key pair for the logs. The **public** key goes in `config.json` next to the
  logs. The logger only has that, so it can add rows but can't read any back.
- The **private** key is stored only in wrapped form, in `key.json`. It is encrypted to a second
  key that lives inside this Mac's Secure Enclave, and the Enclave refuses to use that key
  without Touch ID or your login password. The check is done by the hardware, not by this
  program, so another program can't skip it.
- Each row is sealed on its own (HPKE with X25519, HKDF-SHA256 and ChaCha20-Poly1305, from
  Apple's CryptoKit), bound to its day, padded so its size gives little away, and written as
  one base64 line.
- The logs can only be decrypted on this Mac. If you erase it, replace its logic board, or
  delete `key.json`, they can't be read. Backups of the folder are safe to keep for the same
  reason, and useless on another machine.
- `errors.log` in the same folder stays plain text. It holds notes from the logger and, at
  most, the names of your Chrome profiles, never titles or URLs.

What it does not protect against: a program already running as you can replace the app, edit
`config.json` so that future rows are sealed to a key of its own, add or delete rows, or read
the rows while you export them. It can't read what is already on disk without your Touch ID.
The app is signed ad hoc, without the hardened runtime.

## Output

Each row is a stretch of time where nothing changed: `start`, `end`, `duration_s`,
`status` (`active`, `idle`, `locked`, `asleep`), `app`, `bundle_id`, `window_title`, `url`,
`tab_title`, `private`. Example of exported rows:

```json
{"app":"Google Chrome","bundle_id":"com.google.Chrome","duration_s":42.3,"end":"2026-10-16T09:14:42.300-04:00","private":false,"start":"2026-10-16T09:14:00.000-04:00","status":"active","tab_title":"Hacker News","type":"segment","url":"https://news.ycombinator.com/","window_title":"Hacker News - Google Chrome - Work"}
{"app":"Google Chrome","bundle_id":"com.google.Chrome","duration_s":118.0,"end":"2026-10-16T09:16:40.300-04:00","private":true,"start":"2026-10-16T09:14:42.300-04:00","status":"active","tab_title":null,"type":"segment","url":null,"window_title":null}
{"app":"Notes","bundle_id":"com.apple.Notes","duration_s":300.0,"end":"2026-10-16T09:21:40.300-04:00","private":false,"start":"2026-10-16T09:16:40.300-04:00","status":"idle","tab_title":null,"type":"segment","url":null,"window_title":"Grocery list"}
```

## Tests

`./build.sh && build/ActivityLogger.app/Contents/MacOS/ActivityLogger selftest` checks the
encryption round trip, the key wrapping and the profile-label matching. It runs without any
prompt. `ACTIVITY_LOGGER_DIR` points the app at another log folder, and
`ACTIVITY_LOGGER_NO_PROMPT=1` stops the logger from asking for Accessibility, both for trying
things out without touching your own logs.

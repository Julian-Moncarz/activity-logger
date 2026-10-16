# Activity Logger

A tiny macOS app that logs what's in front of you (app, window title, Chrome tab) to
`~/ActivityLog/YYYY-MM-DD.jsonl`. Raw data only, for analyzing later (for example by
pasting a week of logs into Claude).

## Install

Needs macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/Julian-Moncarz/activity-logger.git
cd activity-logger && ./install.sh
```

Then allow **Accessibility** when prompted (for window titles), and click OK when asked to
let it control Chrome (for tab URLs). It starts at login.

Uninstall with `./uninstall.sh` (your logs are kept).

## Output

Each line is a stretch of time where nothing changed: `start`, `end`, `duration_s`,
`status` (`active`, `idle`, `locked`, `asleep`), `app`, `bundle_id`, `window_title`, `url`,
`tab_title`. Example:

```json
{"app":"Google Chrome","bundle_id":"com.google.Chrome","duration_s":42.3,"end":"2026-10-16T09:14:42.300-04:00","start":"2026-10-16T09:14:00.000-04:00","status":"active","tab_title":"Hacker News","type":"segment","url":"https://news.ycombinator.com/","window_title":"Hacker News - Google Chrome"}
{"app":"Notes","bundle_id":"com.apple.Notes","duration_s":118.0,"end":"2026-10-16T09:16:40.300-04:00","start":"2026-10-16T09:14:42.300-04:00","status":"active","tab_title":null,"type":"segment","url":null,"window_title":"Grocery list"}
{"app":"Notes","bundle_id":"com.apple.Notes","duration_s":300.0,"end":"2026-10-16T09:21:40.300-04:00","start":"2026-10-16T09:16:40.300-04:00","status":"idle","tab_title":null,"type":"segment","url":null,"window_title":"Grocery list"}
```

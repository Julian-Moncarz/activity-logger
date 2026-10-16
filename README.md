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
`tab_title`.

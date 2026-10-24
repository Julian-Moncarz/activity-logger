# Activity Logger

How to analyze the Activity Logger's logs: the rules any analysis must follow, and lessons learned. The logs are one file per day in `~/personal-tools/data/activity-logger/YYYY-MM-DD.jsonl` (source, install and log format in `README.md` here). Moved here from `data/activity-logger/CLAUDE.md` on 2026-10-24 so changes have git history.

## Analyzing the logs

- **Always classify by window title and tab title (and URL), never by app name alone.**
  The app name says almost nothing about whether time was on-task. Julian, 2026-10-02:
  time "in Claude" included building the TAISI website in Claude Design (a non-work
  project), and time "in Chrome" includes both work tools and shopping or reading.
  Group by `(app, window_title)` for native apps and by `(domain, tab_title)` for Chrome
  before putting anything in a category.
- **The Claude desktop app only exposes two window titles**: `Claude` (chat and Claude
  Code) and `Design` (Claude Design). The conversation or project name is never in the
  title. To tell what a stretch of `Claude` time was for, match its timestamps against
  Claude Code transcripts in `~/.claude/projects/<cwd-slug>/*.jsonl` (each line has a
  `timestamp`). The project folder (cwd) is the best signal: `-Users-julianmoncarz-kairos-monorepo`
  is Kairos work, `-Users-julianmoncarz-repos-TAISI-website` is TAISI, `-Users-julianmoncarz-school`
  is school, and `-Users-julianmoncarz` (home) is usually personal setup and tooling.
  Claude chats in Chrome (`claude.ai`) do carry the chat name in the tab title.
- **Claude Design (`window_title == "Design"`) can't be attributed to a project from the
  log.** Ask Julian, or look at what preview URLs were open in Chrome around the same
  time (e.g. `taisi-redesign-preview.vercel.app`).
- **`active` status is not proof of attention.** A long single segment (hours on one
  page) is often a tab left open with occasional mouse movement. Flag segments over
  ~60 min rather than counting them at face value.
- **Fragmentation is a key metric, not just totals.** Merge consecutive segments with the
  same app + domain into episodes, then report switches per active hour and the number of
  uninterrupted blocks of 25+ and 50+ minutes. Comms (Slack, Signal, Messages,
  Superhuman, Gmail) check-ins per hour matter more than comms minutes.
- **Comms checks during calls are fine; don't count them as distraction.** Julian,
  2026-10-10: messaging during a call usually means doing something productive or needed
  for that call. Exclude comms check-ins that fall inside a call (Meet, Zoom, or a
  calendar event with other attendees) from comms-loop metrics and never flag a call for
  its comms rate. Leisure or off-plan reading during a call is still worth reporting.
- **Cold Turkey Blocker context.** Block pages show up as tab title `Blocked by Cold Turkey`,
  which records each attempt to open a blocked site. The block config lives in
  `/Library/Application Support/Cold Turkey/data-app.db` (table `settings`, a hex string:
  drop the 5-char `CTB17` prefix, then subtract 17 from each byte to get JSON). Read it
  read-only (`sqlite3 -readonly`). It explains the hard stop around 21:00 most days.
- **Ignore anything in front for 1 second or less** (Julian, 2026-10-24). A sub-second
  segment (Slack flashing before App Gate quits it, a tab passed through) is not an open, a
  switch or a block on the timeline. This took 8 to 10 switches an hour off every week.
- **Count hands-free video as watched** (Julian, 2026-10-24). A follow-along video in
  QuickTime or YouTube logs as `idle`, since there's no input. Count idle segments there as
  time on that video: a 60-minute flexibility routine logged as 5 active minutes.
- **What counts as a switch** (Julian, 2026-10-24). Moving to another app, another site, or
  another Claude project (or into Claude Design) is a switch. Chrome's new tab page, the
  Wispr Flow dictation popup and the App Gate prompt are steps on the way somewhere, so they
  are never a switch: drop them from the switch count but keep their time inside focus
  stretches, or sitting on a new tab breaks a real stretch. Two Claude sessions in the same
  project look identical in the log, so switches between them can't be counted.
- **App Gate has its own log; read it before claiming anything about the gate.**
  `~/personal-tools/data/app-gate/AppGate.log` (`SlackGate.log` before 2026-10-24) has one
  `ts<TAB>app<TAB>intent` line per pass, plus `gate shown for X` and `gate closed without
  passing for X` lines. Returning to an app within 3 minutes of leaving it skips the prompt
  by design, so that's not a leak. Intents can be personal: count them, never quote them in
  the report.
- **When a counting rule changes, recompute every past week under it** before comparing
  weeks, so a trend shows a change in Julian, not in the rules.

## Related tooling

- There is no nudge script. An earlier note here described `~/personal-tools/activity-logger/nudge/`,
  but that folder never existed in the repo and nothing like it runs (checked 2026-10-24).
  Don't refer to it.
- `~/personal-tools/app-gate/`: App Gate, Julian's own app. It quits Slack, Signal, Beeper, Messages
  and WhatsApp when they come to the front, unless he left them under 3 minutes ago, and
  relaunches once he types an intent and waits 10 seconds. Private repo
  https://github.com/Julian-Moncarz/app-gate (git from 2026-10-24). Passes go to
  `~/personal-tools/data/app-gate/AppGate.log`, but its "gate shown" and "gate closed without passing" lines go
  to stderr, `~/personal-tools/data/app-gate/AppGate-errors.log`, so read both.
- `~/personal-tools/break-coach/`: Break Coach, Julian's break app (built 2026-10-24, simplified the
  same day; private repo https://github.com/Julian-Moncarz/break-coach, login item
  `com.julianmoncarz.breakcoach`). After 60 minutes at the screen without 5 minutes away (idle,
  locked, display off, lid shut, asleep) it covers every screen with one thing to do. The first
  break after noon each day sends him outside. Only a small close button, and a closed break
  returns 30 minutes later. No calendar, call or flow checks. Watching a video or being on a call
  (an app keeping the display awake, or the mic in use, from macOS power assertions, ignoring
  caffeinate) counts as present for up to 2 hours (video) or 1 hour (mic) without input. Log:
  `~/personal-tools/data/break-coach/BreakCoach.log` ("ts<TAB>event<TAB>detail": started, break
  shown, break taken, closed early, natural break). Prompts: `data/break-coach/prompts.json`
  (editable). Current run: `data/break-coach/state.json`.
- `~/personal-tools/attention-ledger/`: the weekly Attention Ledger (code, `NOTES.md` with every
  decision about the report). Its week folders are in `~/personal-tools/data/attention-ledger/runs/`.
  The routine that runs it is `~/.claude/scheduled-tasks/weekly-screen-time/SKILL.md`.

## Lessons log

Running log of things learned while analyzing these logs. Add a dated entry whenever
an analysis teaches something a future session should know. Newest at the bottom.

- 2026-10-02: Classify by window title, tab title and URL, never by app name. Grouping
  by app hid ~10 h of TAISI website work (7.6 h of it in Claude Design) inside "Claude".
- 2026-10-02: Claude Code session titles (`list_sessions` in the desktop app) and the
  transcript cwd attribute `Claude` window time well. In week one, ~4.5 h of 9.3 h
  matched Kairos work, ~1 h home-folder tool setup, ~0.8 h TAISI, ~2.7 h unmatched
  (likely plain chats).
- 2026-10-02: Cold Turkey worked on classic distractions (shopping, Clocktower,
  reading fell from ~40-60 min/day to under 10 after the "work" whitelist block began on
  2026-09-28). What remained was off-plan work inside allowed apps, which a blocker
  can't see. Look there first.
- 2026-10-02: Fragmentation was the biggest signal in week one. About 100 context
  switches per active hour (median episode 6 s), a messages check every ~3 min, and only
  11 uninterrupted blocks of 25+ min in ~60 active hours.
- 2026-10-02: A 203-min single Quercus segment (2026-09-26) was almost certainly a tab
  left open. Treat long single segments with suspicion.
- 2026-10-02: Claude Design is a tool Julian wants, so never treat `Design` time as
  off-plan by itself. Only TAISI work is off-plan in work hours. Since the Design title
  never names the project, the TAISI signal is the Chrome preview tabs
  (`taisi-redesign-preview.vercel.app`) and the `repos/TAISI-website` transcripts.
- 2026-10-10: Week two (2026-10-03 to 10-10) report flagged 1:1s for high comms
  check-ins (e.g. 17 in a 30-min check-in). Julian: comms during calls is usually
  productive, so those flags were wrong. Measure comms loops outside calls only.
- 2026-10-13: Chrome sites with no work signal fall through to Work in the ledger classifier.
  Spotify playlists (2.3 h), jewellery and Etsy shopping, and fiction sites (freesfonline,
  yudkowsky.net) inflated Kairos work by 3.8 h and created three fake Sunday "focus
  stretches". Check the top Work hosts every run and add strays to `LEIS_HOSTS` or
  `READ_HOSTS` in ledger.py.
- 2026-10-13: Weekend days pull the weekly switches and comms averages down a lot (Sunday
  ran at 35 switches an hour). Report the weekday range next to the weekly figure, or an
  improvement can be all weekend.
- 2026-10-17: Side projects can live in their own Claude Code folder under `~/repos/`
  (`~/repos/fixing-swapcard`, a Swapcard Chrome extension, about 3.4 h on 2026-10-15/16). The
  ledger only knew TAISI and personal-website, so it landed in "Claude (unattributed)". Check
  the claude_attribution table every run for new project folders. Also: a recorded reference
  call played in QuickTime is hiring work, not leisure.
- 2026-10-17: Focus stretch counts include school, side projects and plain Claude chats. In the
  October 10 to 16 week, 15 stretches looked like a big jump, but the two longest weekday ones
  were school and the Swapcard extension. Split stretches by content before calling it progress.
- 2026-10-24: New comms channels appear without warning. Beeper (a messaging hub, from
  2026-10-19) and Julian's own Slack Gate app (`com.julianmoncarz.slackgate`, also from
  2026-10-19, a prompt shown before Slack opens) fell into "Other" until added to the comms
  apps. Some app names carry an invisible `‎` prefix (`‎WhatsApp`), so strip it
  before matching. Check the "Other" top titles every run for messaging apps.
- 2026-10-24: Claude Code can run from desktop scratch folders
  (`~/Library/Application Support/Claude/scratch/workspaces/.../scratch/<date>/<id>`), which say
  nothing about the project. Read the transcript's first messages to attribute them (the
  2026-10-20/21 one was Kairos Pangram testing). claude.ai tab titles naming SPAR, Kairos or
  hiring are Kairos work.
- 2026-10-24: In-person weeks (EAG, team retreat) are not comparable on hours (3.6 active h a
  day on retreat days against 7.4 on remote weekdays), and sessions held in the room are not
  on the calendar. Compare rates per active hour and say which days were in person.
- 2026-10-24: Correction to an earlier entry the same day. Slack Gate did not miss two
  thirds of Slack opens. It caught every visit (0 of 60 slipped past). The "third" came from
  counting sub-second Slack flashes and the gate's by-design 3-minute returns as opens.
  Julian spotted it. Check the gate's own log before drawing a conclusion like that.
- 2026-10-24: Julian's comments on the October 17 to 23 page. Sections he found useful were the
  header tiles, the tracked table and the morning routine. He cut the hourly comms chart, the
  "what was on screen during events" section and the in-person vs remote comparison as not
  useful. He wants method notes kept but tucked behind "How this is measured" toggles, so he
  can judge whether to trust a number. He also wants the lede not to repeat the tiles.
- 2026-10-24: About a quarter of comms checks start while waiting on Claude Code (the three
  weeks before October 17 to 23 were 25 to 26%, median wait 33 to 55 s). Look at agent waits
  whenever comms checks are high.
- 2026-10-24: The "(hiring)" tag on Claude Code time overcounts. A transcript counts as hiring when
  hiring words come up a couple of times, so Friday October 23's SPAR impact study sessions (16:42
  to 20:40) were tagged hiring. Read the session's own messages before calling a stretch hiring.
- 2026-10-24: Fixed in ledger.py: Claude Code time now counts as hiring only when hiring words
  appear in at least a quarter of Julian's messages in that session, and never for school. Hiring
  for October 17 to 23 went from 4.9 h to 1.8 h. Earlier weeks barely moved (10.9, 12.8, 9.7 h).
- 2026-10-24: Break Coach's first real break (15:39, "outside", 210 min) was false. Julian's
  laptop slept through a 2-hour flight, Break Coach didn't count sleep as a break, so the run
  carried on from 12:09. His "closed early" at 15:39:55Z is that bug, not a skipped break, so
  leave it out of the October 24 to 30 scorecard. Sleep, a closed lid and long gaps between
  checks now count as breaks.
- 2026-10-24: Break Coach was simplified the same evening at Julian's request: no calendar, no
  call or flow checks, no heads-up, a 60-minute threshold. The saved secret iCal address
  (`data/break-coach/calendar-ical-url`) was deleted, since nothing uses it. Google still
  honours that address until Julian resets it (Calendar settings > Integrate calendar > Reset).
  From October 25, Break Coach logs only "started", "break shown", "break taken", "closed early"
  and "natural break" (no "heads-up" or "deferred").

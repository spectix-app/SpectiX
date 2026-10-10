# Changelog

Every release, newest first. Also at https://spectix.app/changelog/

## 1.10 — Busy sessions with many agents hover cleanly (2026-10-06)

Verified on Claude Code 2.1.291.

### New

- **About** — the About card now reads FSL-1.1 and the licence text inside the app is the Functional Source License. This is the first release under it: free to use, personally or at work, and each release becomes Apache-2.0 two years after it ships.

### Fixed

- Pointing at a session that had many agents running under it pushed every outline away from its own text — with ten or more agents the top and bottom rows sat visibly off their boxes. The lift now grows the group by the same small amount however tall it is, so every row stays inside its outline.

## FSL-1.1-ALv2 — New license from the next release (2026-10-04)

- From the next release on, SpectiX is source-available under the Functional Source License (FSL-1.1-ALv2). The code stays public at [github.com/spectix-app/SpectiX](https://github.com/spectix-app/SpectiX).
- You can use it free — personally or at work. You may not sell it or ship a competing product built from it. Every release becomes Apache-2.0 open source two years after it ships.
- Version 1.9 and earlier were released under GPL-3.0 and stay GPL-3.0.

## 1.9 — Open source, and a break timer that notices when you walk away (2026-10-04)

Verified on Claude Code 2.1.289.

### New

- **About** — the About card now says the app is GPL-3.0 and links straight to its source on GitHub, and the licence text ships inside the app itself. This is the first release built from the public repository.
- Builds no longer carry an expiry date. Earlier versions counted down to a date after which they stopped working; this one keeps running for as long as you keep it.

### Fixed

- Walking away from the desk, or closing the lid, during a work round jumped straight to `休息好了？` before you had rested at all. Leaving now starts a rest dated from your last input, the prompt only appears once the rest is long enough, and it tells you how long you have been away.
- The “time for a break” banner stayed on screen after you had already started a rest. It now fades like the other banners and clears the moment a rest begins, and the over-time chip in the title bar is readable again — dark red on a pale wash instead of white on solid red.
- In VS Code, clicking a terminal’s row in the side tab list swapped the pane in but drew no ring, because focus stayed on the list. The ring now lands on the pane that row shows.
- When a window grew a second terminal, the side tab strip appeared and the hidden terminal’s status dot was left sitting on top of it. Dots that fall on the tab strip are now hidden.

## GPL-3.0 — SpectiX is now open source (2026-09-30)

- The full source is public at [github.com/spectix-app/SpectiX](https://github.com/spectix-app/SpectiX) under GPL-3.0. You can read every line, build it yourself with `./build.sh`, and file issues there.
- Nothing about the app changes: the signed, notarized download is built from the same code, and it still makes no network connection you did not ask for. The checks on the [privacy page](/privacy) work exactly as before.

## 1.8 — See which skills and agents you actually use (2026-09-29)

Verified on Claude Code 2.1.284.

### New

- **Skills** — a fifth tab in the main window lists every skill and agent you have for Claude Code and Codex, with its description, where it lives, how many times it has run and when it last did. It reads as a leaderboard, most used first, and the **All** / **Claude** / **Codex** filter and the sort order stay pinned while you scroll, so a skill you wrote months ago and never call is easy to spot.
- Counts come from your local transcripts. The first visit takes a few seconds to read them; after that only what is new since last time is read, so the tab opens in about half a second. A row can show the file in Finder, open it, or copy its name for typing after a slash.

### Fixed

- The context gauge read about five times too full on Opus 5.5. Its model ids carry no `[1m]` suffix, so the app assumed a 200k window for what is natively a one-million-token one. Opus 5.5 is now recognised as a 1M model, and a session’s own model can raise its window rather than only the model its project last used.
- The app did a full process scan a few times a second with nothing to show for it. Each open editor window rewrites a small heartbeat file every two seconds, and every one of those writes woke a scan of around seven hundred processes. Heartbeats no longer trigger a scan — the regular poll still reads them — and each process’s arguments are now remembered instead of re-read on every pass. On a measured sample the time spent scanning fell by about a third.

## 1.7 — A seventh status, and a menu bar icon that stops growing (2026-09-15)

Verified on Claude Code 2.1.273.

### New

- **Waiting** — a seventh status, in cyan, and the only hollow dot in the app. A background shell command still running, or a turn parked while background agents finish, used to be painted the green of a finished turn — you walked over and found nothing to do. Both are now waiting: a filled dot means someone is busy or something needs you, a hollow one means neither, it is only waiting. It joins no jump queue, makes no sound and raises no banner, and the row’s right-hand tag says what is being waited on where the pill only says that it is.
- **Export diagnostics** in Settings › System permissions — the highlight ring failing to appear has four causes that look identical from the outside, one of them being an editor extension that is on disk but running in no window. The button writes a plain text file saying whether the extension loaded, what the recent jump and ring attempts did, and which permissions are granted, ready to paste into the feedback page. It contains none of your code and none of your conversations.
- The break strip can now count up instead of down. A button beside the `✕` flips the big number between how long until the break and how long you have worked this round; the icon says which you are looking at, and the choice is remembered. The 🍅 chip in the header reads the same number, so the two can never disagree.
- The break strip is coloured by state: the background is where you are, the main button is where it takes you. Working is red with a green **Rest now**; resting is green with a red **End break**; `Rested?` belongs to resting, so it is green with a red **Start**. Before, button and background shared a colour and the button read as decoration rather than as the way out.
- The countdown in the header keeps its footnote on screen. It used to expand only on hover, which left the bar in the middle of that column with nothing to say what it measured. It still widens three to one on hover, and each column’s floor is now derived from its slot rather than typed in, so all three read correctly from 384pt in the menu bar popover up to a full window.

### Fixed

- The menu bar capsule ate about a gigabyte of memory a day. To make the running dot breathe it redrew an image ten times a second and wrote it to the status bar button — and on macOS 26 every write to that button registers a pair of objects the system never frees again (measured: five per image write, a hundred and sixty per width change, about thirteen per frame at that rate). A process left running twenty-two hours had accumulated 1.25 million of each. The capsule is now a view inside the button, the breathing is a layer animation the system runs by itself, and the artwork is redrawn only when the counts or the colours actually change.
- Two git worktrees of one repository could add a dead grey group to the list that opened nothing. A window title carries a folder name and no path, so the two look alike from outside; faced with a window parked on a preview tab or holding only terminals — neither of which has a current file to tell them apart — the app fell back to ranking and picked the main checkout, which had no sessions of its own. Windows now report which folders they have open, through the editor extension that ships with this build, and a window that cannot say draws no group rather than a wrong one.
- A batch of background agents returning rang the done chime once each. Five agents meant five chimes while nothing had finished — the session woke straight back up and carried on. The chime now hangs off the same ledger as the waiting status: when the screen does not say finished, neither does the sound.
- The break banner could arrive while you were in the middle of something, stacked on top of a prompt waiting for your answer. Crossing zero raised it regardless of whether you could act on it. It is now held back while any session is running or waiting on you and released at the first genuinely quiet moment — the first moment you could actually stand up — for at most ten minutes, so an unattended night cannot swallow it entirely. The strip and the chip still turn red the second the count reaches zero.
- The green glow around the resting strip was drawn as a hard-edged square, and the big number sat visibly high. The panel was clipping itself, so the part of the glow outside it stopped at the boundary instead of fading; and the clock and its caption were each centred on the same line, which put a 24pt numeral above the optical middle. The glow now follows the rounded edge, and clock and caption are centred together as one block. In dark mode the caption had been invisible: a colour that follows the system had turned white on pale green, and a terracotta button beside green read as orange. Pale backgrounds now carry fixed dark ink, and the button on green is deep red.
- The header could not print the one figure most worth seeing. `100%` needs 32pt at that size and the slot is 25pt, and a label that does not fit is not truncated — it takes the width from the only elastic thing on its line, which is its own bar. Codex’s `26d/09h` overran the footnote slot the same way. Neither is fixed by widening, which would leave a gap between every two-digit figure and its bar: three digits drop the per cent sign, ten days and over drop the hours. A check now fails the build when a label wants more than its slot allows.

## 1.6 — A break timer that knows when you are working (2026-09-11)

Verified on Claude Code 2.1.268.

### New

- **Break timer** — a 🍅 chip beside the session count times how long you have been at the machine, and starts by itself when a session begins working. When it reaches zero a strip opens under the header, the chip turns red and keeps counting past zero, and a banner appears with the done chime, again after every further work length until you stop. Work and rest lengths are in Settings › Breaks.
- **Rest now** — swaps the tomato for a stretching cat and counts your break down. **+10 min** buys one extension per round, and the ✕ closes the strip for that round. When the break is over a cat in glasses asks `Rested?` until you press **Start** or a session starts a new turn.
- Walking away counts as a break even if you never press anything: five minutes without keyboard or mouse, or twenty while a session is running (watching a long turn is not rest), or a closed lid ends the stretch and adds it to today’s total, which the chip shows on hover.
- Click the big clock on the strip to pick a length — work lengths normally, rest lengths while resting. The round in progress is re-timed on the spot, so lengthening an overdue round puts it back to counting down.
- Switching to another Claude account in the account panel now also asks for that account’s current usage, so the header shows its real figures straight away instead of the last ones it remembered. The second 1.5 download already did this without a word here, so this is that word: the request is sent only on your click, carries the access token of the account you switched to, goes to Anthropic’s own usage endpoint, and is made by a `/usr/bin/curl` child process. A small spinner shows while it is in flight.

### Fixed

- Right after a switch, the header could show the figures of the account you had just left under the new account’s name, because the newest reading on disk still belonged to it. Readings older than the switch are now set aside, and until a fresh one arrives the card shows the new account’s own last figures, marked as remembered rather than current.
- Two git worktrees of the same repository share a folder name, so the session list showed two identical group headers you could not tell apart. Each header now adds the nearest parent folder where the two paths differ, and Recent Projects uses the same names.

## 1.5 — Every account’s quota, without switching to it (2026-09-09)

Verified on Claude Code 2.1.263.

### New

- **Refresh** — the Claude account panel has a refresh button, shown once a remembered account other than the signed-in one has a stored copy. Press it and every such account is asked for its current 5-hour and weekly usage, so the panel shows real figures across the board instead of the dimmed `~` estimate everywhere but the active row. A row refreshed this way stays marked live for ten minutes and then returns to the older reading rather than passing it off as current.
- That request goes out on your press and at no other moment — not when the panel opens, never on a timer, never in the background. It sends the stored copy’s access token, never the refresh token, to the same usage endpoint the CLI’s own `/usage` command calls, and the request is made by a `/usr/bin/curl` child process — the app binary still links no network library and opens no socket, which is what the checks on the privacy page verify. An outbound firewall shows that connection as the child process’s, started by SpectiX; deny it and the row keeps its last figure.
- When some accounts cannot be read, the button settles on an amber warning instead of quietly returning to idle, and says how many were missed and that signing in to one once is enough to make it refreshable. The signed-in account now also carries a green tick beside its address, so the row you are on is legible at a glance rather than inferred from which bars are live.
- The panel opens even when that CLI has nobody signed in, as long as one address is remembered. A failed read of the current credential used to hold it shut — at exactly the moment you needed it to sign back in. It also matches the width of the account card above it and resizes with it, rather than sitting at a fixed width of its own.

### Fixed

- Switching to a Codex account could sign it out instead of switching to it. The Keychain returns Claude’s one-line credential as text but Codex’s multi-line one as a hex dump, and that hex went straight back into `~/.codex/auth.json`, which the CLI cannot parse. Every credential read now passes through one decode-and-validate step that undoes the hex and refuses anything that is not valid JSON, so a bad read can no longer overwrite a good stored copy or reach the live file.
- A switch could quietly restore the wrong account. If the credential being left failed to read for a moment, the copy was filed under the last known name while its bytes belonged to somebody else, and the next click on that name signed you into the other session. A Codex credential is now checked against the address it claims before anything is saved, and nothing is saved when they disagree.
- The status dot on a terminal pane took a fraction of a second to disappear when you dragged a window over it, because it floated above everything and only a quarter-second sweep noticed it had been covered. It now sits at the terminal’s own level, so whatever covers the terminal covers the dot in the same frame; it lifts for one second after you click that window, which is the only moment it needs to.
- Status dots could float over the SpectiX window itself. Working out what was in front excluded every window belonging to the app, so its own main window counted as nothing at all and the dots behind it stayed on top. Only the dot panels are excluded now.
- In light appearance the impact panel lost half its colours: the neon greens are built to glow against a dark surface, and on a white one they washed out to almost nothing. That panel now carries its own dark surface in both appearances, collapsed or open, so the curves and their labels read the same either way. Hovering the open card no longer lights it up as though it could be clicked, which it has not been since closing moved to the small chevron.
- A selected session row rendered brighter and more saturated than the rows around it, a block of colour rather than a tint. The status colour is now mixed at a lower rate over the row’s resting fill instead of its lifted one, which is what the design called for.

## 1.4 — Codex sessions join the list, and you can change account in one click (2026-09-04)

Verified on Claude Code 2.1.260.

### New

- **Codex CLI** — sessions of OpenAI’s Codex CLI now appear as rows next to your Claude Code ones, with the same status colours, title, current step, token count, context figure and model chip. The same hook script drives both; Codex asks you to approve it once from its `/hooks` panel, and the installer says so on its last screen. Two things Codex rows do not get: the busy probe that catches a prompt the hook missed, and the background-agent badge — Codex runs tools differently and neither signal exists there.
- **Accounts** — click the Claude or Codex column in the header and every account you have signed in with is listed. Click another one and it becomes the active account for terminals you open from then on, without signing in again; running sessions keep the account they started with. **Add account** runs the CLI’s own login in Terminal, and right-click gives you **Remove from list**. This is the one feature that touches a sign-in credential: it copies the CLI’s token into SpectiX’s own Keychain items when you switch, and only then. The privacy and security pages say exactly what is read and where the copies live.
- Each account row carries its own 5-hour and weekly gauges. Only the signed-in account can have a live reading, so the others are drawn honestly: a dimmed bar with a `~` for a figure recorded last time that account was active, an empty bar with a green `0%` once its window has rolled over, and a dash for an account that has never been used while the app was running. The green zero is the point — it tells you the other account is usable again without switching to check.
- **Terminal status dot** — a setting under Highlights that keeps a small dot in the top-left corner of every visible terminal pane in VS Code, Cursor and Windsurf, in the colour of that session’s status. With terminals as vertical tabs only one pane is on screen, so the same dot also sits on each terminal’s row in the tab list. You can tell which session is waiting without switching to it. Off by default.
- **Burn rate** and **Terminals at once** — two new curves in the stats window under the impact chart, sharing one time axis so you can read straight down from an expensive five minutes to how many terminals were open. The burn-rate curve draws a second dashed line for the share spent by unattended runs. Every curve in that panel now shows a readout under the pointer.
- The header’s three readings — this Mac, Claude, Codex — sit as three columns inside one frame instead of separate cards, each with a small plan chip. The Codex column only appears once there is a Codex account or quota to show. Countdowns read `3h/20m` rather than `3h20m`, which ran together as one number.

### Fixed

- A row’s title followed the last thing you typed, while the VS Code terminal tab kept the name Claude Code gave the session — on one machine ten of fifteen live terminals disagreed with their tab. The row now defers to that name once it exists, so both places read the same. Dragging a screenshot into a prompt also no longer turns the title into a file path.
- A reused terminal could show the model of a session that ended hours earlier on a different project, because a terminal outlives the session on it. The fallback now only trusts a record written by the process that is actually running there.
- Switching terminal by clicking a row in the tab list left you without a ring or caption for up to four seconds, and clicking the terminal’s icon after a jump made the highlight vanish. Clicks now draw from the remembered pane position immediately, as jumps do, and focus resting on the tab row counts as still being in that terminal.
- With vertically tabbed terminals, several status dots landed on the same corner, and the one you saw could belong to a terminal hidden behind the current one — a running blue on an idle terminal. Only the dot of the terminal that is actually selected is drawn now, and when it has none yet the pile is hidden rather than shown in the wrong colour. Dots also stopped flickering on and off every few seconds.
- In the stats window the readout under the pointer blinked away every couple of seconds as the panel repainted, the day-long impact curve could shrink to a single dot, and a legend described a dashed line that was never drawn. Repaints now wait while the pointer is over the panel, the day view falls back to counts when scores are too sparse, and the legend only names what is on screen. Clicking on the panel no longer folds it away.
- Opening Terminal from the account panel did nothing when Automation permission had been denied. It now says so, with buttons to open System Settings or copy the command.

## 1.3 — The header watches this Mac, not just your quota (2026-08-25)

Verified on Claude Code 2.1.241.

### New

- **This machine** — the quota strip at the top is now a pair of cards. The new one on the left reads the Mac you are working on: processor load and memory in use, each with its own bar and figure. Click it to open Activity Monitor.
- The processor figure is normalised across every core — the scale Activity Monitor uses, where a full bar means the machine is full, rather than the one where eight busy cores read 800%. The footnote beside it says how many cores that actually works out to, which is the part a single percentage cannot tell you.
- Reading the load opens nothing and asks for nothing. It comes from the kernel directly: no subprocess, no permission prompt, and no connection — the same as everything else here. Sampling runs only while a window is open, and the first reading after opening one shows a dash while it establishes a baseline, because load is a rate and needs two samples to exist at all.
- The session counts now sit at the right of the main window’s title row, opposite the logo, instead of on a line below it.

### Fixed

- The panel measuring what the app did for you ignored the range you picked. Whether the window above it was set to today, this week, this month or all time, it always answered for the week — so the two halves of one window described different periods. It now follows the switch, and draws its curve at the matching grain.
- Chart axes carried three labels at most, so a day-long curve read `0 / 12 / now` and told you nothing about where anything fell. Labels are now spaced along the axis, up to seven of them: a week gets its seven weekdays, a month one every five days, and `now` keeps the last slot to itself.

## 1.2 — The app starts measuring what it does for you (2026-08-13)

Verified on Claude Code 2.1.232.

### New

- **This week** — a panel at the top of the stats window that measures what the app itself did for you, rather than what Claude did. Five figures: waiting you did not do, your longest unbroken stretch of focus, your run of consecutive days, how many jumps it made on your behalf, and the most sessions you ran at once.
- Click any of the five to open a card explaining what was measured and how it was counted. Every number is re-computable by hand from the log behind it — nothing on the panel is a verdict the app asks you to take on trust.
- The first week says so instead of guessing. Before there is anything to compare against, the panel says the record is a first rather than printing a saving it cannot yet know, and the chart plots this week by day until the eight-week curve has two weeks to draw from.

### Fixed

- Clicking the menu bar icon could do nothing at all — no popover, no error. After a sleep/wake cycle or a display change, the invisible panel the popover attaches to had been dropped by the window server while AppKit went on reporting it as healthy. It is now rebuilt for each open and verified against the window server; if it still cannot be shown, the main window opens instead of the click going dead.
- The return-to-origin key did nothing, silently, when the window you had jumped from had since been closed or its app quit. The origin is now checked for liveness before being raised, and the call is time-bounded so a wedged app cannot stall the interface.
- An open main window stranded on a disconnected display was never brought back. It is re-examined whenever the displays change, and recentred only if it is on no screen at all.
- Accessibility could read as granted in System Settings while nothing that needs it worked. Turning it on from Settings now clears the stale record first, so the request actually reaches you — and only when the permission is genuinely broken, never when it is working.

## 1.1 — Fresh installs get their highlight back (2026-08-12)

Verified on Claude Code 2.1.221.

### Fixed

- On a machine that had never carried the editor extension before, jumping to a session worked but the breathing ring and its caption never appeared at all. The installer put the extension on disk without registering it in the editor's own extension index, so the editor never loaded it. It is registered now, and taken back out again on uninstall.
- An editor that is already open has to be reloaded before a freshly installed extension can do anything. The installer now says so where you cannot miss it, instead of in one line of small print.

## 1.0 — First public release (2026-08-10)

### Seeing what is going on

- A menu bar icon that summarises how many sessions need you, are working, and are done — without opening anything.
- One row per live session, grouped by project window. A working row shows the tool step it is on right now; a finished row shows elapsed time, tokens, the model that session is on, and how much of its context window is gone.
- Five states, kept honest: needs you, working, done, paused (you interrupted it), idle.
- Background subagents are tracked per session, including the case where a subagent's permission prompt never reaches the terminal's hooks.
- The desktop Claude app appears as its own group, detected without hooks.
- A stats tab: weekly usage bars, a token heatmap, and totals for runs, approvals and tokens.

### Getting back to it

- Click a row to land in that session's terminal with the cursor in its input box — including the correct split pane inside a VS Code window, and across Spaces.
- A breathing ring lights up the pane you landed on, in eight styles, configurable per status.
- `⌃⌥⌘B` toggles the panel; `⌃⌥⌘N` jumps to the next session that most needs you, walking a jump order you can drag into whatever shape you want. Both are rebindable.
- Toast notifications for "needs you" and "done" that dismiss themselves when you switch to that terminal yourself.

### Making it yours

- Light, dark or follow-system appearance, plus a second visual theme.
- Interface in English or Chinese, switchable live.
- Per-project emoji icons, hideable projects, grouping by project or by status, and a customisable status order.
- A GUI installer that puts the app, the status hooks and the editor extension in place in one click — and takes all three back out again.

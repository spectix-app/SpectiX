#!/bin/bash
# SpectiX status hook — records each session's live state for the menu bar app.
#
# Why a hook instead of reading transcripts: Claude Code v2.1's daemon architecture
# stopped writing a discoverable ~/.claude/projects/<cwd>/<session>.jsonl for live
# terminal sessions (and the hook's session_id no longer matches any jsonl on disk),
# so transcript-mtime can't tell "working" from "done" anymore — everything looked
# blue. The hooks themselves are the reliable signal; they fire on exactly the
# transitions we care about:
#   $1 = working -> UserPromptSubmit / PreToolUse  (model is busy)        蓝
#   $1 = done    -> Stop                           (turn ended, your turn) 绿
#                   Still written while bg-<tty> lists running background subagents —
#                   the state file only ever holds the five hook states — but the app
#                   renders THAT row 等待/await (青), not 完成, because the turn merely
#                   parked to wait on its agents (T314, reversing T54's green). The
#                   chime below is gated on the same ledger for the same reason, and the
#                   🤖 ×N badge says how many are still out.
#   $1 = needs   -> PermissionRequest              (permission dialog)     红
#                   PermissionRequest fires the instant the dialog appears — the
#                   real-time needs signal. Notification is ALSO mapped to "needs"
#                   as a fallback, but Claude Code debounces it (~2-4s lag), and it
#                   double-duties as the idle "waiting for your input" ping. That ping
#                   normally writes nothing (a quiet row must not repaint green — Stop
#                   owns "done"), with ONE exception: if the row still says needs or
#                   working, the ping proves that state is stale (Esc interrupt emits
#                   no hook) and flips it to paused. See the idle_prompt branch below.
#
# State is keyed by the session's controlling tty, not env: both CLAUDE_CODE_SESSION_ID
# and CLAUDE_CODE_SSE_PORT are inherited and shared by every terminal in the same
# VSCode window, so they'd collapse sibling sessions into one. The tty is unique per
# terminal. This hook runs piped (no tty of its own), so we walk up the parent chain
# to the `claude` process that owns the terminal. The app joins each live process on
# its own tty (~/.claude/spectix/state-<tty>) to read its state.
#
# Sessions with NO tty at all — the Claude Code chat panel inside VSCode — key on the
# claude process's pid instead ("pid<PID>"); see the climb below for why that's still
# within 「键控原则」. Every companion file (title-/step-/bg-/agents-/ctx-/tp-/…) is
# built as "$dir/<name>-$tty", so they all follow that key with no further change.
action="$1"
# Every file written under $dir needs a row on the site's /security page: tools/web-check.py
# fails the deploy otherwise, and it only sees names whose prefix is literal ("$dir/<name>-$tty").
dir="$HOME/.claude/spectix"

# The subscription-usage snapshot at the bottom spawns a nested `claude -p "/usage"`.
# That child fires its OWN copy of these hooks, which would (a) recurse and (b) climb the
# parent-process chain to THIS terminal's tty and clobber its state file. The probe
# exports SPECTIX_USAGE_PROBE, so bail immediately and leave the nested run's hooks inert.
[ -n "$SPECTIX_USAGE_PROBE" ] && exit 0

# Write atomically: a temp file in the same dir + mv (rename(2)). This changes the
# directory entry, which fires the app's watchers (FSEvents *and* the kqueue dir
# source) instantly and reliably — a plain `>` truncates in place (same inode), and
# some watch paths miss or delay that, which is what made the row lag the prompt.
atomic_write() { # $1=dest  $2=content
  local tmp="$1.$$.tmp"
  printf '%s' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

# Read the hook payload once. UserPromptSubmit carries .prompt; Notification carries
# .message; Pre/PostToolUse carry neither. We branch on what's present below.
input=$(cat)

# Locate the controlling tty by climbing to the ancestor that owns a terminal.
#
# ★ Editor chat panels have NO tty anywhere on the chain (改这块前必读). A Claude Code
# session running in the VSCode sidebar/tab is spawned by the extension host, so the
# chain reads claude → Code Helper (Plugin) → Code → launchd — not one ttys* on it.
# Those sessions fire every hook exactly like a terminal one (verified 2026-08-05 on
# 2.1.222: UserPromptSubmit/Stop arrive identically), so the signal was always there;
# only the KEY was missing, and `[ -z "$tty" ] && exit 0` dropped them on the floor.
# We therefore fall back to keying on the `claude` process's own pid ("pid<PID>").
# That obeys CLAUDE.md「键控原则」, which allows tty (unique per terminal) OR pid
# (unique per process) and bans only env/sessionId — and it matches how the daemon
# keys its own ~/.claude/sessions/<pid>.json.
#
# ⚠️ ORDER MATTERS: terminal sessions have `claude` on their chain too, but their very
# first hop already carries a ttys*, so they break out before the fallback is ever
# consulted and keep their historical state-ttysNNN key byte for byte. That ordering
# is the regression line for this whole feature — never hoist the pid branch above it.
tty=""
cpid=""
p=$PPID
while [ "${p:-0}" -gt 1 ]; do
  t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
  case "$t" in ttys*) tty="$t"; break ;; esac
  # No tty on this hop. Remember the first `claude` ancestor as the fallback key —
  # costs one extra ps ONLY on tty-less chains (a terminal session breaks above).
  if [ -z "$cpid" ]; then
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in
      */claude|claude) cpid="$p" ;;
    esac
  fi
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
[ -z "$tty" ] && [ -n "$cpid" ] && tty="pid$cpid"
[ -z "$tty" ] && exit 0

mkdir -p "$dir"

# Ledger of still-running async subagents (any Agent/Task launch — this harness runs
# them all async), one agent id per line. Stop fires when the main turn ends even while
# such agents are still running — a non-empty ledger turns that Stop into working (蓝)
# instead of done (绿), so the row never claims "完成" while a subagent is busy. Ids are
# added when the launch's PostToolUse carries an agentId (NOT gated on run_in_background;
# see the append block below) and retired when the task-notification wake-up comes back
# (a synthetic UserPromptSubmit embedding the same id as <task-id>).
bgfile="$dir/bg-$tty"

# SessionStart fires on startup/resume/clear/compact. On a /clear the conversation
# is wiped but the title-<tty> file still advertises the previous task, so the app's
# row keeps the stale label until the next prompt. Reset it here: drop the title so
# the row falls back to the folder name, and mark the session idle (灰「闲置」). A
# fresh startup (or just-cleared conversation) has run nothing yet, so it's idle —
# not "done/绿", which means a turn finished and is waiting on you, something a
# brand-new terminal never did. Only
# "clear" (and "startup" — a fresh claude on a tty a prior session left a title on)
# should reset; "resume"/"compact" keep working on the same conversation, so their
# title is still meaningful.
if [ "$action" = "session-start" ]; then
  source=$(printf '%s' "$input" | /usr/bin/python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('source', ''))
except Exception: pass
" 2>/dev/null)
  case "$source" in
    clear|startup)
      # UI reset (both clear AND startup): drop the stale title/step, wipe the
      # background-agent ledger and the captured context occupancy, go idle (灰).
      # push-at-* goes too: otherwise a fresh session's first "needs" can land inside
      # the previous session's 30s debounce window and get silently swallowed.
      rm -f "$dir/title-$tty" "$dir/step-$tty" "$bgfile" "$dir/ctx-$tty" \
            "$dir/title-ai-used-$tty" "$dir/title-ai-stamp-$tty" "$dir/tp-$tty" \
            "$dir/tick-$tty" "$dir/agents-$tty" "$dir/agent-step-$tty-"* \
            "$dir/push-at-$tty-"*
      atomic_write "$dir/state-$tty" "idle"
      ;;
  esac
  # Counting boundary for the row's ⏱ time / ◆ tokens — stamped ONLY on a real /clear
  # (T185; T86 had dropped it entirely, see docs/row-display.md). Everything else on
  # that row already resets above (title, step, ctx %, agent ledger, state), so leaving
  # the two counters running made one row assert both "this conversation just started
  # (0%)" and "2.4h / 3.2M tokens spent" — that split is what reads as a broken number.
  # ★ NEVER stamp on "startup": reconnects and subagents fire it constantly, and doing
  # so is exactly what lopped the count back to ~0 forever (the old session-<tty> bug).
  # A fresh startup gets a new pid anyway, so processStartEpoch already zeroes it.
  if [ "$source" = "clear" ]; then
    atomic_write "$dir/clear-boundary-$tty" "$(date +%s)"
  fi
  exit 0
fi

# Universal stale-ledger sweep — runs on EVERY non-SessionStart hook event, not just the
# idle_prompt ping where this judgment used to live. The retire path (a task-notification
# wake-up's UserPromptSubmit dropping the matching <task-id>) only fires when the wake-up
# spawns a NEW turn; if the notification lands while the main turn is still busy it's
# merely injected into that turn's context and no UserPromptSubmit hook runs, so the id
# never retires — killed agents, and agents that finish mid-turn, leak into the ledger. A
# continuously busy session also never reaches the idle_prompt branch, so its zombies
# pinned the row at working forever. An id whose heartbeat froze >600s died without ever
# pairing a wake-up and will never retire → drop it. A mis-drop self-heals twice over: a
# straggler's wake-up re-logs a run and repaints the row, and the self-heal in the
# PreToolUse branch below puts a still-working agent straight back on the books.
#
# ★ Judged PER ID, not for the ledger as a whole (改这块前必读). The old judgment aged
# the bg-<tty> FILE: one mtime for every id at once. Two ways that misreads reality, and
# they pull in opposite directions — ① any fresh launch rewrites the file, so ids that
# leaked minutes ago look brand new and zombies survive indefinitely in a session that
# keeps spawning agents (the phantom 🤖 count that never drains); ② a single agent that
# legitimately runs past 600s takes the WHOLE ledger down with it, live siblings
# included, since the sweep deleted the ledger, the roster and every step file wholesale.
# Each id now carries its own heartbeat, most trustworthy first:
#   1. agent-step-<tty>-<id> mtime — rewritten on EVERY tool call that agent makes, so a
#      genuinely working agent refreshes it constantly no matter how long it runs;
#   2. the roster's start stamp — for an agent that hasn't called a tool yet;
#   3. the ledger mtime — last resort, the old behavior.
# Only ids whose own heartbeat froze >600s are dropped; live ones stay on the books.
if [ -s "$bgfile" ]; then
  _now=$(date +%s); _agf="$dir/agents-$tty"; _keep=""; _drop=""
  while IFS= read -r _id; do
    [ -z "$_id" ] && continue
    _sf="$dir/agent-step-$tty-$_id"
    _last=$(stat -f %m "$_sf" 2>/dev/null)
    [ -z "$_last" ] && _last=$(grep -o "\"id\":\"$_id\"[^}]*\"start\":[0-9]*" "$_agf" 2>/dev/null \
                                | sed 's/.*"start"://' | head -1)
    [ -z "$_last" ] && _last=$(stat -f %m "$bgfile" 2>/dev/null || echo 0)
    if [ $(( _now - _last )) -gt 600 ]; then
      _drop="$_drop $_id"; rm -f "$_sf"
    else
      _keep="$_keep$_id
"
    fi
  done < "$bgfile"
  if [ -n "$_drop" ]; then
    if [ -n "$_keep" ]; then
      printf '%s' "$_keep" > "$bgfile.$$.tmp" && mv -f "$bgfile.$$.tmp" "$bgfile"
    else
      rm -f "$bgfile"
      # Nothing left in flight: surface the turn's REAL outcome, done (绿). The Stop this
      # ledger was holding open already happened, so completion — not interruption — is
      # the truth, and it keeps the idle_prompt else-branch below from misreading a
      # just-swept zombie as paused. With survivors still on the books the row is left
      # alone; their Stop verdict still stands.
      atomic_write "$dir/state-$tty" "done"
    fi
    for _d in $_drop; do
      [ -f "$_agf" ] || break
      grep -v "\"id\":\"$_d\"" "$_agf" > "$_agf.$$.tmp" 2>/dev/null
      mv -f "$_agf.$$.tmp" "$_agf"
    done
    [ -f "$_agf" ] && [ ! -s "$_agf" ] && rm -f "$_agf"
  fi
fi

# Resolve the state and write it FIRST — before the (slow) title derivation below —
# so the menu-bar app's FSEvents watcher flips the row the instant Claude asks. The
# title step spins up python (~hundreds of ms cold); doing it before the state write
# is what made the red "needs" lag behind the actual prompt.
state="$action"
if [ "$action" = "needs" ]; then
  # Two events map to this action, and they differ in latency by SECONDS:
  #
  #   PermissionRequest — fires the instant the permission dialog appears. This is
  #     the real-time, ground-truth "needs" signal and the one we prefer. Its payload
  #     carries no .message to grep; by definition it IS a permission request, so flip
  #     to needs (红) unconditionally. Fast `case` match on the raw payload — no python,
  #     no grep, on this latency-critical path.
  #
  #   Notification — Claude Code DEBOUNCES this (it lags the on-screen prompt by ~2-4s),
  #     so it's only a FALLBACK for older Claude Code that lacks PermissionRequest. It
  #     also double-duties as the idle "waiting for your input" ping, which is NOT a
  #     completion: it fires while a session merely sits idle, so writing "done" here
  #     would repaint a quiet row green 完成 out of nowhere (the "闲置突然变绿" bug).
  #     Stop already owns "done", so on the idle ping we preserve the current state and
  #     exit before the state write below. Only an explicit permission/approval message
  #     becomes needs.
  case "$input" in
    *'"hook_event_name":"PermissionRequest"'*|*'"hook_event_name": "PermissionRequest"'*)
      state="needs" ;;
    *)
      if printf '%s' "$input" | grep -qiE 'needs your (permission|approval)'; then
        # Modern Claude Code sends BOTH events for one dialog: PermissionRequest
        # instantly, then this debounced Notification ~6s later. Re-writing needs on
        # the echo is pure harm: it replays the 提示音, double-counts the decision
        # stat, and — worst — bumps the state file's mtime, which is the App's
        # time-guard baseline ("tool shell must have started AFTER needs"). If you
        # already confirmed inside that 6s window, the running command's shell now
        # predates the fresh mtime, the guard rejects it, the row snaps back from
        # 运行中(蓝) to 需确认(红) and a SECOND red toast fires (the 「每次弹两次」bug).
        # Only write when the row isn't already red — i.e. when this really is the
        # fallback for an old Claude Code that never sent PermissionRequest.
        [ "$(cat "$dir/state-$tty" 2>/dev/null)" = "needs" ] && exit 0
        state="needs"
      else
        # Idle ping (notification_type=idle_prompt, "Claude is waiting for your input"):
        # fires ~60s after the session comes to rest at the REAL input prompt — and never
        # while a permission dialog is pending (verified: a dialog parked >2min drew zero
        # idle pings). That makes it the interrupt-recovery signal: pressing Esc on a
        # dialog (or mid-turn) emits NO hook at all — no Stop, no PostToolUse — so the
        # row would stay red/blue forever. An idle ping arriving while the state file
        # still says needs/working proves that state is stale — the turn was interrupted
        # (cmd+c/Esc) and did NOT complete → flip to paused (洋红「暂停」), distinct from a
        # real Stop's done (绿). Any other current state (done/idle) preserves the old
        # behavior — exit without writing, so a quiet row never repaints out of nowhere
        # (the 闲置突然变绿 bug).
        case "$input" in
          *'"notification_type":"idle_prompt"'*|*'"notification_type": "idle_prompt"'*)
            # A non-empty bg-<tty> ledger means the turn Stopped only to WAIT on a
            # background subagent. Per T54 that is NOT "busy" — the main loop is free,
            # you can talk to Claude directly — so DON'T repaint the row working (蓝).
            # Preserve the current state (a real Stop already wrote done 绿; the 🤖 ×N
            # badge carries "agents still in flight"). Also must NOT flip to paused here:
            # a running subagent isn't an interrupt (that was the "subagent 在跑却显示暂停"
            # bug). Stale zombies are handled by the universal sweep at the top of the
            # script, so a non-empty ledger here is genuinely a live subagent → leave the
            # row as-is (done). Only when NOTHING is pending does a ping become the
            # interrupt signal: a stale needs/working then proves the turn was interrupted
            # (Esc/cmd+c emits no hook) → flip to paused, distinct from a real Stop's
            # done (绿). Any other current state (done/idle) exits without writing so a
            # quiet row never repaints out of nowhere (the 闲置突然变绿 bug).
            if [ -s "$bgfile" ]; then
              exit 0
            else
              case "$(cat "$dir/state-$tty" 2>/dev/null)" in
                needs|working) state="paused" ;;
                *) exit 0 ;;
              esac
            fi ;;
          *) exit 0 ;;
        esac
      fi ;;
  esac
elif [ "$action" = "working" ]; then
  # PreToolUse for a tool that STOPS and waits on you — AskUserQuestion (confirm a
  # direction) or ExitPlanMode (approve a plan) — means it's your turn the instant the
  # tool fires, long before Claude Code's delayed idle notification would say so. Flip
  # straight to needs (红) so "等你确认" is real-time, not just permission prompts.
  # Gate on hook_event_name=PreToolUse: the matching PostToolUse fires with the same
  # tool_name once you've answered, and that one must fall through to working (蓝).
  # Fast string match on the raw payload — no python on this every-tool-call path.
  case "$input" in
    *'"hook_event_name":"PreToolUse"'*|*'"hook_event_name": "PreToolUse"'*)
      case "$input" in
        *'"tool_name":"AskUserQuestion"'*|*'"tool_name": "AskUserQuestion"'* \
        |*'"tool_name":"ExitPlanMode"'*|*'"tool_name": "ExitPlanMode"'*)
          state="needs" ;;
      esac ;;
  esac
elif [ "$action" = "done" ]; then
  # Stop = the main turn ended → done (绿), ALWAYS — the state file carries only the
  # five hook states, so a turn parked on background subagents writes done here too and
  # the COLOR decision is made app-side: a non-empty bg-<tty> makes that row 等待/await
  # (青「等它自己回来」) instead of 完成 (T314). Writing working/蓝 here (the pre-T54 code)
  # would be the other lie — a backgrounded agent does not hold the main loop, you can
  # talk to Claude while it runs. The ledger is KEPT untouched — the app reads it for the
  # await decision and the 🤖 ×N badge, and the retire/sweep paths still need it.
  :
fi

atomic_write "$dir/state-$tty" "$state"

# Diagnostic trace (toggle: `touch ~/.claude/spectix/.trace-on` to enable, `rm` it
# to disable — zero cost when off). One line per hook invocation that writes state, so
# a stuck-color row can be diagnosed by replaying the real event ordering + tool names.
if [ -f "$dir/.trace-on" ]; then
  tr_ev=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name":[ ]*"\([^"]*\)".*/\1/p')
  tr_tool=$(printf '%s' "$input" | sed -n 's/.*"tool_name":[ ]*"\([^"]*\)".*/\1/p')
  printf '%s tty=%s action=%s state=%s ev=%s tool=%s\n' \
    "$(/bin/date '+%H:%M:%S')" "$tty" "$action" "$state" "$tr_ev" "$tr_tool" >> "$dir/trace.log"
fi

# Play a distinct sound on the two states the user cares about — but NO visual
# notification. The SpectiX app already shows its own clickable Toast banner
# on these same transitions; a second macOS notification here would double up.
# The sound is user-configurable from the app's Settings window, which writes the
# chosen /System/Library/Sounds name (bare, e.g. "Glass") to sound-done / sound-needs,
# or "off" to silence that state. Defaults: done → Glass (清亮，完成); needs → Funk
# (低沉，提醒). Backgrounded so afplay never blocks the hook's 5s timeout.
play_state_sound() { # $1=state-file-suffix  $2=default-sound-name
  local name vol
  name=$(cat "$dir/sound-$1" 2>/dev/null | tr -d ' \n')
  name="${name:-$2}"
  [ "$name" = "off" ] && return
  # Playback volume (0…1), user-set from Settings (sound-volume). Absent → full.
  vol=$(cat "$dir/sound-volume" 2>/dev/null | tr -d ' \n')
  vol="${vol:-1}"
  afplay -v "$vol" "/System/Library/Sounds/$name.aiff" >/dev/null 2>&1 &
}

# Buzz the user's Apple Watch. A local macOS notification can NOT reach a Watch —
# watchOS only mirrors notifications the paired iPhone got, and a Mac is not in that
# chain at all. So the wrist is reached the long way round: here → Bark's server →
# APNs → iPhone → mirror → Watch. Off unless the user pasted a device key in Settings.
#
# Two things this must never do: block, or fail loudly. The hook has a 5s budget that
# afplay and the state write share, and a push that can't go out is not worth telling
# anyone about mid-turn — Settings shows the last result instead (push-last).
push_watch() { # $1=state (needs|done)
  local key server body title
  key=$(cat "$dir/push-key" 2>/dev/null | tr -d ' \n')
  [ -z "$key" ] && return
  server=$(cat "$dir/push-server" 2>/dev/null | tr -d ' \n')
  server="${server:-https://api.day.app}"
  # done only buzzes if the user asked for it: `needs` blocks the agent, `done` is
  # just news, and buzzing on every turn end is how the whole feature gets switched off.
  if [ "$1" = "done" ]; then
    [ "$(cat "$dir/push-done" 2>/dev/null | tr -d ' \n')" = "1" ] || return
  fi
  # Debounce per tty+state: APNs coalesces rapid pushes to one device (so extras are
  # DROPPED, not queued), and a flapping session would otherwise buzz the wrist raw.
  local stamp now last
  stamp="$dir/push-at-$tty-$1"
  now=$(/bin/date +%s)
  last=$(cat "$stamp" 2>/dev/null | tr -d ' \n')
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt 30 ] && return
  printf '%s' "$now" > "$stamp"

  # Row title (project/branch the user named this terminal) if we have one, so the
  # wrist says WHICH session wants them — with N sessions running, "SpectiX" alone
  # is useless. Falls back to the tty.
  # `cut -c` counts BYTES under LC_ALL=C, and the hook's locale is whatever Claude Code
  # happened to have — so a CJK title gets sliced mid-character and the JSON body ends
  # in an invalid UTF-8 sequence that Bark then rejects. iconv -c drops that stub.
  body=$(cat "$dir/title-$tty" 2>/dev/null | head -1 | tr -d '\n' | cut -c1-60 \
         | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
  body="${body:-$tty}"
  # JSON-escape by hand rather than shelling out to python: this runs on the same
  # path as the color flip, and /usr/bin/python3 both costs ~50ms and can pop the
  # Command Line Tools installer on a machine that has never had it. A title is
  # plain text, so backslash + quote + stray control bytes is the whole exposure.
  body=$(printf '%s' "$body" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [ "$1" = "needs" ]; then title="需要确认"; else title="已完成"; fi
  # POST JSON, not Bark's GET /<key>/<title>/<body> form: titles carry spaces, slashes,
  # CJK and emoji, and the URL-path form makes every one of those an encoding bug.
  # `level=timeSensitive` is what gets through Focus/勿扰 — which is exactly when the
  # user is away from the keyboard and needs this most. Never `critical`: that pierces
  # the ringer switch, and one 3am alarm over "turn finished" and the app is uninstalled.
  local json
  json=$(printf '{"title":"SpectiX · %s","body":"%s","group":"SpectiX","level":"timeSensitive"}' \
                "$title" "$body")
  {
    if curl -sS -m 3 -X POST "$server/$key" \
         -H 'Content-Type: application/json; charset=utf-8' \
         -d "$json" >/dev/null 2>&1; then
      printf 'ok %s' "$(/bin/date +%s)" > "$dir/push-last"
    else
      printf 'fail %s' "$(/bin/date +%s)" > "$dir/push-last"
    fi
  } &
}

case "$state" in
  done)
    # A non-empty ledger means this Stop is NOT a completion: the main turn only parked
    # while background subagents keep running, and the app paints that row 等待/await
    # rather than 完成 (T314). Ringing the completion chime there is the same lie in
    # sound that the green dot was on screen — and it fires once per agent batch, which
    # is how the chime gets switched off entirely. The turn that ends AFTER the last
    # agent returns finds an empty ledger and rings then, which is the beat the user
    # actually waits for. Background Bash commands (T312's await) are NOT covered here:
    # they leave no ledger entry, only a live shell the app discovers by probing.
    [ -s "$bgfile" ] || { play_state_sound done Glass; push_watch done; } ;;
  needs) play_state_sound needs Funk; push_watch needs ;;
esac

# --- Live step label: what a WORKING session is doing right now ----------------
# The app shows this beneath the row title while 运行中, so you can tell "editing
# main.swift" from "running git push" without opening the terminal. Off the critical
# path (state already written); pure sed, no python, so it never delays the color
# flip even though PreToolUse fires on every tool call. PreToolUse carries tool_name
# + tool_input — distill a short "Tool · detail". Cleared at turn start
# (UserPromptSubmit, no tool yet) and end (done) so a stale step never lingers into
# the next turn. Length is capped app-side (grapheme-safe), so we write it whole.
jval() { printf '%s' "$input" | sed -n "s/.*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

# --- Live transcript pointer (tp-<tty>) ---------------------------------------
# EVERY event's payload carries transcript_path; stamp it so the app can tail that
# file itself and read the model the session is on RIGHT NOW. Without it the only
# model signal was the turn-end `done` event, so a /model switch didn't show on the
# row until the whole turn finished (and a fresh tab showed nothing at all). One
# tiny write, off the critical path — the app does the reading.
tp=$(jval transcript_path)
[ -n "$tp" ] && atomic_write "$dir/tp-$tty" "$tp"

case "$action" in
  done)
    if [ -s "$bgfile" ]; then
      # Turn end rewritten to working (bg agents pending): show why the row is busy.
      # The subagent's own PreToolUse events overwrite this with its live tool step.
      atomic_write "$dir/step-$tty" "Agent · 后台任务运行中"
    else
      rm -f "$dir/step-$tty"
    fi ;;
  working)
    case "$input" in
      *'"hook_event_name":"UserPromptSubmit"'*|*'"hook_event_name": "UserPromptSubmit"'*)
        rm -f "$dir/step-$tty" ;;
      *'"hook_event_name":"PreToolUse"'*|*'"hook_event_name": "PreToolUse"'*)
        tool=$(jval tool_name)
        detail=""
        case "$tool" in
          Read|Edit|Write|NotebookEdit) fp=$(jval file_path); detail="${fp##*/}" ;;
          Bash)       detail=$(jval description) ;;  # command is multi-line/quoted → too messy for a label
          Grep|Glob)  detail=$(jval pattern);     [ -z "$detail" ] && detail=$(jval query) ;;
          Task|Agent) detail=$(jval subagent_type); [ -z "$detail" ] && detail=$(jval description) ;;
          WebSearch)  detail=$(jval query) ;;
          WebFetch)   detail=$(jval url) ;;
        esac
        detail=$(printf '%s' "$detail" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
        step="$tool"
        [ -n "$detail" ] && step="$tool · $detail"
        [ -n "$step" ] && atomic_write "$dir/step-$tty" "$step"
        # A tool call fired by a background subagent carries agent_id (== the ledgered
        # agentId) — mirror the step into that agent's own file so the expanded agent
        # sublist can show what EACH agent is doing. The shared step-<tty> write above
        # keeps its existing behavior (the row's subtitle follows the latest activity).
        aid=$(jval agent_id)
        if [ -n "$aid" ]; then
          atomic_write "$dir/agent-step-$tty-$aid" "$step"
          # ★ Self-heal the books (改这块前必读). This event is PROOF the agent is
          # alive — it just called a tool. If it isn't on the ledger, the launch-time
          # bookkeeping is gone, and nothing downstream ever rebuilds it: the roster is
          # written ONLY at launch, so a row lost to a missed launch, a SessionStart
          # wipe, or a stale sweep stays lost for the agent's whole remaining life. The
          # symptom is an ORPHAN agent-step-<tty>-<id> ticking away with no bg-<tty> and
          # no agents-<tty> beside it — an agent visibly working that the app cannot
          # show, because backgroundAgents() reads the roster and nothing else. Re-add
          # it here and the sublist recovers on the agent's very next tool call,
          # whatever lost it. Inert on the normal path: a ledgered id matches and this
          # whole block is skipped, so the common case costs one grep.
          if ! grep -qxF "$aid" "$bgfile" 2>/dev/null; then
            printf '%s\n' "$aid" >> "$bgfile"
            agf="$dir/agents-$tty"
            # A subagent's own tool events carry agent_type; description was only ever
            # in the launch payload, which is exactly what we lost, so desc stays empty
            # and the sublist falls back to the type.
            atype=$(jval agent_type | tr -d '\\"')
            # Recover the REAL start instead of stamping now: the agent's transcript is
            # created at launch, so its birth time is the true elapsed-time baseline.
            # Stamping now would restart every recovered agent's ⏱ from zero.
            astart=""
            ptp=$(cat "$dir/tp-$tty" 2>/dev/null)
            [ -n "$ptp" ] && astart=$(stat -f %B "${ptp%.jsonl}/subagents/agent-$aid.jsonl" 2>/dev/null)
            [ -z "$astart" ] && astart=$(date +%s)
            # Drop any stale row for this id first, so recovery can't duplicate it.
            [ -f "$agf" ] && { grep -v "\"id\":\"$aid\"" "$agf" > "$agf.$$.tmp" 2>/dev/null; mv -f "$agf.$$.tmp" "$agf"; }
            printf '{"id":"%s","type":"%s","desc":"","model":"","start":%s}\n' \
              "$aid" "$atype" "$astart" >> "$agf"
          fi
        fi
        ;;
    esac ;;
esac

# --- Background-agent ledger maintenance (off the critical path) ---------------
# Add: async Agent/Task launch acknowledges instantly — PostToolUse carries the
# agentId that the eventual task-notification will echo back as <task-id>. Retire:
# that wake-up arrives as a synthetic UserPromptSubmit; drop the matching id. A
# repeat notification for an already-retired id (agents can be resumed and stop
# again) is a no-op, as is a background-Bash task-notification (id never ledgered).
case "$input" in
  *'"hook_event_name":"PostToolUse"'*|*'"hook_event_name": "PostToolUse"'*)
    case "$input" in
      *'"tool_name":"Agent"'*|*'"tool_name": "Agent"'* \
      |*'"tool_name":"Task"'*|*'"tool_name": "Task"'*)
        # An Agent/Task PostToolUse that carries an agentId IS an async launch: it
        # returns instantly and wakes the session later via a task-notification whose
        # <task-id> == this agentId. Gate on the agentId's PRESENCE, NOT on a
        # run_in_background:true flag — this harness runs every Agent/Task async but its
        # PostToolUse does NOT echo run_in_background, so the old flag-gate matched none
        # of them: the ledger stayed empty and the main turn's Stop painted premature
        # done (绿「完成」) while the subagents were still running (the "一个 subagent
        # 完成就弹 complete" bug). The retire below keys off the same id, so anything we
        # add here gets retired when it wakes.
        bid=$(jval agentId)
        # ...but an agentId alone no longer proves the launch was ASYNC. A synchronous
        # Agent call (run_in_background:false) blocks until the agent finishes and then
        # returns the same agentId — already done, and no task-notification will ever
        # arrive to retire it. Ledgering one strands a phantom "运行中" agent (and an
        # inflated 🤖 ×N) until the stale sweep clears it ~10min later. The launch's
        # tool_response distinguishes them: "async_launched" vs "completed" (verified
        # against both live payloads, 2026-08-04).
        # async_launched is checked FIRST and wins: the payload echoes the launch prompt
        # verbatim, so a prompt that merely mentions "status":"completed" must not be
        # able to disown a genuinely async launch.
        case "$input" in
          *'"status":"async_launched"'*|*'"status": "async_launched"'*) ;;
          *'"status":"completed"'*|*'"status": "completed"'*) bid="" ;;
        esac
        if [ -n "$bid" ]; then
          printf '%s\n' "$bid" >> "$bgfile"
          # Agent roster for the expandable sublist: one JSON line per agent
          # {id,type,desc,start} — type/desc from the launch's tool_input
          # (subagent_type / description), start for the elapsed-time column.
          # Retire below DELETES the line — a finished agent is not shown at all — so
          # this prune only sweeps `end`-stamped leftovers written by an older hook.
          # Sanitize type/desc for hand-built JSON (strip backslash + quote).
          atype=$(jval subagent_type | tr -d '\\"')
          adesc=$(jval description | tr -d '\\"')
          # The launch's explicit model override ("opus"/"sonnet"/"haiku"), when the
          # caller passed one. Absent for the common case — the agent then inherits the
          # session's model, which the app fills in from the parent row.
          amodel=$(jval model | tr -d '\\"')
          agf="$dir/agents-$tty"
          # Also drop any row that already carries this id, so the append below can't
          # duplicate it. One PostToolUse can reach this script twice when the hooks are
          # wired in BOTH places at once (~/.claude/settings.json from the installer AND
          # the plugin distribution) — the bg ledger tolerates that (retire is grep -vxF,
          # which strips every copy), but the roster is what the sublist renders, so a
          # second copy would show the same agent twice. Inert on the normal path: a
          # fresh id matches nothing.
          if [ -f "$agf" ]; then
            awk -v bid="$bid" '{
              if (index($0, "\"id\":\"" bid "\"")) next
              if (match($0, /"end":[0-9]+/)) next
              print }' "$agf" > "$agf.$$.tmp" && mv -f "$agf.$$.tmp" "$agf"
          fi
          printf '{"id":"%s","type":"%s","desc":"%s","model":"%s","start":%s}\n' \
            "$bid" "$atype" "$adesc" "$amodel" "$(date +%s)" >> "$agf"
        fi ;;
    esac ;;
  *'"hook_event_name":"UserPromptSubmit"'*|*'"hook_event_name": "UserPromptSubmit"'*)
    case "$input" in
      *'<task-id>'*)
        if [ -s "$bgfile" ]; then
          # A batched wake-up can carry MULTIPLE <task-id> blocks (several agents that
          # finished while the session was busy get delivered in one UserPromptSubmit).
          # Retire EVERY id present, not just the last one — the old single-sed grabbed
          # only the final <task-id>, leaving the others stuck in the ledger (row stuck
          # blue forever). grep -oE pulls each block; strip the tags to bare ids.
          ids=$(printf '%s' "$input" | grep -oE '<task-id>[^<]*</task-id>' | sed 's/<[^>]*>//g')
          if [ -n "$ids" ]; then
            grep -vxF "$ids" "$bgfile" > "$bgfile.$$.tmp" 2>/dev/null
            mv -f "$bgfile.$$.tmp" "$bgfile"
            [ -s "$bgfile" ] || rm -f "$bgfile"
          fi
          # Roster retire: DELETE each returned agent's line and its live-step file, so
          # the sublist holds running agents only. (It used to stamp `end` and keep the
          # row as "✓ 已返回" until a later launch pruned it — on a session that launches
          # nothing else, that row never went away.) The app also drops an agent whose own
          # transcript ended the turn, which is what makes it vanish immediately; this
          # path is the ledger catching up. Rare (one wake-up per batch), so python is
          # fine here. An emptied roster file is removed, not left as a 0-byte file.
          agf="$dir/agents-$tty"
          if [ -f "$agf" ]; then
            printf '%s' "$input" | AGF="$agf" STEPPRE="$dir/agent-step-$tty-" /usr/bin/python3 -c '
import sys, os, re, json
inp = sys.stdin.read()
done = set(re.findall(r"<task-id>([^<]+)</task-id>", inp))
if done:
    agf = os.environ["AGF"]
    out = []
    try:
        with open(agf) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: d = json.loads(line)
                except Exception: continue
                if d.get("id") in done:
                    try: os.remove(os.environ["STEPPRE"] + d["id"])
                    except OSError: pass
                    continue
                # Survivors go back VERBATIM. Re-dumping them would respace the JSON
                # ("id": "x" instead of "id":"x") and the shell paths that match these
                # lines literally — the stale sweep and the launch de-dupe — would then
                # miss them.
                out.append(line)
        if out:
            tmp = agf + "." + str(os.getpid()) + ".tmp"
            with open(tmp, "w") as f: f.write("".join(o + "\n" for o in out))
            os.replace(tmp, agf)
        else:
            os.remove(agf)
    except Exception: pass
' 2>/dev/null
          fi
        fi ;;
    esac ;;
esac

# Derive a human-readable session title so the app can label the row with "what this
# session is about" instead of the bare ttysNNN. Three sources cooperate:
#
#   1. Claude Code's OWN AI task summary (transcript "ai-title" events — the same
#      string it writes to the VSCode terminal tab). Measured behavior: it lands
#      asynchronously mid-session (sometimes never — many sessions have zero), is
#      generated ONCE, and is then re-appended VERBATIM forever — never recomputed
#      on a topic change. So it's checked on every event (throttled on the busy
#      PreToolUse path) for an early mid-turn upgrade, but only a NEVER-SEEN value
#      may write; title-ai-used-<tty> remembers the consumed value so a stale
#      re-append can't clobber a newer topic's title.
#   2. The user's prompt — a FALLBACK, used only until source 1 lands. Once an
#      ai-title exists the prompt never writes again: the row and the terminal tab
#      then read identically, which is what the user asked for (2026-09-03, after
#      10 of 15 live terminals disagreed with their tab). The cost is accepted and
#      real — ai-title is generated once, so neither place follows a topic change.
#      Before it lands: a substantial prompt writes; a junk/trigger prompt (jx, rr,
#      done, 好的, bare numbers typed as option answers…) may only seed a session
#      that has no title yet — never overwrite one (the "jx / 1 became the title"
#      bug).
#   3. `todo.py claim` writes the claimed task's title from the task side (not
#      here); the junk filter is what keeps it alive through the jx workflow's
#      short prompts.
#
# Deferred to here (after the state write) so none of this ever delays the row's
# color flip.
tfile="$dir/title-$tty"

# (1) ai-title upgrade — pure grep/sed, no python. Immediate on UserPromptSubmit and
# Stop; throttled to one transcript scan per 20s on the every-tool-call PreToolUse path.
ai_check=0
if [ "$action" = "done" ]; then
  ai_check=1
elif [ "$action" = "working" ]; then
  case "$input" in
    *'"hook_event_name":"UserPromptSubmit"'*|*'"hook_event_name": "UserPromptSubmit"'*)
      ai_check=1 ;;
    *)
      stampf="$dir/title-ai-stamp-$tty"
      if [ $(( $(date +%s) - $(stat -f %m "$stampf" 2>/dev/null || echo 0) )) -ge 20 ]; then
        touch "$stampf"
        ai_check=1
      fi ;;
  esac
fi
if [ "$ai_check" = 1 ]; then
  # $tp was already parsed above (the tp-<tty> pointer block) — same payload field.
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    ai=$(grep -E '"type": ?"ai-title"' "$tp" 2>/dev/null | tail -1 \
         | sed -n 's/.*"aiTitle":[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$ai" ] && [ "$ai" != "$(cat "$dir/title-ai-used-$tty" 2>/dev/null)" ]; then
      atomic_write "$tfile" "$ai"
      atomic_write "$dir/title-ai-used-$tty" "$ai"
    fi
  fi
fi

# (2) prompt — gated on a REAL UserPromptSubmit (a PreToolUse tool_input can carry
# its own "prompt" key, e.g. Agent/Task launches). The python prints the cleaned
# 24-char title and signals junk via exit 3.
case "$action:$input" in
  *:*'"prompt":"<task-notification>'*|*:*'"prompt": "<task-notification>'*)
    ;;  # background-task wake-up, not the user — keep the real task title
  working:*'"hook_event_name":"UserPromptSubmit"'*|working:*'"hook_event_name": "UserPromptSubmit"'*)
    title=$(printf '%s' "$input" | /usr/bin/python3 -c "
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: d = {}
p = ' '.join((d.get('prompt') or '').split())
if not p or p.startswith('<task-notification>') or p.startswith('<cross-session-message'): sys.exit(0)
# The editor chat panel prepends IDE context the EXTENSION injects, not text the user
# typed: <ide_opened_file>…</ide_opened_file>, <ide_selection>…, and friends. Terminal
# sessions never carry these, which is why this gate didn't exist before the chat panel
# was wired up (T142) — without it the row title reads '<ide_opened_file>The use'.
# Strip every leading <tag>…</tag> block; what remains is the real prompt, often empty.
# The opening tag may carry ATTRIBUTES: a cross-session message arrives as
# <cross-session-message from="uds:/tmp/cc-socks/40377.sock" …>, and an attribute-less
# pattern left it unstripped — every row that received one read
# '<cross-session-message f' (2026-09-12). Such a message is another session talking,
# not this one's topic, so it also bails outright above, like <task-notification>.
p = re.sub(r'^(?:<([a-z_][a-z0-9_-]*)(?:\\s[^>]*)?>.*?</\\1>\\s*)+', '', p).strip()
if not p: sys.exit(0)
# A dragged-in file is not a topic. A screenshot dropped into the prompt arrives as an
# absolute path -- quoted when it holds spaces, backslash-escaped otherwise -- and being
# long and nothing like a trigger word it sails straight past the junk gate below: the
# row then reads '/var/folders/2c/hsqx8tg while the terminal tab still names the real
# topic. Strip absolute paths wherever they sit; two segments minimum so a slash command
# (/task, /jx) is not mistaken for one. Often nothing is left -> keep the current title.
p = ' '.join(re.sub(r'\x27/[^\x27]*/[^\x27]*\x27|(?<!\\S)/(?:\\\\ |[^\\s/])+(?:/(?:\\\\ |[^\\s/])*)+', ' ', p).split())
if not p: sys.exit(0)
print(p[:24])
# Junk = too short to describe anything, or a workflow trigger word carrying at most
# a short argument (jx T37 / pr main / task u / bash check / bare option numbers).
junk = len(p) < 4 or re.match(
    r'(?i)^(jx|rr|done|ok|okay|y|yes|n|no|好的?|继续|测试|ts|check|bash check|'
    r'task|pr|amend|tosandbox|release|发布|build app|[0-9]{1,3})'
    r'([\\s,，.。!！?？:：].{0,6})?$', p)
sys.exit(3 if junk else 0)
" 2>/dev/null)
    rc=$?
    if [ -n "$title" ]; then
      if [ -s "$dir/title-ai-used-$tty" ]; then
        # Claude Code has already named this session, and that same string is what the
        # VSCode terminal tab shows. The row now defers to it so both places read
        # identically -- see the ai-title note above for what that costs.
        :
      elif [ "$rc" -eq 3 ]; then
        # trigger/junk prompt: only seed a session that has no title at all
        [ -s "$tfile" ] || atomic_write "$tfile" "$title"
      else
        # no ai-title yet -- the prompt is the only topic signal there is
        atomic_write "$tfile" "$title"
      fi
    fi
    ;;
esac

# --- Usage log (append-only, off the critical path) --------------------------
# Append one JSONL line per event worth counting to events.jsonl, so the app's
# stats window can tally — per day and per project — how many task runs you
# kicked off and how many decisions you had to make. Placed dead last so it never
# delays the row's color flip. `state` was already resolved above; map it:
#   state = needs                          -> "decision" (each permission/plan/question)
#   action = working + event=UserPrompt... -> "run"      (one per new user turn = one task)
#   action = done                          -> "done"     (turn completed)
#   action = working + any other tool event-> "tick"     (heartbeat, ≤1 per 60s per tty)
# The run gate matches hook_event_name, NOT a bare "prompt" substring: a PreToolUse
# for a tool that carries its own tool_input.prompt (e.g. Task/Agent) also fires as
# "working" and would over-count runs. Idle pings already exited.
# O_APPEND makes each one-line write atomic across ttys.
#
# ★ Why the heartbeat exists (T146, 改这块前必读): the app no longer measures a turn as
# run.ts→done.ts — that's how long the turn was OPEN, which billed a permission prompt
# left up overnight as 20 hours of work. It now sums the gaps BETWEEN pulses, capping
# each one (see WorkClock in Stats.swift). Without a pulse from ordinary tool calls, a
# fully allowlisted turn would emit only run and done and get capped down to minutes,
# so every PreToolUse/PostToolUse that isn't already logging something pulses instead —
# throttled to one per 60s per tty (the stamp file claims the window BEFORE the write,
# so a busy turn costs ~60 log lines an hour, not one per tool call).
log_event=""
case "$state" in
  needs) log_event="decision" ;;
  *)
    if [ "$action" = "done" ]; then
      log_event="done"
    elif [ "$action" = "working" ]; then
      case "$input" in
        *'"hook_event_name":"UserPromptSubmit"'*|*'"hook_event_name": "UserPromptSubmit"'*)
          # A task-notification wake-up also logs a run ON PURPOSE: the app opens a new
          # work segment at each run, and the resumed segment needs its opener.
          log_event="run" ;;
        *)
          tickf="$dir/tick-$tty"
          if [ $(( $(date +%s) - $(stat -f %m "$tickf" 2>/dev/null || echo 0) )) -ge 60 ]; then
            : > "$tickf"
            log_event="tick"
          fi ;;
      esac
    fi ;;
esac

if [ -n "$log_event" ]; then
  printf '%s' "$input" | EV="$log_event" TTY="$tty" DIR="$dir" /usr/bin/python3 -c '
import sys, json, os, time
try: d = json.load(sys.stdin)
except Exception: d = {}
cwd = (d.get("cwd") or "").rstrip("/")
project = cwd.rsplit("/", 1)[-1] if cwd else "unknown"
title = " ".join((d.get("prompt") or "").split())[:80]
rec = {"ts": int(time.time()), "date": time.strftime("%Y-%m-%d"),
       "event": os.environ["EV"], "project": project or "unknown",
       "cwd": cwd, "tty": os.environ["TTY"], "title": title}

# Unattended rounds are spawned by todo-autorun.py, which exports AUTORUN_OWNER into
# the environment of each round; this hook inherits it. Without this stamp an overnight
# queue is indistinguishable from hand-typed work, because a spawned `claude -p` has no
# tty of its own and borrows the one autorun was launched from — so a night of autorun
# lands entirely on whichever terminal happened to start it.
if os.environ.get("AUTORUN_OWNER"):
    rec["auto"] = 1

# On turn completion, tally THIS turn'"'"'s token usage from the transcript. The Stop
# payload carries transcript_path; it points at a real file only when the session
# actually saves one (sessions that inherit CLAUDE_CODE_CHILD_SESSION are treated as
# children and skip the write — unset it to get transcripts back). One pass over the
# file, resetting at every genuine user prompt, leaves the last turn standing.
# Defensive throughout: a missing transcript just omits the token fields.
if os.environ["EV"] == "done":
    tp = d.get("transcript_path") or ""
    if tp and os.path.exists(tp):
        try:
            turn = {}   # requestId -> usage (the one with the largest output_tokens)
            model = ""  # last assistant model seen this turn — drives cost estimation
            ctx_usage = {}  # LAST assistant usage in the whole file → current context occupancy
            with open(tp) as tf:
                for line in tf:
                    line = line.strip()
                    if not line: continue
                    try: e = json.loads(line)
                    except Exception: continue
                    t = e.get("type")
                    if t == "user":
                        # A genuine prompt (a string, or a list with a text block) starts a
                        # new turn; a tool_result-only user turn does not. Reset on the former.
                        c = (e.get("message") or {}).get("content")
                        if isinstance(c, str) or (isinstance(c, list) and any(
                                isinstance(x, dict) and x.get("type") == "text" for x in c)):
                            turn = {}
                            model = ""
                    elif t == "assistant":
                        m = (e.get("message") or {}).get("model")
                        if m: model = m   # keep the turn'"'"'s model for the cost table
                        u = (e.get("message") or {}).get("usage") or {}
                        if not u: continue
                        ctx_usage = u   # keep overwriting → ends as the last one seen
                        # One API call streams as several assistant events sharing a
                        # requestId; only the last carries the final output_tokens. Keep the
                        # max per requestId so each call counts once (matches /stats, which
                        # otherwise over-counts 3-10x).
                        rid = e.get("requestId") or e.get("uuid") or len(turn)
                        prev = turn.get(rid)
                        if prev is None or u.get("output_tokens", 0) >= prev.get("output_tokens", 0):
                            turn[rid] = u
            us = turn.values()
            rec.update(
                tok_in=sum(u.get("input_tokens", 0) for u in us),
                tok_out=sum(u.get("output_tokens", 0) for u in us),
                tok_cache_w=sum(u.get("cache_creation_input_tokens", 0) for u in us),
                tok_cache_r=sum(u.get("cache_read_input_tokens", 0) for u in us),
                api_calls=len(turn))
            if model: rec["model"] = model
            # Current context occupancy = the input side of the LAST assistant message:
            # the fresh input tokens plus everything replayed from cache. This is the
            # window fill the app gauges — NOT the per-turn cache_read summed across
            # turns (that double-counts by api_calls). Write it to ctx-<tty> atomically.
            ctx = (ctx_usage.get("input_tokens", 0)
                   + ctx_usage.get("cache_read_input_tokens", 0)
                   + ctx_usage.get("cache_creation_input_tokens", 0))
            if ctx > 0:
                cp = os.path.join(os.environ["DIR"], "ctx-" + os.environ["TTY"])
                ctmp = cp + "." + str(os.getpid()) + ".tmp"
                with open(ctmp, "w") as cf: cf.write(str(ctx))
                os.replace(ctmp, cp)
        except Exception: pass

with open(os.path.join(os.environ["DIR"], "events.jsonl"), "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
' 2>/dev/null
fi

# --- Subscription usage snapshot (throttled, backgrounded) -------------------
# Refresh ~/.claude/spectix/usage.json so the app's header can show your Claude
# subscription usage (current session % + weekly %) and when each window resets. The
# figures come from `claude -p "/usage"` — exactly what the /usage command prints, via
# Claude Code's own auth, so they're always correct and need no token handling here.
# That call is slow (spawns a CLI, ~seconds), so guard it heavily: only on turn end
# (done), skip when the file is fresh (<120s), claim the throttle window up front so a
# failing probe doesn't retry every turn, run fully detached so the hook returns now, and
# export SPECTIX_USAGE_PROBE so the nested claude's own hooks no-op (guard at top). The
# parser exits nonzero for non-subscription output, leaving the last good file untouched.
if [ "$action" = "done" ]; then
  uf="$dir/usage.json"
  # Resolve the parser next to THIS script, not at a fixed ~/.claude/hooks path: the
  # installer puts both files there (so this resolves to the same place it always did),
  # but the plugin distribution ships them under ${CLAUDE_PLUGIN_ROOT}/hooks/, where a
  # hardcoded $HOME path would silently find nothing and drop the usage header.
  up="$(dirname "$0")/spectix-usage.py"
  [ -f "$up" ] || up="$HOME/.claude/hooks/spectix-usage.py"
  mt=$(stat -f %m "$uf" 2>/dev/null || echo 0)
  if [ "$(( $(date +%s) - mt ))" -ge 120 ]; then
    touch "$uf" 2>/dev/null
    (
      SPECTIX_USAGE_PROBE=1 claude -p "/usage" 2>/dev/null \
        | /usr/bin/python3 "$up" > "$uf.tmp" 2>/dev/null \
        && mv -f "$uf.tmp" "$uf" || rm -f "$uf.tmp"
    ) >/dev/null 2>&1 &
  fi
fi

exit 0

#!/usr/bin/env python3
"""Read-only probe: does main.swift's agentTail still recognise a finished subagent?

The 🤖 sublist drops an agent the moment agentTail sees its own transcript end the
turn: the newest assistant line carrying "usage" calls SubagentHandback, or has a
stop_reason other than "tool_use". That rule is a guess about Claude Code's on-disk
format, and it has already broken once: by 2026-10 subagents stopped ending on a
plain end_turn reply and instead make a final SubagentHandback TOOL call logged with
no stop_reason — every returned agent stayed listed as running and nothing failed,
no test, no exception, just a 🤖 line that never went away. This probe found it
(71 of 98 handed-back agents in 72h on 2026-10-11).

Ground truth comes from the PARENT transcript instead: Claude Code records each
hand-back there as a <task-notification> whose <task-id> is the agent id, and/or an
<agent-message from="<id>">. An agent the parent has heard back from, whose own
file was not written to after that hand-back (so it was not resumed), but which the
agentTail rule still calls running, is exactly the regression this probe exists for.

Usage: tools/agent-tail-probe.py [hours=48]
Exit 1 when any such agent is found; prints counts either way.
"""
import glob
import json
import os
import re
import sys
from datetime import datetime

PROJECTS = os.path.expanduser("~/.claude/projects")
WINDOW = 256 * 1024          # same tail window as lastAssistantInfo in main.swift
RESUME_SLACK = 5.0           # seconds: hand-back line and the agent's last write race


def agent_tail_finished(path):
    """Mirror of agentTail: None when unreadable, else whether the agent finished."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > WINDOW:
            f.seek(size - WINDOW)
        data = f.read().decode("utf-8", "replace")
    for line in reversed(data.split("\n")):
        if '"usage":' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        msg = d.get("message")
        if d.get("type") != "assistant" or not isinstance(msg, dict) \
                or not isinstance(msg.get("usage"), dict):
            continue
        reason = msg.get("stop_reason")
        # Swift: handedBack || (stopReason.map { $0 != "tool_use" } ?? false)
        blocks = msg.get("content") if isinstance(msg.get("content"), list) else []
        handed = any(isinstance(b, dict) and b.get("type") == "tool_use"
                     and b.get("name") == "SubagentHandback" for b in blocks)
        return handed or (reason is not None and reason != "tool_use"), reason
    return False, None


def handback_times(parent):
    """agent id -> epoch of the LAST hand-back the parent transcript recorded."""
    out = {}
    try:
        fh = open(parent, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for line in fh:
            if "<task-id>" not in line and "<agent-message from=" not in line:
                continue
            ids = set(re.findall(r'<agent-message from=\\?"([A-Za-z0-9]+)', line))
            # Only a completed/failed/killed notification is a hand-back; a progress
            # ping for a still-running task must not count.
            for m in re.finditer(r"<task-id>([A-Za-z0-9]+)</task-id>(.{0,600}?)</task-notification>",
                                 line):
                if re.search(r"<status>(completed|failed|killed|stopped)", m.group(2)):
                    ids.add(m.group(1))
            if not ids:
                continue
            try:
                ts = json.loads(line).get("timestamp", "")
                t = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except (ValueError, AttributeError):
                continue
            for i in ids:
                out[i] = max(out.get(i, 0), t)
    return out


def main():
    hours = float(sys.argv[1]) if len(sys.argv) > 1 else 48
    cutoff = datetime.now().timestamp() - hours * 3600
    files = [p for p in glob.glob(f"{PROJECTS}/*/*/subagents/agent-*.jsonl")
             if os.path.getmtime(p) >= cutoff]
    parents = {}
    checked = finished = no_reason = 0
    bad = []
    for p in files:
        real = os.path.realpath(p)
        aid = os.path.basename(p)[len("agent-"):-len(".jsonl")]
        parent = os.path.dirname(os.path.dirname(p)) + ".jsonl"
        if parent not in parents:
            parents[parent] = handback_times(parent)
        back = parents[parent].get(aid)
        if back is None:
            continue                       # never handed back (or still running): no truth
        if os.path.getmtime(real) > back + RESUME_SLACK:
            continue                       # written after the hand-back → resumed
        checked += 1
        ok, reason = agent_tail_finished(real)
        if ok:
            finished += 1
            continue
        if reason is None:
            no_reason += 1
        bad.append((p, reason))
    print(f"scanned {len(files)} subagent transcripts (last {hours:g}h); "
          f"{checked} handed back; agentTail says finished for {finished}")
    for p, reason in bad:
        print(f"STUCK  stop_reason={reason!r}  {p}")
    if bad:
        print(f"FAIL: {len(bad)} handed-back agent(s) would keep their 🤖 line "
              f"({no_reason} with no readable stop_reason) — Claude Code changed how a "
              f"subagent ends; update agentTail in main.swift (docs/session-status.md "
              f"后台 subagent 台账)")
        sys.exit(1)
    if checked == 0:
        print("WARN: no handed-back agent in the window — nothing was actually checked")
    print("OK")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""backlog-owners-lint — every queued backlog item has exactly one owners line,
and every owners line names a real session and a real item.

  backlog-owners-lint.py [backlog.md] [backlog-owners]

Owners format: `<item> <session> [hold]`, `#` comments, order = priority.
The session `hold` parks an item that has no owner yet. Exit 0 green, 1 red.
"""
import re
import sys

SESSIONS = {"advisor", "personal-vps", "orbit", "health", "kidsquest"}
PARKED = "hold"
ITEM_RE = re.compile(r"<summary><b>(\d+)\.</b>\s*([^<]*)")


def backlog_items(path):
    queued, every = [], set()
    section = None
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            section = line.strip()
        for n, _title in ITEM_RE.findall(line):
            every.add(n)
            if section and section.startswith("## Queued work"):
                queued.append(n)
    return queued, every


def owners_lines(path):
    rows, bad = [], []
    for no, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2 or len(parts) > 3 or not parts[0].isdigit():
            bad.append((no, raw.rstrip()))
            continue
        if len(parts) == 3 and parts[2] != "hold":
            bad.append((no, raw.rstrip()))
            continue
        rows.append((no, parts[0], parts[1], len(parts) == 3))
    return rows, bad


def main(argv):
    backlog = argv[1] if len(argv) > 1 else "/root/backlog.md"
    owners = argv[2] if len(argv) > 2 else "/root/backlog-owners"
    queued, every = backlog_items(backlog)
    rows, bad = owners_lines(owners)
    errs = []
    for no, raw in bad:
        errs.append("line %d: not `<item> <session> [hold]` — %r" % (no, raw))
    seen = {}
    for no, item, sess, _held in rows:
        if sess not in SESSIONS and sess != PARKED:
            errs.append("line %d: item %s names unknown session %r" % (no, item, sess))
        if item not in every:
            errs.append("line %d: item %s is not in the backlog" % (no, item))
        if item in seen:
            errs.append("line %d: item %s is owned twice (also line %d)" % (no, item, seen[item]))
        seen[item] = no
    unowned = [n for n in queued if n not in seen]
    if unowned:
        errs.append("queued items with no owners line: " + " ".join(unowned))
    if errs:
        for e in errs:
            print("backlog-owners-lint: " + e)
        print("backlog-owners-lint: %d problem(s)" % len(errs))
        return 1
    print("backlog-owners-lint: %d queued items, all owned" % len(queued))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

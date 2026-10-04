#!/usr/bin/env python3
"""Extract every Mac UI string the owner docs quote into build/ui-expectations.json (python3 stdlib only).

Called by scripts/ui-expectations.sh; read by mac/DaylightUITests (the Docs to UI check, docs/handoff/vp-mac-ui.md
"What the suite proves" item 5). Usage: ui_expectations.py --root DIR --out FILE [DOC ...]

Chains recognised (Mac only):
  menu bar > "X"                          kind menu
  menu bar > "X" > "Y" [/ "Z" ...]         kind submenu (parent X)
  Settings > <Tab>                         kind tab (Tab one of the nine Mac tabs)
  Settings > <Tab> > [switch on|off] "L"   kind setting (tab)
  Settings > <Tab> > "L" > "O" [/ "P"]     kind option (tab, parent L)
  menu bar > "Settings..." > <Tab> > ...   the same as Settings > <Tab> > ...
Skipped: "System Settings > ...", "Daylight Ink > Settings > ...", "Zoom Settings > ...", "Settings > <not a Mac tab>" (Android, Zoom, Chrome).
Welcome window phrases (kind welcome):
  "Welcome to Daylight" (not "Welcome to Daylight Ink"), a quote in parentheses right after it, the quote after
  "first row reads", the titles after "Its rows, in order:" on such a line, the quotes in a "Welcome window: ..."
  clause, and in a "Location" or "Finish" bullet the quotes after "On an unsigned build:" or before "Closing".
A number placeholder " N" in a label ("Change threshold: N canvas cells") cuts the text there: the UI check
matches settings and menu items as a prefix. Output order is document order; duplicates by (kind, text, tab, parent)
keep the first source.
"""
import argparse
import json
import os
import re
import sys

TABS = ["General", "Hotkeys", "Network", "Mirror", "Overlay", "Share", "Saving", "Advanced", "Diagnostics"]
DEFAULT_DOCS = ["docs/OWNER-NEXT-STEPS.md", "docs/SETUP.md", "docs/TESTING-CHECKLIST.md"]

Q = r'"([^"\n]+)"'
SEP = r'\s*>\s*'
ROOT_MENU = re.compile(r'\b[Mm]enu bar' + SEP + Q)
ROOT_SETTINGS = re.compile(r'(?<![A-Za-z])Settings' + SEP + r'([A-Z][A-Za-z]+)\b')
NEXT_QUOTE = re.compile(SEP + r'(?:switch (?:on|off) )?' + Q)
ALT_QUOTE = re.compile(r'\s*/\s*' + Q)
NEXT_TAB = re.compile(SEP + r'([A-Z][A-Za-z]+)\b')
SKIP_BEFORE = ("System ", "Ink > ", "Ink ", "options > ", "app's ", "Zoom ")


def clean(text):
    """Cut a number placeholder (" N" as a word) and the spaces before it."""
    m = re.search(r'\s\bN\b', text)
    if m:
        text = text[:m.start()]
    return text.strip()


class Collector:
    def __init__(self):
        self.items = []
        self.seen = set()

    def add(self, kind, text, source, tab=None, parent=None):
        text = clean(text)
        if not text:
            return
        key = (kind, text, tab or "", parent or "")
        if key in self.seen:
            return
        self.seen.add(key)
        entry = {"text": text, "kind": kind}
        if tab:
            entry["tab"] = tab
        if parent:
            entry["parent"] = parent
        entry["source"] = source
        self.items.append(entry)


def settings_tail(line, pos, tab, source, out):
    """After `Settings > <Tab>` (pos is the end of the tab name): optional "Label" and "Option" levels."""
    out.add("tab", tab, source)
    m = NEXT_QUOTE.match(line, pos)
    if not m:
        return
    label = m.group(1)
    out.add("setting", label, source, tab=tab)
    m2 = NEXT_QUOTE.match(line, m.end())
    if not m2:
        return
    out.add("option", m2.group(1), source, tab=tab, parent=clean(label))
    end = m2.end()
    while True:
        alt = ALT_QUOTE.match(line, end)
        if not alt:
            break
        out.add("option", alt.group(1), source, tab=tab, parent=clean(label))
        end = alt.end()


def parse_chains(line, source, out):
    for m in ROOT_MENU.finditer(line):
        first = m.group(1)
        out.add("menu", first, source)
        if first == "Settings...":
            t = NEXT_TAB.match(line, m.end())
            if t and t.group(1) in TABS:
                settings_tail(line, t.end(), t.group(1), source, out)
            continue
        n = NEXT_QUOTE.match(line, m.end())
        if not n:
            continue
        out.add("submenu", n.group(1), source, parent=first)
        end = n.end()
        while True:
            alt = ALT_QUOTE.match(line, end)
            if not alt:
                break
            out.add("submenu", alt.group(1), source, parent=first)
            end = alt.end()
    for m in ROOT_SETTINGS.finditer(line):
        tab = m.group(1)
        if tab not in TABS:
            continue
        before = line[:m.start()]
        if any(before.endswith(s) for s in SKIP_BEFORE):
            continue
        settings_tail(line, m.end(), tab, source, out)


WELCOME = re.compile(r'"Welcome to Daylight"(?! Ink)')
WELCOME_PAREN = re.compile(r'"Welcome to Daylight"\s*\(' + Q + r'\)')
FIRST_ROW = re.compile(r'"Welcome to Daylight" window whose first row reads ' + Q)
ROWS = re.compile(r'Its rows, in order: ([^.]+?)\.(?:\s|$)')
WELCOME_CLAUSE = re.compile(r'Welcome window: (.*?)(?:\. |\.$|$)')
UNSIGNED = re.compile(r'On an unsigned build: (.*)$')
BULLET = re.compile(r'^- (Location|Finish): (.*)$')


def parse_welcome(line, source, out):
    if WELCOME.search(line):
        out.add("welcome", "Welcome to Daylight", source)
        for m in WELCOME_PAREN.finditer(line):
            out.add("welcome", m.group(1), source)
        for m in FIRST_ROW.finditer(line):
            out.add("welcome", m.group(1), source)
        r = ROWS.search(line)
        if r:
            for title in r.group(1).split(", "):
                out.add("welcome", title, source)
    for m in WELCOME_CLAUSE.finditer(line):
        for q in re.findall(Q, m.group(1)):
            out.add("welcome", q, source)
    b = BULLET.match(line)
    if b:
        body = b.group(2)
        if b.group(1) == "Location":
            u = UNSIGNED.search(body)
            if u:
                for q in re.findall(Q, u.group(1)):
                    out.add("welcome", q, source)
        else:
            head = body.split("Closing", 1)[0]
            for q in re.findall(Q, head):
                out.add("welcome", q, source)


def source_name(path, root):
    absolute = os.path.abspath(path)
    root = os.path.abspath(root)
    if absolute.startswith(root + os.sep):
        return os.path.relpath(absolute, root)
    return os.path.basename(absolute)


def extract(paths, root):
    out = Collector()
    for path in paths:
        name = source_name(path, root)
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, start=1):
                line = line.rstrip("\n")
                source = "%s:%d" % (name, number)
                parse_chains(line, source, out)
                parse_welcome(line, source, out)
    return out.items


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--out", default=None)
    parser.add_argument("docs", nargs="*")
    args = parser.parse_args(argv)
    docs = args.docs or [os.path.join(args.root, d) for d in DEFAULT_DOCS]
    out_path = args.out or os.path.join(args.root, "build", "ui-expectations.json")
    items = extract(docs, args.root)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(items, handle, indent=1, ensure_ascii=False)
        handle.write("\n")
    counts = {}
    for item in items:
        counts[item["kind"]] = counts.get(item["kind"], 0) + 1
    summary = ", ".join("%s %d" % (k, counts.get(k, 0)) for k in ["menu", "submenu", "tab", "setting", "option", "welcome"])
    print("ui-expectations: %d strings from %d docs (%s) -> %s" % (len(items), len(docs), summary, source_name(out_path, args.root)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

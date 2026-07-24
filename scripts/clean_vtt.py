#!/usr/bin/env python3
"""Turn a (YouTube auto-)VTT subtitle file into clean, readable paragraphs.

YouTube auto-subs repeat each caption line across rolling cues and embed
per-word timing tags — strip tags, drop timing/header lines, dedupe
consecutive repeats, then re-wrap into ~110-word paragraphs.
"""
import re
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()

kept, prev = [], ""
for ln in lines:
    s = ln.strip()
    if not s:
        continue
    if s.startswith(("WEBVTT", "Kind:", "Language:", "NOTE", "STYLE")):
        continue
    if "-->" in s or re.fullmatch(r"\d+", s):
        continue
    s = re.sub(r"<[^>]+>", "", s)
    s = (s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&gt;", ">")
           .replace("&lt;", "<").replace("&#39;", "'").replace("&quot;", '"')).strip()
    if not s or s in ("[Music]", "[Applause]", "[Laughter]"):
        continue
    if s == prev:
        continue
    kept.append(s)
    prev = s

words = " ".join(kept).split()
paras = [" ".join(words[i:i + 110]) for i in range(0, len(words), 110)]
print("\n\n".join(paras))

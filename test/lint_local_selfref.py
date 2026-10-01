#!/usr/bin/env python3
"""Fail on a `local` that reads a name declared earlier on the same line.

Bash expands every word of `local a=$1 b="x-$a"` BEFORE assigning any of them,
so $a there is the CALLER's a (or unset under `set -u`), not $1. That bug sat in
run_deploy_hook unnoticed because its caller happened to have its own $app.
"""
import re, shlex, sys

bad = 0
for path in sys.argv[1:]:
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        m = re.match(r"\s*local\s+(.*)$", line)
        if not m:
            continue
        try:
            toks = shlex.split(m.group(1).split("#")[0], posix=False)
        except ValueError:
            continue
        seen = []
        for t in toks:
            name, _, val = t.partition("=")
            for s in seen:
                if val and re.search(r"\$\{?" + re.escape(s) + r"\b", val):
                    print(f"{path}:{n}: `{s}` is read in the same `local` that declares it: {line.strip()}")
                    bad += 1
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                seen.append(name)
sys.exit(1 if bad else 0)

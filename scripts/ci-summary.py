#!/usr/bin/env python3
"""Turn `swift test` output + SwiftPM's codecov JSON into shields.io endpoint badges and a job summary.

usage: ci-summary.py <test.log> <codecov.json> <out-dir>
Writes <out-dir>/tests.json, coverage.json (engine + models), total-coverage.json and appends a table to $GITHUB_STEP_SUMMARY.
"""
import json, os, re, sys

log_path, cov_path, out_dir = sys.argv[1:4]
os.makedirs(out_dir, exist_ok=True)

# ---- tests -------------------------------------------------------------------------------
log = open(log_path, errors="replace").read()
runs = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log)
total, failed = (int(runs[-1][0]), int(runs[-1][1])) if runs else (0, 1)
passed = total - failed

def badge(name, label, message, color):
    with open(os.path.join(out_dir, name), "w") as f:
        json.dump({"schemaVersion": 1, "label": label, "message": message, "color": color}, f)

badge("tests.json", "tests",
      f"{passed} passing" if failed == 0 and total else f"{failed} failing" if total else "no results",
      "brightgreen" if failed == 0 and total else "red")

# ---- coverage ----------------------------------------------------------------------------
def color(p):
    return ("brightgreen" if p >= 90 else "green" if p >= 80 else "yellowgreen" if p >= 70
            else "yellow" if p >= 60 else "orange" if p >= 40 else "red")

data = json.load(open(cov_path))["data"][0]["files"]
rows, tot = [], [0, 0]
core = [0, 0]
for f in data:
    name = f["filename"]
    if "/Sources/Headroom/" not in name:
        continue                       # ignore tests and dependencies
    rel = name.split("/Sources/Headroom/")[1]
    lines = f["summary"]["lines"]
    rows.append((rel, lines["covered"], lines["count"]))
    tot[0] += lines["covered"]; tot[1] += lines["count"]
    if rel.startswith(("Engine/", "Models/")):
        core[0] += lines["covered"]; core[1] += lines["count"]

pct = lambda c, n: (100.0 * c / n) if n else 0.0
overall, core_pct = pct(*tot), pct(*core)
# Two badges: all code (total-coverage.json) and the logic layer (coverage.json, Engine + Models).
# The views are covered by render smoke tests, so the logic number is the one that reflects assertions.
badge("coverage.json", "coverage (engine + models)", f"{core_pct:.0f}%", color(core_pct))
badge("total-coverage.json", "coverage (all code)", f"{overall:.0f}%", color(overall))

summary = [f"## Tests: {passed}/{total} passing", "",
           f"**Line coverage:** {overall:.1f}% overall · {core_pct:.1f}% Engine + Models", "",
           "| File | Covered | Lines | % |", "|---|---:|---:|---:|"]
for rel, c, n in sorted(rows, key=lambda r: r[0]):
    summary.append(f"| `{rel}` | {c} | {n} | {pct(c, n):.0f}% |")
text = "\n".join(summary) + "\n"
print(text)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(text)

sys.exit(1 if failed or not total else 0)

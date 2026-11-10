#!/usr/bin/env python3
"""Temporary probe v2 (Cleaner v2.7).

Run 42859520811: the processor ran (after the --toolchain-dir fix) but
said "Extracted no relevant App Intents symbols", and the .swiftconstvalues
file the probe produced earlier was 2 bytes (probably "{}"): swiftc gathers
no constants. This probe tests WHAT makes swiftc gather:

Phase 1 (gathering): compile the real Intents/CleanerIntents.swift with
build.sh's exact flags (-Onone, absolute source path so the file-map key
matches — the v1 probe passed a relative source, so swiftc never wrote
the .o), varying ONLY the protocols file, and print the .swiftconstvalues
CONTENT (not just its size):
  G1: bare array, "Module.Name" x7 (current file)
  G2: bare array, bare names x7 (["AppIntent", ...])
  G3: bare array, "Module.Name" x8 (with IntentResult)
Phase 2 (symbols): for modules CleanerIntents and Cleaner, dump the
Shortcuts symbols of the .o and test build.sh's three greps, so the
fallback witness pattern gets an evidence-based fix (run 42857021899 /
42859520811 both failed it).
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.getcwd()
OUT = "/tmp/probe-out"
os.makedirs(OUT, exist_ok=True)
SRC = f"{ROOT}/Intents/CleanerIntents.swift"

SDK = subprocess.check_output(
    ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
    text=True).strip()

P7 = ["AppIntents.AppIntent", "AppIntents.AppEntity",
      "AppIntents.AppShortcutsProvider", "AppIntents.EntityQuery",
      "AppIntents.SnippetIntent", "AppIntents.WidgetConfigurationIntent",
      "AppIntents.ControlConfigurationIntent"]
N7 = [p.split(".", 1)[1] for p in P7]
P8 = P7 + ["AppIntents.IntentResult"]

VARIANTS = [
    ("G1", "bare array, Module.Name x7 (current)", P7),
    ("G2", "bare array, bare names x7", N7),
    ("G3", "bare array, Module.Name x8", P8),
]


def compile_intents(module, protocols_path, tag):
    """Compile like build.sh's build_app_binary; returns (rc, obj, cv)."""
    obj = f"{OUT}/{tag}.o"
    cv = f"{OUT}/{tag}.swiftconstvalues"
    fmap = {SRC: {"object": obj, "const-values": cv}}
    map_path = f"{OUT}/{tag}-map.json"
    with open(map_path, "w") as fh:
        json.dump(fmap, fh)
    cmd = ["xcrun", "--sdk", "iphoneos", "swiftc",
           "-target", "arm64-apple-ios26.0", "-sdk", SDK,
           "-Onone", "-swift-version", "5",
           "-parse-as-library", "-module-name", module,
           "-emit-const-values",
           "-output-file-map", map_path,
           "-Xfrontend", "-const-gather-protocols-file",
           "-Xfrontend", protocols_path,
           "-import-objc-header",
           "Intents/CleanerIntents-Bridging-Header.h",
           "-emit-objc-header-path", f"{OUT}/{tag}-Swift.h",
           "-I", "Core", "-c", SRC, "-o", obj]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, obj, cv, (r.stderr or r.stdout or "")


for vid, desc, entries in VARIANTS:
    ppath = f"{OUT}/proto-{vid}.json"
    with open(ppath, "w") as fh:
        json.dump(entries, fh)
    rc, obj, cv, err = compile_intents("CleanerIntents", ppath, vid)
    status = "PASS" if rc == 0 else "FAIL"
    print(f"PROBE {vid} [{desc}]: compile {status}", flush=True)
    if rc != 0:
        print(f"  {err.strip().splitlines()[-1] if err.strip() else ''}",
              flush=True)
        continue
    print(f"  object exists={os.path.exists(obj)}", flush=True)
    if os.path.exists(cv):
        raw = open(cv, "rb").read()
        print(f"  const-values size={len(raw)} content={raw[:500]!r}",
              flush=True)
    else:
        print("  const-values MISSING", flush=True)

print("PROBE GATHER DONE", flush=True)

# Phase 2: symbols of both modules (G1 protocols file).
ppath = f"{OUT}/proto-G1.json"
for module, prefix in [("CleanerIntents", r"[$]s14CleanerIntents"),
                       ("Cleaner", r"[$]s7Cleaner")]:
    tag = f"sym-{module}"
    rc, obj, cv, err = compile_intents(module, ppath, tag)
    print(f"PROBE SYMBOLS compile-as-{module}: "
          f"{'PASS' if rc == 0 else 'FAIL'}", flush=True)
    if rc != 0:
        print(f"  {err.strip().splitlines()[-1] if err.strip() else ''}",
              flush=True)
        continue
    nm = subprocess.run(["nm", "-a", obj], capture_output=True, text=True)
    if nm.returncode != 0:
        nm = subprocess.run(["xcrun", "nm", "-a", obj],
                            capture_output=True, text=True)
    syms = [l for l in nm.stdout.splitlines() if "Shortcuts" in l]
    print(f"PROBE SYMBOLS [{module}]: {len(syms)} Shortcuts symbols",
          flush=True)
    for line in syms:
        print(f"  {line}", flush=True)
    blob = open(obj, "rb").read()
    for pat, desc in [
            (prefix + r"16CleanCacheIntentV", "CleanCacheIntent type"),
            (prefix + r"0A9ShortcutsV", "CleanerShortcuts provider"),
            (r"0A9ShortcutsV03appC0", "appShortcuts witness")]:
        hit = re.search(pat.encode(), blob) is not None
        print(f"PROBE SYMBOLS [{module}] grep {desc}: "
              f"{'PASS' if hit else 'FAIL'} ({pat})", flush=True)
print("PROBE DONE", flush=True)
sys.exit(0)

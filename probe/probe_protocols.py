#!/usr/bin/env python3
"""Temporary probe (v2.7): which const-gather-protocols JSON format does the
Xcode 26.6 swift-frontend accept?

Run 42854024396 failed with:
  error: constant extraction protocol list input file from
  Intents/swift_const_gather_protocols.json is malformed
for {"protocols": ["AppIntents.AppIntent", ...]} (candidate C1).

This script replays the exact strict-check swiftc invocation from
tests/run_all_tests.sh against the real Intents/CleanerIntents.swift,
varying ONLY the protocols file, and prints PROBE <id>: PASS|FAIL per
candidate. Delete this file (and its workflow) once the format is known.
"""

import json
import os
import subprocess
import sys

ROOT = os.getcwd()
OUT = "/tmp/probe-out"
os.makedirs(OUT, exist_ok=True)

P8 = ["AppIntents.AppIntent", "AppIntents.AppEntity",
      "AppIntents.AppShortcutsProvider", "AppIntents.EntityQuery",
      "AppIntents.IntentResult", "AppIntents.SnippetIntent",
      "AppIntents.WidgetConfigurationIntent",
      "AppIntents.ControlConfigurationIntent"]
P7 = [p for p in P8 if not p.endswith(".IntentResult")]
N7 = [p.split(".", 1)[1] for p in P7]
OBJ8 = [{"module": "AppIntents", "name": p.split(".", 1)[1]} for p in P8]
OBJ7 = [o for o in OBJ8 if o["name"] != "IntentResult"]

CANDIDATES = [
    ("C1", "object, strings x8 (current, control)",
     {"protocols": P8}),
    ("C2", "object, strings x7 (no IntentResult)",
     {"protocols": P7}),
    ("C3", "bare array, strings x8",
     P8),
    ("C4", "bare array, strings x7 (no IntentResult)",
     P7),
    ("C5", "object, {module,name} x8",
     {"protocols": OBJ8}),
    ("C6", "object, {module,name} x7 (no IntentResult)",
     {"protocols": OBJ7}),
    ("C7", "object, bare names x7 (no module, no IntentResult)",
     {"protocols": N7}),
    ("C8", "object + version, strings x8",
     {"version": 1, "protocols": P8}),
    ("C9", "module-keyed map, bare names x7",
     {"AppIntents": N7}),
    ("C10", "object, {moduleName,protocolName} x1 (shape test)",
     {"protocols": [{"moduleName": "AppIntents",
                     "protocolName": "AppIntent"}]}),
]

SDK = subprocess.check_output(
    ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
    text=True).strip()

# Same output file map as the strict check in tests/run_all_tests.sh.
fmap = {f"{ROOT}/Intents/CleanerIntents.swift": {
    "object": f"{OUT}/CleanerIntents.o",
    "const-values": f"{OUT}/CleanerIntents.swiftconstvalues",
}}
with open(f"{OUT}/output-file-map.json", "w") as fh:
    json.dump(fmap, fh)

BASE_CMD = ["xcrun", "--sdk", "iphoneos", "swiftc",
            "-target", "arm64-apple-ios26.0", "-sdk", SDK,
            "-O", "-swift-version", "5",
            "-parse-as-library", "-module-name", "CleanerIntents",
            "-emit-const-values",
            "-output-file-map", f"{OUT}/output-file-map.json",
            "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend",
            None,  # placeholder: protocols file path
            "-import-objc-header",
            "Intents/CleanerIntents-Bridging-Header.h",
            "-emit-objc-header-path", f"{OUT}/CleanerIntents-Swift.h",
            "-I", "Core", "-c", "Intents/CleanerIntents.swift",
            "-o", f"{OUT}/CleanerIntents.o"]

npass = 0
for cid, desc, obj in CANDIDATES:
    ppath = f"{OUT}/proto-{cid}.json"
    with open(ppath, "w") as fh:
        json.dump(obj, fh)
    cmd = [ppath if a is None else a for a in BASE_CMD]
    r = subprocess.run(cmd, capture_output=True, text=True)
    status = "PASS" if r.returncode == 0 else "FAIL"
    if r.returncode == 0:
        npass += 1
    print(f"PROBE {cid} [{desc}]: {status}", flush=True)
    if r.returncode != 0:
        out = (r.stderr or r.stdout or "").strip().splitlines()
        for line in out[-3:]:
            print(f"  {line}", flush=True)
    else:
        cv = f"{OUT}/CleanerIntents.swiftconstvalues"
        print(f"  const-values: exists={os.path.exists(cv)} "
              f"size={os.path.getsize(cv) if os.path.exists(cv) else 0}",
              flush=True)

print(f"PROBE DONE: {npass}/{len(CANDIDATES)} passed", flush=True)
sys.exit(0)

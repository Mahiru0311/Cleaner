#!/usr/bin/env python3
import os
import stat
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build.sh"


FAKE_XCRUN = r'''#!/bin/sh
set -eu
if [ "$1" = "--sdk" ] && [ "$3" = "--show-sdk-path" ]; then
    printf '%s\n' "$FAKE_SDK"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "swiftc" ]; then
    output=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "-o" ]; then output=$argument; fi
        previous=$argument
    done
    test -n "$output"
    printf 'fake swift object\n' > "$output"
    # v2.7: the const-values path lives in the output file map, not on
    # the command line; the fake writes it next to the object file with
    # the same stem build.sh uses.
    printf '{}\n' > "${output%.o}.swiftconstvalues"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "clang" ]; then
    output=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "-o" ]; then output=$argument; fi
        previous=$argument
    done
    test -n "$output"
    # The stub must carry what the pre-strip check really greps for (v2.5):
    # the Swift-mangled intent symbols and the appShortcuts witness —
    # NOT just the bare type names. v2.4's binary kept the bare names
    # ("CleanCacheIntent", "CleanerShortcuts") while the types were gone,
    # so a stub with only bare names must FAIL the build. FAKE_DROP_INTENT
    # simulates exactly that v2.4 outcome: bare names present, mangled
    # symbols and appShortcuts absent. WORD SUBSTITUTION (run 42825889428):
    # the real mangled names are $s14CleanerIntents16CleanCacheIntentV
    # (spelled out) and $s14CleanerIntents0A9ShortcutsV ("Cleaner" -> 0A),
    # with the appShortcuts accessor as 0A9ShortcutsV03appC0 — the
    # literals "CleanerShortcutsV" and "appShortcuts" never appear.
    if [ "${FAKE_DROP_INTENT:-0}" = 1 ]; then
        printf '#!/bin/sh\n# CleanCacheIntent CleanerShortcuts\n# AppIntents linked\n\nexit 0\n' > "$output"
    else
        {
            printf '#!/bin/sh\n'
            printf '# %s\n' '$s14CleanerIntents16CleanCacheIntentV'
            printf '# %s\n' '$s14CleanerIntents0A9ShortcutsV'
            printf '# %s\n' '0A9ShortcutsV03appC0'
            # v2.7: the fallback module "Cleaner" (same substitution: the
            # first word "Cleaner" becomes 0A). The fake must carry both
            # modules' symbols, or the fallback path's pre-strip check
            # would fail in the fake environment for the wrong reason.
            printf '# %s\n' '$s7Cleaner16CleanCacheIntentV'
            printf '# %s\n' '$s7Cleaner0A9ShortcutsV'
            printf '# AppIntents linked\n'
            printf '\nexit 0\n'
        } > "$output"
    fi
    chmod +x "$output"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "strip" ]; then
    # build.sh strips the linked binary; the fixture binary is already a stub.
    exit 0
fi
if [ "$1" = "appintentsmetadataprocessor" ]; then
    output=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "--output" ]; then output=$argument; fi
        previous=$argument
    done
    test -n "$output"
    if [ "${FAKE_DROP_METADATA:-0}" = 1 ]; then
        # v2.7: the processor found no App Intents symbols and wrote
        # nothing ("Extracted no relevant App Intents symbols, skipping
        # writing output") — the build must fail instead of shipping an
        # invisible shortcut.
        echo 'Extracted no relevant App Intents symbols, skipping writing output' >&2
        exit 0
    fi
    mkdir -p "$output"
    # Plausible extracted metadata: the CleanCacheIntent action
    # (discoverable, background) and the CleanerShortcuts auto-shortcuts
    # with both phrases, in the shape the validator checks.
    cat > "$output/extract.actionsdata" <<'METADATA_EOF'
{"actions": [{"identifier": "CleanCacheIntent", "isDiscoverable": true, "openAppWhenRun": false, "title": "清理全部缓存"}], "autoShortcuts": [{"provider": "CleanerShortcuts", "phrases": ["用 Cleaner 清理全部缓存", "在 Cleaner 里清理缓存"]}]}
METADATA_EOF
    printf '{"version": 1}\n' > "$output/version.json"
    exit 0
fi
exit 2
'''

FAKE_CODESIGN = r'''#!/bin/sh
set -eu
last=
for argument in "$@"; do last=$argument; done
if [ "$1" = "-f" ]; then
    entitlements=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "--entitlements" ]; then entitlements=$argument; fi
        previous=$argument
    done
    mkdir -p "$last/_CodeSignature"
    printf 'fixture signature\n' > "$last/_CodeSignature/CodeResources"
    if [ "${FAKE_DROP_GROUP:-0}" = 1 ]; then
        printf '<plist version="1.0"><dict/></plist>\n' > "$last/.fake-entitlements.plist"
    else
        cp "$entitlements" "$last/.fake-entitlements.plist"
    fi
    exit 0
fi
if [ "$1" = "--verify" ]; then
    test -x "$last/Cleaner"
    test -f "$last/_CodeSignature/CodeResources"
    exit 0
fi
if [ "$1" = "-d" ]; then
    /usr/bin/plutil -convert xml1 -o - "$last/.fake-entitlements.plist"
    exit 0
fi
exit 2
'''

FAKE_OTOOL = r'''#!/bin/sh
set -eu
if [ "$1" = "-L" ]; then
    # validate_app greps this for the AppIntents link. A real check: read
    # the binary (last argument) and report the link only if the binary
    # actually carries the AppIntents marker. The old stub printed the
    # line unconditionally, so the check passed on any binary at all.
    last=
    for argument in "$@"; do last=$argument; done
    if grep -q "AppIntents" "$last"; then
        printf '\t/System/Library/Frameworks/AppIntents.framework/AppIntents (compatibility version 1.0.0, current version 1.0.0)\n'
    fi
    exit 0
fi
exit 2
'''

FAKE_ZIP = r'''#!/bin/sh
set -eu
if [ "${FAKE_ZIP_FAIL:-0}" = 1 ]; then
    echo 'injected zip failure' >&2
    exit 9
fi
exec /usr/bin/zip "$@"
'''

FAKE_UNZIP = r'''#!/bin/sh
set -eu
exec /usr/bin/unzip "$@"
'''


class StagedBuildTests(unittest.TestCase):
    def _fake_environment(self, directory: Path):
        fake_bin = directory / "bin"
        fake_bin.mkdir()
        fake_sdk = directory / "sdk"
        fake_sdk.mkdir()
        for name, content in {
            "xcrun": FAKE_XCRUN,
            "codesign": FAKE_CODESIGN,
            "otool": FAKE_OTOOL,
            "zip": FAKE_ZIP,
            "unzip": FAKE_UNZIP,
        }.items():
            path = fake_bin / name
            path.write_text(content, encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment["FAKE_SDK"] = str(fake_sdk)
        environment["WQ_SKIP_PREFLIGHT"] = "1"
        return environment

    def test_default_output_stays_in_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "project"
            project.mkdir()
            for name in ("build.sh", "Info.plist", "entitlements.plist"):
                shutil.copy2(ROOT / name, project / name)
            # v2.7: build.sh now reads the metadata validator and the
            # const-gather protocols file from the project tree.
            (project / "tests").mkdir()
            shutil.copy2(ROOT / "tests" / "check_appintents_metadata.py",
                         project / "tests" / "check_appintents_metadata.py")
            (project / "Intents").mkdir()
            shutil.copy2(ROOT / "Intents" / "swift_const_gather_protocols.json",
                         project / "Intents" / "swift_const_gather_protocols.json")
            (project / "icons").mkdir()
            (project / "icons" / "AppIcon60x60@2x.png").write_bytes(b"fixture icon")
            environment = self._fake_environment(root)
            environment.pop("CLEANER_FINAL_IPA", None)
            environment.pop("WQFILES_FINAL_IPA", None)
            result = subprocess.run(
                [str(project / "build.sh")], cwd=project, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((project / "Cleaner.ipa").is_file())
            self.assertFalse((root / "Cleaner.ipa").exists())

    def test_success_publishes_only_a_validated_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "Cleaner.ipa"
            final.parent.mkdir()
            final.write_bytes(b"previous release")
            environment = self._fake_environment(root)
            environment["CLEANER_FINAL_IPA"] = str(final)
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(final.read_bytes(), b"previous release")
            with zipfile.ZipFile(final) as archive:
                self.assertIsNone(archive.testzip())
                self.assertIn("Payload/Cleaner.app/Cleaner", archive.namelist())
                self.assertIn("Payload/Cleaner.app/Info.plist", archive.namelist())

    def test_zip_failure_preserves_existing_final_ipa_and_cleans_siblings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "Cleaner.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["CLEANER_FINAL_IPA"] = str(final)
            environment["FAKE_ZIP_FAIL"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)
            self.assertEqual(list(final.parent.glob(".Cleaner.ipa.*")), [])
            self.assertEqual(list(final.parent.glob(".Cleaner-build.*")), [])

    def test_missing_signed_app_group_preserves_existing_final_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "Cleaner.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["CLEANER_FINAL_IPA"] = str(final)
            environment["FAKE_DROP_GROUP"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)

    def test_stripped_intent_fails_the_build(self):
        # v2.5: the v2.4 binary kept the bare intent names but the mangled
        # symbols (in their real, word-substituted forms) were absent,
        # and a bare-name grep passed it. FAKE_DROP_INTENT reproduces
        # that binary (bare names present, mangled symbols + appShortcuts
        # witness absent); the build must fail and leave the existing
        # release untouched.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "Cleaner.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["CLEANER_FINAL_IPA"] = str(final)
            environment["FAKE_DROP_INTENT"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)


    def test_dropped_app_intents_metadata_fails_the_build(self):
        # v2.7: the processor found no App Intents symbols and wrote no
        # Metadata.appintents (the v2.4-v2.6 outcome, which shipped an
        # invisible shortcut). The build must fail — including through
        # the fallback recompile as the app module — and leave the
        # existing release untouched.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "Cleaner.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["CLEANER_FINAL_IPA"] = str(final)
            environment["FAKE_DROP_METADATA"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()

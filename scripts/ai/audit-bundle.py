#!/usr/bin/env python3
"""Audit a BUILT iOS app for the things that block submission or crash in review.

`xcodebuild archive` succeeding proves nothing about submission. This reads the
product itself: Info.plist, the privacy manifests, entitlements, the linked
symbols, and debug residue.

usage: audit-bundle.py <App.app | App.xcarchive | App.ipa> [--src <swift source dir>]

Exit 1 on any FAIL. Symbol-based checks are heuristics and report WARN, never FAIL,
with the symbol that triggered them as evidence.
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

RESULTS: list[tuple[str, str]] = []


def report(level: str, msg: str) -> None:
    RESULTS.append((level, msg))
    print(f"  {level:<5} {msg}")


def run(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return ""


def resolve_app(target: Path) -> tuple[Path, str]:
    if target.suffix == ".app":
        return target, "app"
    if target.suffix == ".xcarchive":
        apps = list((target / "Products" / "Applications").glob("*.app"))
        if not apps:
            sys.exit(f"no .app inside {target}/Products/Applications")
        return apps[0], "archive"
    if target.suffix == ".ipa":
        tmp = Path(tempfile.mkdtemp(prefix="audit-ipa-"))
        with zipfile.ZipFile(target) as z:
            z.extractall(tmp)
        apps = list((tmp / "Payload").glob("*.app"))
        if not apps:
            sys.exit(f"no Payload/*.app inside {target}")
        return apps[0], "ipa"
    sys.exit("expected a .app, .xcarchive or .ipa")


def machos(app: Path, exe: str) -> list[Path]:
    """The app's own code: the executable, Xcode's debug dylib split, and embedded frameworks."""
    out = [app / exe]
    out += list(app.glob("*.debug.dylib"))
    for fw in (app / "Frameworks").glob("*.framework") if (app / "Frameworks").exists() else []:
        b = fw / fw.stem
        if b.exists():
            out.append(b)
    return [p for p in out if p.exists()]


def undefined_symbols(binaries: list[Path]) -> set[str]:
    syms: set[str] = set()
    for b in binaries:
        syms.update(line.strip() for line in run("nm", "-u", "-j", str(b)).splitlines())
    return syms


# Linked class -> the Info.plist key the first access needs. Missing key = the app is killed on access.
USAGE_KEYS = [
    ("_OBJC_CLASS_$_AVCaptureDevice", ["NSCameraUsageDescription"], "camera"),
    ("_OBJC_CLASS_$_AVAudioRecorder", ["NSMicrophoneUsageDescription"], "microphone"),
    ("_OBJC_CLASS_$_AVAudioEngine", ["NSMicrophoneUsageDescription"], "microphone (if the input node is used)"),
    ("_OBJC_CLASS_$_SFSpeechRecognizer", ["NSSpeechRecognitionUsageDescription"], "speech recognition"),
    ("_OBJC_CLASS_$_CLLocationManager", ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"], "location"),
    ("_OBJC_CLASS_$_CNContactStore", ["NSContactsUsageDescription"], "contacts"),
    ("_OBJC_CLASS_$_EKEventStore", ["NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription", "NSRemindersFullAccessUsageDescription"], "calendars/reminders"),
    ("_OBJC_CLASS_$_PHPhotoLibrary", ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"], "photo library (PHPicker out of process needs none)"),
    ("_OBJC_CLASS_$_HKHealthStore", ["NSHealthShareUsageDescription"], "HealthKit"),
    ("_OBJC_CLASS_$_CBCentralManager", ["NSBluetoothAlwaysUsageDescription"], "Bluetooth"),
    ("_OBJC_CLASS_$_NFCNDEFReaderSession", ["NFCReaderUsageDescription"], "NFC"),
    ("_OBJC_CLASS_$_ATTrackingManager", ["NSUserTrackingUsageDescription"], "tracking"),
    ("_OBJC_CLASS_$_MPMediaLibrary", ["NSAppleMusicUsageDescription"], "media library"),
    ("_OBJC_CLASS_$_CMMotionActivityManager", ["NSMotionUsageDescription"], "motion"),
]

# Required-reason API categories (Apple's list) and symbols that indicate use.
REQUIRED_REASON = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ["_OBJC_CLASS_$_NSUserDefaults"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["_stat", "_fstat", "_lstat", "_fstatat", "_getattrlist", "_getattrlistbulk",
                                                  "_NSFileCreationDate", "_NSFileModificationDate",
                                                  "_NSURLContentModificationDateKey", "_NSURLCreationDateKey"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["_mach_absolute_time"],
    "NSPrivacyAccessedAPICategoryDiskSpace": ["_statfs", "_statvfs", "_fstatfs", "_fstatvfs", "_NSFileSystemFreeSize",
                                              "_NSFileSystemSize", "_NSURLVolumeAvailableCapacityKey",
                                              "_NSURLVolumeAvailableCapacityForImportantUsageKey"],
}


def privacy_manifests(app: Path) -> list[Path]:
    return sorted(app.rglob("PrivacyInfo.xcprivacy"))


def declared_categories(manifests: list[Path], app: Path) -> dict[str, list[str]]:
    """Category -> which manifests declare it ("app" for the root one, else the containing bundle)."""
    cats: dict[str, list[str]] = {}
    for m in manifests:
        try:
            d = plistlib.loads(m.read_bytes())
        except Exception:
            report("FAIL", f"unreadable privacy manifest: {m}")
            continue
        owner = "app" if m.parent == app else m.parent.name
        for entry in d.get("NSPrivacyAccessedAPITypes", []):
            cats.setdefault(entry.get("NSPrivacyAccessedAPIType", ""), []).append(owner)
    return cats


def entitlements(binary: Path) -> dict:
    raw = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(binary)],
                         capture_output=True, check=False).stdout
    try:
        return plistlib.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    src = None
    if "--src" in args:
        i = args.index("--src")
        src = args[i + 1]
        del args[i:i + 2]
    app, kind = resolve_app(Path(args[0]).expanduser())
    info = plistlib.loads((app / "Info.plist").read_bytes())
    exe = info.get("CFBundleExecutable", app.stem)
    platform = info.get("DTPlatformName", "?")
    distributable = kind in ("archive", "ipa")

    print(f"audit {app.name}  ({kind}, {platform}, {info.get('CFBundleIdentifier')} "
          f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')}), min iOS {info.get('MinimumOSVersion')})")
    if platform != "iphoneos":
        print("  note  simulator build: release checks below are advisory; audit the archive before submitting")

    # 1. Export compliance.
    if "ITSAppUsesNonExemptEncryption" in info:
        report("PASS", f"export compliance answered in the binary (ITSAppUsesNonExemptEncryption={info['ITSAppUsesNonExemptEncryption']})")
    else:
        report("FAIL", "ITSAppUsesNonExemptEncryption missing: every upload stops for the question and TestFlight will not distribute")

    # 2. Launch screen and iPad orientations.
    if "UILaunchScreen" in info or "UILaunchStoryboardName" in info:
        report("PASS", "launch screen declared")
    else:
        report("FAIL", "no UILaunchScreen / UILaunchStoryboardName: the app runs letterboxed and validation rejects it")
    if 2 in info.get("UIDeviceFamily", []) and not info.get("UIRequiresFullScreen"):
        ipad = set(info.get("UISupportedInterfaceOrientations~ipad", info.get("UISupportedInterfaceOrientations", [])))
        if len(ipad) < 4:
            report("FAIL", f"iPad multitasking needs all four orientations (has {sorted(ipad)}) or UIRequiresFullScreen")
        else:
            report("PASS", "iPad supports all orientations")
    if info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon") or info.get("CFBundleIconName"):
        report("PASS", "app icon declared")
    else:
        report("FAIL", "no primary app icon in Info.plist")

    # 3. Debug residue.
    residue = [p.name for p in app.glob("*.debug.dylib")] + [p.name for p in app.glob("__preview.dylib")]
    if residue:
        report("FAIL" if distributable else "note", f"debug residue in bundle: {', '.join(residue)} (a Debug-configuration build)")
    else:
        report("PASS", "no debug dylib / preview residue")

    # 4. Entitlements.
    ents = entitlements(app / exe)
    if ents.get("get-task-allow"):
        report("FAIL" if distributable else "note", "get-task-allow is true: development-signed, not distributable")
    if distributable and ents.get("aps-environment") == "development":
        report("WARN", "aps-environment is development in a distribution product")
    for k in ("com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
              "com.apple.developer.associated-domains", "com.apple.security.application-groups"):
        if k in ents:
            report("info", f"{k.rsplit('.', 1)[-1]}: {ents[k]}")

    # 5. Architectures.
    archs = run("lipo", "-archs", str(app / exe)).split()
    if platform == "iphoneos" and "arm64" not in archs:
        report("FAIL", f"no arm64 slice (has {archs})")

    # 6. Privacy manifests and required-reason APIs.
    manifests = privacy_manifests(app)
    root_manifest = app / "PrivacyInfo.xcprivacy"
    if root_manifest.exists():
        d = plistlib.loads(root_manifest.read_bytes())
        report("PASS", f"app privacy manifest present (tracking={d.get('NSPrivacyTracking', False)}, "
                       f"{len(d.get('NSPrivacyCollectedDataTypes', []))} collected types, "
                       f"{len(d.get('NSPrivacyAccessedAPITypes', []))} required-reason APIs)")
    else:
        report("FAIL", "no PrivacyInfo.xcprivacy at the app root: rejected at upload since May 2024")
    fw_dir = app / "Frameworks"
    if fw_dir.exists():
        for fw in fw_dir.glob("*.framework"):
            if not (fw / "PrivacyInfo.xcprivacy").exists():
                report("WARN", f"embedded {fw.name} has no privacy manifest (required for SDKs on Apple's list)")
    declared = declared_categories(manifests, app)
    syms = undefined_symbols(machos(app, exe))
    for cat, markers in REQUIRED_REASON.items():
        used = sorted(s for s in markers if s in syms)
        name = cat.replace("NSPrivacyAccessedAPICategory", "")
        owners = declared.get(cat, [])
        if not used:
            continue
        if "app" in owners:
            report("PASS", f"{name} API referenced and declared by the app manifest")
        elif owners:
            report("WARN", f"{name} API referenced ({', '.join(used[:3])}) and declared only by {', '.join(owners)}: "
                           f"if the app's own code calls it, the app manifest must declare it too")
        else:
            report("WARN", f"{name} API referenced ({', '.join(used[:3])}) but no manifest in the bundle declares it")

    # 7. Usage descriptions for linked capabilities.
    for sym, keys, what in USAGE_KEYS:
        if sym in syms:
            present = [k for k in keys if info.get(k)]
            if present:
                report("PASS", f"{what}: {present[0]} present")
            else:
                report("WARN", f"{what}: links {sym.replace('_OBJC_CLASS_$_', '')} but none of {keys} is set "
                               f"(the app is terminated on first access)")
    for k, v in info.items():
        if k.endswith("UsageDescription") and (not isinstance(v, str) or len(v.strip()) < 12):
            report("WARN", f"{k} is empty or too short to pass review: {v!r}")

    # 8. Launch-argument seams, from source (the binary cannot show short literals).
    if src:
        here = Path(__file__).parent
        r = subprocess.run([sys.executable, str(here / "debug-fences.py"), src], capture_output=True, text=True)
        if r.returncode == 0:
            report("PASS", "no launch-argument read outside #if DEBUG in " + src)
        else:
            for line in r.stdout.splitlines():
                if ": error:" in line:
                    report("FAIL", line)
    else:
        report("note", "pass --src <dir> to check launch-argument seams are fenced out of Release")

    fails = sum(1 for lvl, _ in RESULTS if lvl == "FAIL")
    warns = sum(1 for lvl, _ in RESULTS if lvl == "WARN")
    print(f"result: {fails} FAIL, {warns} WARN")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

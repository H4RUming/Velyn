"""Capture real v1.1 simulator UI with generated fixtures in an isolated app store.
Usage: python3 Scripts/capture-readme.py SIMULATOR_UDID APP_BUNDLE EXAMPLE_DIRECTORY
Run make-readme-examples.swift first. No user photo library is read or modified.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    parser.add_argument("app", type=Path)
    parser.add_argument("examples", type=Path)
    args = parser.parse_args()
    bundle = run("/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", str(args.app / "Info.plist"))
    run("xcrun", "simctl", "install", args.simulator, str(args.app))
    container = Path(run("xcrun", "simctl", "get_app_container", args.simulator, bundle, "data"))
    root = container / "Library/Application Support/Velyn/ReadmeV11"
    run("xcrun", "simctl", "terminate", args.simulator, bundle, check=False)
    root.mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.examples / "projects", root, dirs_exist_ok=True)
    report = json.loads((args.examples / "report.json").read_text())
    asset = report["assetID"]
    output = Path("Docs/Images")
    run("xcrun", "simctl", "status_bar", args.simulator, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")
    screens = [
        ("app-library.png", [], "sdr"),
        ("app-selection.png", ["--readme-selection"], "sdr"),
        ("app-editor.png", [f"--readme-asset={asset}"], "sdr"),
        ("app-hdr.png", [f"--readme-asset={asset}", "--editor-tool=HDR"], "hdr"),
        ("app-export.png", [f"--readme-asset={asset}", "--editor-export-smoke-test"], "hdr"),
        ("app-language.png", ["--settings-smoke-test"], "sdr"),
    ]
    for filename, flags, recipe in screens:
        run("xcrun", "simctl", "terminate", args.simulator, bundle, check=False)
        shutil.copyfile(args.examples / f"document-{recipe}.json", root / asset / "edits.json")
        run("xcrun", "simctl", "launch", args.simulator, bundle, "--readme-screenshots", "-appLanguage", "en", "-libraryColumns", "2", *flags)
        time.sleep(4)
        run("xcrun", "simctl", "io", args.simulator, "screenshot", str(output / filename))
        print(filename, flush=True)
    for name in ["alpine-before.jpg", "alpine-after.jpg", "alpine-hdr.jpg", "alpine-hdr.heic", "hdr-reference-sdr.jpg", "hdr-reference-hdr.jpg", "hdr-applied-gain.png", "report.json"]:
        shutil.copyfile(args.examples / name, output / name)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify pubspec and built-APK version metadata agree.

Source of truth:
  pubspec.yaml version: <versionName>+<baseBuildNumber>

Android split-per-abi APKs add ABI offsets to versionCode, so this script checks:
  * APK versionName == pubspec versionName
  * APK versionCode ends with pubspec base build number

The installed app's settings page reads PackageInfo.fromPlatform(), so it shows
the APK's own metadata directly. That's the same APK that
`.github/workflows/release.yml` uploads to GitHub Releases. Passing this check
guarantees the in-app version display and the published release artifact both
agree with pubspec.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys


def find_aapt() -> str:
    explicit = os.environ.get("AAPT")
    if explicit:
        return explicit
    found = shutil.which("aapt")
    if found:
        return found
    candidates = sorted(glob.glob("/opt/android-sdk/build-tools/*/aapt"))
    if candidates:
        return candidates[-1]
    raise SystemExit("aapt not found. Set AAPT=/path/to/aapt.")


def read_pubspec(path: str) -> tuple[str, str]:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            match = re.match(r"^version:\s*(\S+)", line)
            if match:
                raw = match.group(1)
                parts = raw.split("+", 1)
                return parts[0], parts[1] if len(parts) > 1 else ""
    raise SystemExit(f"No version: field found in {path}")


def read_apk(aapt: str, apk: str) -> tuple[str, str]:
    out = subprocess.check_output([aapt, "dump", "badging", apk], text=True)
    first = out.splitlines()[0]
    name = re.search(r"versionName='([^']+)'", first)
    code = re.search(r"versionCode='([^']+)'", first)
    if not name or not code:
        raise SystemExit(f"Could not parse APK version metadata from {apk}")
    return name.group(1), code.group(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--pubspec", default="pubspec.yaml", help="Path to pubspec.yaml"
    )
    parser.add_argument(
        "--apk",
        default="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk",
        help="Path to APK to verify",
    )
    args = parser.parse_args()

    pub_name, pub_build = read_pubspec(args.pubspec)
    apk_name, apk_code = read_apk(find_aapt(), args.apk)

    errors: list[str] = []
    if apk_name != pub_name:
        errors.append(f"versionName mismatch: pubspec={pub_name} apk={apk_name}")
    if pub_build and not apk_code.endswith(pub_build):
        errors.append(
            f"versionCode mismatch: pubspec build={pub_build} apk versionCode={apk_code}"
        )

    print(f"pubspec: {pub_name}+{pub_build}")
    print(f"apk:     {apk_name}+{apk_code}")
    print(f"display: {apk_name}+{apk_code}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("✓ version metadata is consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

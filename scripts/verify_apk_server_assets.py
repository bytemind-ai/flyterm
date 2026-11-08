#!/usr/bin/env python3
"""Fail if an APK does not bundle the flyterm-server binaries.

The app installs and upgrades the server on remote hosts from these assets.
Without them the upgrade silently does nothing and a fresh host can't be
set up at all — which is how 0.7.0–0.9.0 shipped. Run after `flutter build
apk`, in CI and before publishing a release.
"""
import sys
import zipfile

PREFIX = "assets/flutter_assets/assets/flyterm-server/"
REQUIRED = [
    "VERSION",
    "flyterm-server-linux-x86_64.gz",
    "flyterm-server-linux-aarch64.gz",
]

apk = sys.argv[1]
names = set(zipfile.ZipFile(apk).namelist())
missing = [f for f in REQUIRED if PREFIX + f not in names]
if missing:
    print(f"::error::{apk} is missing flyterm-server assets: {', '.join(missing)}")
    sys.exit(1)
version = zipfile.ZipFile(apk).read(PREFIX + "VERSION").decode().strip()
print(f"OK: {apk} bundles flyterm-server {version}")

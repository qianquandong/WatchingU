#!/usr/bin/env python3
"""Boot an installed iPhone simulator and capture the real app's launch for visual QA."""
import json
import plistlib
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
app = ROOT / '.build/DerivedData-iPhone/Build/Products/Debug-iphonesimulator/DayTape.app'
if not app.is_dir():
    raise SystemExit('Built iPhone app is missing')
with (app / 'Info.plist').open('rb') as stream:
    identifier = plistlib.load(stream)['CFBundleIdentifier']
listing = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
devices = [device for runtime in listing['devices'].values() for device in runtime
           if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not devices:
    raise SystemExit('No iPhone simulator runtime available for smoke test')
device = sorted(devices, key=lambda item: (item['state'] != 'Booted', 'Pro' not in item['name']))[0]
udid = device['udid']
if device['state'] != 'Booted':
    subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=180)
subprocess.run(['xcrun', 'simctl', 'ui', udid, 'appearance', 'dark'], check=True)
subprocess.run(['xcrun', 'simctl', 'install', udid, str(app)], check=True)
subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, identifier], check=True)
time.sleep(5)
destination = ROOT / 'artifacts/iphone-home.png'
subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(destination)], check=True)
print('Captured', destination)

#!/usr/bin/env python3
"""Package the built app and write the checksum consumed by the updater."""
import hashlib
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
app = root / '.build/app/HWP Preview.app'
info = json.loads((app / 'Contents/Resources/BuildInfo.json').read_text())
version = info['version'].removeprefix('v')
out = root / '.build/releases'
out.mkdir(parents=True, exist_ok=True)
archive = out / f'HWP-Preview-{version}-macOS-{info["architecture"]}.zip'
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive.name + '\n')
print(archive)

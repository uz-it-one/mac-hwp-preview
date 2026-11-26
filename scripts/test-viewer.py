#!/usr/bin/env python3
"""Actual AppKit/WebKit viewer integration tests; requires a macOS GUI session."""
import pathlib
import subprocess
root = pathlib.Path(__file__).resolve().parent.parent
output = root / '.build/viewer-probe'
sources = list((root / 'Sources/HWPPreviewCore').glob('*.swift'))
sources += [root / 'App' / name for name in ['DocumentCoordinator.swift', 'DocumentWindowController.swift', 'DefaultApplicationService.swift']]
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(root / '.build/module-cache'), '-I', str(root / 'Sources/CZlib'), *map(str, sources), str(root / 'scripts/viewer-probe.swift'), '-o', str(output)], check=True)
subprocess.run([str(output), str(root)], check=True, timeout=180)

# Exercise actual app lifecycle and menus in an isolated bundle without an update feed.
import plistlib
import shutil
bundle = root / '.build/app-viewer-probe.app'
shutil.rmtree(bundle, ignore_errors=True)
shutil.copytree(root / '.build/app/HWP Preview.app', bundle, symlinks=True)
contents = bundle / 'Contents'
info = plistlib.loads((contents / 'Info.plist').read_bytes())
info['CFBundleIdentifier'] = 'org.hwp-preview.app-viewer-probe'
info.pop('SUFeedURL', None)
info.pop('SUPublicEDKey', None)
info.pop('CFBundleDocumentTypes', None)
info.pop('UTExportedTypeDeclarations', None)
info.pop('UTImportedTypeDeclarations', None)
shutil.rmtree(contents / 'PlugIns', ignore_errors=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
app_sources = [p for p in (root / 'App').glob('*.swift') if p.name != 'main.swift']
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(root / '.build/module-cache'), '-I', str(root / 'Sources/CZlib'), *map(str, (root / 'Sources/HWPPreviewCore').glob('*.swift')), *map(str, app_sources), str(root / 'scripts/app-viewer-probe.swift'), '-o', str(contents / 'MacOS/HWPPreview')], check=True)
for mode in ['cold', 'start']:
    subprocess.run([str(contents / 'MacOS/HWPPreview'), str(root), mode], check=True, timeout=60)

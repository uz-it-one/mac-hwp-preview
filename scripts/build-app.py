#!/usr/bin/env python3
"""Build native app extensions with Xcode's Swift compiler; no project generator required."""
import os, pathlib, plistlib, shutil, subprocess, json, argparse
from wasm_limits import cap_memory
root = pathlib.Path(__file__).resolve().parent.parent
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--update-config', type=pathlib.Path, default=root/'release/update-config.json')
args = parser.parse_args()
update_settings = json.loads(args.update_config.read_text())
updates = {'HWPUpdateRepository': update_settings['github_repository']}

def sign(path, entitlements=None):
    command = ['codesign', '--force', '--sign', '-']
    if entitlements: command += ['--entitlements', str(entitlements)]
    subprocess.run(command + [str(path)], check=True)

version = os.environ.get('RELEASE_VERSION', (root/'VERSION').read_text().strip()).removeprefix('v')
build_number = (root/'BUILD_NUMBER').read_text().strip()
out = root / '.build' / 'app'
app = out / 'HWP Preview.app'
engine = root / '.build/wasm/package/rhwp_bg.wasm'
if not engine.is_file():
    raise SystemExit('Run scripts/fetch-wasm.sh first')
if app.exists(): shutil.rmtree(app)

def plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))

def run(*args): subprocess.run([str(x) for x in args], check=True)

def copy_web(contents):
    web = contents/'Resources/Web'
    web.mkdir(parents=True)
    for filename in ['index.html', 'viewer.js', 'document-tools.js', 'svg.js', 'engine-worker.js']:
        shutil.copy2(root/'Resources/Web'/filename, web/filename)
    for filename in ['rhwp.js','rhwp_bg.wasm','LICENSE']:
        shutil.copy2(root/'.build/wasm/package'/filename, web/filename)
    (web/'rhwp_bg.wasm').write_bytes(cap_memory((web/'rhwp_bg.wasm').read_bytes()))

def bundle(path, name, ident, extension=None):
    contents = path / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    info = dict(CFBundleIdentifier=ident, CFBundleName=name, CFBundleExecutable=name,
                CFBundleVersion=build_number, CFBundleShortVersionString=version.split('-')[0], HWPPreviewVersion=version,
                CFBundlePackageType='XPC!' if extension else 'APPL',
                LSMinimumSystemVersion='14.0')
    if extension: info['NSExtension'] = extension
    plist(contents / 'Info.plist', info)
    return contents

types = ['org.hwp-preview.hwp', 'org.hwp-preview.hwpx', 'com.hancom.hwp', 'com.hancom.hwpx', 'org.libreoffice.hwp-document']
appc = bundle(app, 'HWPPreview', 'org.hwp-preview.app')
info = plistlib.loads((appc/'Info.plist').read_bytes())
info['NSPrincipalClass'] = 'NSApplication'
info['CFBundleIconFile'] = 'AppIcon.icns'
shutil.copy2(root/'Resources/AppIcon.icns', appc/'Resources/AppIcon.icns')
info.update(updates)
info['UTImportedTypeDeclarations'] = [dict(UTTypeIdentifier=types[i], UTTypeDescription=ext.upper()+' Document',
    UTTypeConformsTo=['public.data'], UTTypeTagSpecification={'public.filename-extension':[ext],
    'public.mime-type':mime}) for i,ext,mime in [(0,'hwp','application/x-hwp'),(1,'hwpx','application/hwp+zip')]]
info['CFBundleDocumentTypes'] = [dict(CFBundleTypeRole='Viewer', LSHandlerRank='Alternate', LSItemContentTypes=types)]
plist(appc/'Info.plist',info)
flags = ['-swift-version','5','-target',os.uname().machine+'-apple-macosx14.0',
         '-module-cache-path',str(root/'.build/module-cache'),'-O']
copy_web(appc)
(appc/'Resources/Updater').mkdir()
shutil.copy2(root/'Resources/Updater/install-update.sh', appc/'Resources/Updater/install-update.sh')
run('xcrun','swiftc',*flags,*sorted((root/'App').glob('*.swift')),*sorted((root/'Sources/HWPPreviewCore').glob('*.swift')), '-I',root/'Sources/CZlib',
    '-o',appc/'MacOS/HWPPreview')
for name, point, principal, source in [
    ('Preview','com.apple.quicklook.preview','PreviewController','Extensions/Preview/PreviewController.swift'),
    ('Thumbnail','com.apple.quicklook.thumbnail','ThumbnailProvider','Extensions/Thumbnail/ThumbnailProvider.swift')]:
    attrs = dict(QLSupportedContentTypes=types)
    if name == 'Thumbnail': attrs['QLThumbnailMinimumDimension'] = 0
    c = bundle(appc/'PlugIns'/f'{name}.appex',name,'org.hwp-preview.app.'+name.lower(),
               dict(NSExtensionPointIdentifier=point,NSExtensionPrincipalClass=principal,NSExtensionAttributes=attrs))
    run('xcrun','swiftc',*flags,'-parse-as-library','-application-extension',*sorted((root/'Sources/HWPPreviewCore').glob('*.swift')),source,'-I',root/'Sources/CZlib',
        '-Xlinker','-e','-Xlinker','_NSExtensionMain','-o',c/'MacOS'/name)
    copy_web(c)
    ent = out/'extension.entitlements'
    plist(ent,{'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True,'com.apple.security.network.client':True})
    sign(c.parent, ent)
(appc/'Resources/ThirdParty').mkdir()
shutil.copy2(root/'ThirdParty/RHWP-LICENSE.txt', appc/'Resources/ThirdParty/RHWP-LICENSE.txt')
shutil.copy2(root/'LICENSE',appc/'Resources/LICENSE')
(appc/'Resources/BuildInfo.json').write_text(json.dumps({'version':version,'build':build_number,'engine':'@rhwp/core@0.8.7','wasmMaximumBytes':256*1024*1024,'architecture':os.uname().machine,'releaseStatus':'adhoc-signed'},indent=2)+'\n')
sign(app)
print(app)

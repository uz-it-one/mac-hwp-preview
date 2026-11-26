#!/usr/bin/env python3
"""Validate the GitHub updater and one-shot replacement in disposable directories."""
import pathlib
import subprocess
import sys
import tempfile
import zipfile
import stat
root = pathlib.Path(__file__).resolve().parent.parent
probe = root / '.build/github-update-probe'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(root / '.build/module-cache'), str(root / 'App/GitHubReleaseUpdater.swift'), str(root / 'scripts/github-update-probe.swift'), '-o', str(probe)], check=True)
with tempfile.TemporaryDirectory(prefix='hwp-archive-test-') as directory:
    fixtures = pathlib.Path(directory)
    for name, member in [('traversal', '../outside'), ('absolute', '/outside')]:
        with zipfile.ZipFile(fixtures / (name + '.zip'), 'w') as archive:
            archive.writestr(member, 'must not extract')
    with zipfile.ZipFile(fixtures / 'symlink.zip', 'w') as archive:
        item = zipfile.ZipInfo('HWP Preview.app/Contents/outside')
        item.create_system = 3
        item.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(item, '../../../outside')
    subprocess.run([str(probe), '--archive-tests', directory, *sys.argv[1:]], check=True, timeout=240)
for succeeds in [True, False]:
    with tempfile.TemporaryDirectory(prefix='hwp-install-test-') as directory:
        base = pathlib.Path(directory)
        target = base / 'HWP Preview.app'
        staged = base / 'new.app'
        backup = base / 'old.app'
        work = base / 'work'
        for path in [target, staged, work]: path.mkdir()
        (target / 'version').write_text('old')
        (staged / 'version').write_text('new')
        result = base / 'result'
        process = subprocess.run(['/bin/bash', str(root / 'Resources/Updater/install-update.sh'), '99999999', str(staged), str(target), str(backup), str(result), str(work), '/usr/bin/true' if succeeds else '/usr/bin/false'], timeout=10)
        assert (process.returncode == 0) == succeeds
        assert (target / 'version').read_text() == ('new' if succeeds else 'old')
        assert result.read_text().strip() == ('success' if succeeds else 'failed')
        assert not staged.exists() and not backup.exists() and not work.exists()
print('PASS one-shot replacement, launch failure rollback, result marker and cleanup; installed app untouched')

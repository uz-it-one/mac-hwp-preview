#!/usr/bin/env python3
"""Package the generated artwork into the standard macOS icon sizes."""
import pathlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parent.parent
source = root / 'Resources/AppIcon/source.png'
with tempfile.TemporaryDirectory() as directory:
    iconset = pathlib.Path(directory) / 'AppIcon.iconset'
    iconset.mkdir()
    for size in [16, 32, 128, 256, 512]:
        for factor in [1, 2]:
            filename = f'icon_{size}x{size}' + ('@2x' if factor == 2 else '') + '.png'
            subprocess.run(['sips', '-z', str(size*factor), str(size*factor), str(source), '--out', str(iconset / filename)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(root / 'Resources/AppIcon.icns')], check=True)

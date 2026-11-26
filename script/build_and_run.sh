#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_path="$PWD"
app_path="$repo_path/.build/app/HWP Preview.app"
# Stop only this checkout's executable, leaving an installed release alone.
python3 - "$app_path/Contents/MacOS/HWPPreview" <<'PY'
import os, signal, subprocess, sys
for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and fields[1] == sys.argv[1]:
        os.kill(int(fields[0]), signal.SIGTERM)
PY
python3 scripts/build-app.py
/usr/bin/open -n "$app_path"
case "${1:-run}" in
  run) ;;
  --verify) sleep 1; pgrep -x HWPPreview >/dev/null ;;
  --logs) /usr/bin/log stream --info --style compact --predicate 'process == "HWPPreview"' ;;
  *) echo "usage: $0 [--verify|--logs]" >&2; exit 2 ;;
esac

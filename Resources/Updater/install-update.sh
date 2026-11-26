#!/bin/bash
# One-shot child of the app, never registered as a login item or launch agent.
set -eu
parent_pid="$1"
staged_app="$2"
target_app="$3"
backup_app="$4"
result_file="$5"
work_dir="$6"
open_tool="$7"
old_moved=0
new_moved=0
finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then
        if [ "$new_moved" -eq 1 ]; then /bin/rm -rf "$target_app"; fi
        if [ "$old_moved" -eq 1 ]; then /bin/mv "$backup_app" "$target_app" || true; fi
        /usr/bin/printf 'failed\n' > "$result_file"
        "$open_tool" "$target_app" || true
    else
        /bin/rm -rf "$backup_app"
        /usr/bin/printf 'success\n' > "$result_file"
    fi
    /bin/rm -rf "$staged_app" "$work_dir"
    exit "$code"
}
trap finish EXIT
for ((attempt=0; attempt<60; attempt++)); do
    if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then break; fi
    /bin/sleep 1
done
if /bin/kill -0 "$parent_pid" 2>/dev/null; then exit 1; fi
[ -d "$staged_app" ] && [ -d "$target_app" ] && [ ! -e "$backup_app" ]
/bin/mv "$target_app" "$backup_app"
old_moved=1
/bin/mv "$staged_app" "$target_app"
new_moved=1
"$open_tool" "$target_app"

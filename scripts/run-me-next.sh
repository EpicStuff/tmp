#!/usr/bin/env bash
# Always the next thing to run. Overwritten each iteration -
# never holds history. Idempotent: safe to re-run.
#
# This iteration: fix the KWin script metadata.json from the
# earlier recon runs, register them with kpackagetool6 so they
# show up in System Settings, then point you at the manual
# steps that can't be scripted (enabling in System Settings,
# focusing windows, disabling when done).

set -u

echo '=== fixing metadata.json for both KWin scripts ==='
for id in vw-recon vw-recon2; do
    dir=~/.local/share/kwin/scripts/$id
    if [ ! -d "$dir/contents/code" ]; then
        echo "  skip $id - directory does not exist ($dir)"
        continue
    fi
    cat > "$dir/metadata.json" <<EOF
{
    "KPackageStructure": "KWin/Script",
    "KPlugin": {
        "Id": "$id",
        "Name": "$id",
        "Description": "vw-autofill recon",
        "Version": "1.0",
        "License": "MIT",
        "Authors": [{"Name": "vw-autofill"}]
    },
    "X-Plasma-API": "javascript",
    "X-Plasma-MainScript": "code/main.js"
}
EOF
    echo "  wrote $dir/metadata.json"
done

echo
echo '=== registering with kpackagetool6 ==='
for id in vw-recon vw-recon2; do
    dir=~/.local/share/kwin/scripts/$id
    if [ ! -d "$dir" ]; then continue; fi
    if kpackagetool6 -t KWin/Script -l 2>/dev/null | grep -qx "$id"; then
        echo "  $id already registered"
    else
        kpackagetool6 -t KWin/Script -i "$dir" 2>&1 | sed "s/^/  $id: /"
    fi
done

echo
echo '=== registered KWin scripts ==='
kpackagetool6 -t KWin/Script -l 2>&1 | grep vw-recon || echo '  (none found - if this is empty after kpackagetool6 succeeded, restart plasmashell)'

echo
echo '=== manual steps (cannot be scripted) ==='
cat <<'EOF'

1. Open System Settings -> Window Management -> KWin Scripts.
   Close and reopen the pane if it was already open.
   You should now see "vw-recon" and "vw-recon2".
   Enable BOTH. Click Apply.

2. Focus any 2-3 windows of your choice (any apps).

3. Run the screencast portal probe (in a different terminal is fine):
       python3 /tmp/vw-recon-screencast.py
   (If the file is missing, re-run: bash scripts/recon2.sh)

4. Collect the KWin script output:
       journalctl --user --since "5 minutes ago" --no-pager | grep vw-recon

5. Disable both scripts in System Settings when done.

6. Paste back:
   - the journalctl output
   - the screencast probe output
   - /tmp/vw-recon2.log
EOF

from pathlib import Path

bin_dir = Path(r"D:\Projects\comstar\.tmp\bin")
bin_dir.mkdir(parents=True, exist_ok=True)
(bin_dir / "ssh").write_text(
    "#!/usr/bin/env bash\n"
    'exec /usr/bin/ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes '
    '-o IdentitiesOnly=yes -i /c/Users/Zlatko.Lakisic/.ssh/id_rsa "$@"\n',
    encoding="utf-8",
    newline="\n",
)

Path(r"D:\Projects\comstar\.tmp\run_deploy.sh").write_text(
    """#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export MSYS2_ARG_CONV_EXCL='*'
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
export COMSTAR_DEPLOY_HOST=md-admin@192.168.89.34
export COMSTAR_DEPLOY_DIR=/opt/comstar/src
export COMSTAR_DEPLOY_RESTART=1
cd /d/Projects/comstar
echo HOME=$HOME
echo ssh=$(command -v ssh)
ssh -V
ssh "$COMSTAR_DEPLOY_HOST" 'echo SSH_OK'
bash deploy/deploy.sh
ssh "$COMSTAR_DEPLOY_HOST" "find '$COMSTAR_DEPLOY_DIR' -type f -name '*.sh' -exec sed -i 's/\\r$//' {} +; systemctl --user --no-pager is-active comstar-bridge comstar-audio comstar-kiosk comstar-stt || true"
echo Deploy finished.
""",
    encoding="utf-8",
    newline="\n",
)
print("ok")

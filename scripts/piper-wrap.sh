#!/bin/bash
# Wrapper so systemd/Dart always find piper shared libs.
export LD_LIBRARY_PATH="/opt/comstar/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="/opt/comstar/bin:/usr/local/bin:/usr/bin:/bin"
exec /opt/comstar/bin/piper "$@"

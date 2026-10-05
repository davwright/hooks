#!/bin/sh
# Migration shim: repos armed before v3 have stubs that exec this file. The
# judge is git-guard.exe now; its first run refreshes the repo's stubs to v3,
# which exec the exe directly.
exec "$HOME/.githooks/git-guard.exe" "$@"

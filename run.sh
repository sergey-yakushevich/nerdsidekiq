#!/bin/bash
# Launches NerdSidekiq.app through `open`, so launchd starts it as its own
# responsible process. A binary started directly from a shell inherits the
# terminal's TCC identity, and the System Audio Recording permission is then
# checked against the terminal instead of against this app.
set -uo pipefail
cd "$(dirname "$0")"
open -a "$PWD/build/NerdSidekiq.app"

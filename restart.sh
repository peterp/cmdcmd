#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
./build-app.sh "${1:-debug}"
pkill -x cmdcmd 2>/dev/null || true
sleep 0.2
open cmdcmd.app

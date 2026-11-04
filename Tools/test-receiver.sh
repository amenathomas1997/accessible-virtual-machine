#!/bin/bash
# test-receiver.sh
# AVM — Accessible Virtual Machine
#
# The AVM Receiver's Mac side end to end (2026-11-04), with Tools/receiver-client
# in the phone's place, on a throwaway copy of a test machine.
#
#   Tools/test-receiver.sh --vm FOLDER --guest debian|windows [--app PATH]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Library/Caches/AVM-build/DerivedData/Build/Products/Debug/AVM.app"
VM=""; GUEST=debian
while [ $# -gt 0 ]; do
    case "$1" in
        --vm) VM="$2"; shift 2 ;;
        --guest) GUEST="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done
[ -f "$VM/disk.qcow2" ] || { echo "FAILED: no test machine at $VM"; exit 1; }
TOOL="$HOME/Library/Caches/AVM-tools/receiver-client"
mkdir -p "$(dirname "$TOOL")"
xcrun swiftc -O "$HERE/receiver-client/main.swift" "$HERE/../AVM/ReceiverWire.swift" "$HERE/../AVM/ReceiverSound.swift" -o "$TOOL"
WORK="$(dirname "$VM")/$(basename "$VM")-rx-$$"
trap 'rm -rf "$WORK"' EXIT
cp -c -R "$VM" "$WORK"
"$APP/Contents/MacOS/AVM" --test-receiver --vm "$WORK" --guest "$GUEST" --receiver-client "$TOOL"

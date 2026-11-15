#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kinopub-queue-tests.XXXXXX")
trap 'rm -f "$WORK/queue-tests"; rmdir "$WORK"' EXIT
set --
for source in "$ROOT"/Sources/KinoPubDL/*.swift; do
    case "$source" in */App.swift|*/ContentView.swift) ;; *) set -- "$@" "$source" ;; esac
done
swiftc -swift-version 5 -parse-as-library "$@" "$ROOT/Tests/KinoPubDLTests/QueueIntegrationTests.swift" -o "$WORK/queue-tests"
"$WORK/queue-tests"

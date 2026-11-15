#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/kinopub-model-smoke-$$"
trap 'rm -f "$OUT"' EXIT
swiftc \
  "$ROOT/Sources/KinoPubDL/Models.swift" \
  "$ROOT/Sources/KinoPubDL/BrowserCookies.swift" \
  "$ROOT/Sources/KinoPubDL/VLCUploader.swift" \
  "$ROOT/Sources/KinoPubDL/VLCDiscovery.swift" \
  "$ROOT/Sources/KinoPubDL/PipelineProgress.swift" \
  "$ROOT/Sources/KinoPubDL/ProcessRunner.swift" \
  "$ROOT/Sources/KinoPubDL/ToolLocator.swift" \
  "$ROOT/Sources/KinoPubDL/SourceCleanup.swift" \
  "$ROOT/Sources/KinoPubDL/Transcoder.swift" \
  "$ROOT/Sources/KinoPubDL/YTDLPService.swift" \
  "$ROOT/Sources/KinoPubDL/LocalFileTransfer.swift" \
  "$ROOT/Tests/KinoPubDLTests/ModelsTests.swift" \
  "$ROOT/Tests/KinoPubDLTests/PipelineTests.swift" \
  "$ROOT/Tests/KinoPubDLTests/SourceCleanupTests.swift" -o "$OUT"
"$OUT" "$@"

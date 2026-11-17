#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
TIMING_PROBE_MODULE_CACHE="${TMPDIR:-/tmp}/shanchuan-timing-probe-module-cache"
if [[ "${1:-}" == --build-only ]]; then
    [[ $# == 2 ]] || { print -u2 '用法：run-timing-probe.sh --build-only /tmp/timing-probe'; exit 2; }
    swiftc -module-cache-path "$TIMING_PROBE_MODULE_CACHE" -parse-as-library Tests/GlobalShortcuts/TimingProbe.swift -o "$2"
    print -r -- "已编译，未运行：$2"
    exit 0
fi
TIMING_PROBE_WORK="$(mktemp -d /tmp/shanchuan-timing-probe.XXXXXX)"
trap 'rm -rf -- "$TIMING_PROBE_WORK"' EXIT
swiftc -module-cache-path "$TIMING_PROBE_MODULE_CACHE" -parse-as-library Tests/GlobalShortcuts/TimingProbe.swift -o "$TIMING_PROBE_WORK/timing-probe"
"$TIMING_PROBE_WORK/timing-probe" "$@"

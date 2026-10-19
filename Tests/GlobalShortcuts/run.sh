#!/bin/zsh
set -eu
cd "${0:A:h:h:h}"
swift build
SHORTCUT_TEST_DIR=$(mktemp -d /tmp/copytool-shortcut-test.XXXXXX)
trap 'rm -rf "$SHORTCUT_TEST_DIR"' EXIT
swiftc -parse-as-library -I .build/debug Tests/GlobalShortcuts/main.swift Sources/CopyToolApp/GlobalCopyPasteShortcuts.swift .build/debug/libCopyToolCore.a -o "$SHORTCUT_TEST_DIR/probe"
"$SHORTCUT_TEST_DIR/probe"

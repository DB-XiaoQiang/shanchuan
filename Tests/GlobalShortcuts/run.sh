#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
swift build
SHORTCUT_BIN_DIR="$(swift build --show-bin-path)"
SHORTCUT_TEST_DIR="$(mktemp -d /tmp/copytool-shortcut-test.XXXXXX)"
trap 'rm -rf -- "$SHORTCUT_TEST_DIR"' EXIT

# SwiftPM's native layout places modules in Modules and links target objects;
# the Xcode build-system layout exposes the module and static library directly.
SHORTCUT_IMPORTS=(-I "$SHORTCUT_BIN_DIR")
if [[ -d "$SHORTCUT_BIN_DIR/Modules" ]]; then
    SHORTCUT_IMPORTS+=(-I "$SHORTCUT_BIN_DIR/Modules")
fi
if [[ -f "$SHORTCUT_BIN_DIR/libCopyToolCore.a" ]]; then
    SHORTCUT_CORE_LINK=("$SHORTCUT_BIN_DIR/libCopyToolCore.a")
else
    SHORTCUT_CORE_LINK=("$SHORTCUT_BIN_DIR"/CopyToolCore.build/*.o(N))
    (( ${#SHORTCUT_CORE_LINK} > 0 )) || {
        print -u2 "找不到 CopyToolCore 静态库或目标文件：$SHORTCUT_BIN_DIR"
        exit 1
    }
fi
SHORTCUT_RESOURCES="$SHORTCUT_BIN_DIR/CopyTool_CopyToolCore.bundle"
[[ -d "$SHORTCUT_RESOURCES" ]] || {
    print -u2 "找不到快捷键探针所需的语言资源：$SHORTCUT_RESOURCES"
    exit 1
}
# The linked core uses its SwiftPM resource accessor. Stage resources next to the
# temporary executable so it never depends on a development machine's old path.
/usr/bin/ditto "$SHORTCUT_RESOURCES" "$SHORTCUT_TEST_DIR/CopyTool_CopyToolCore.bundle"
swiftc -module-cache-path "$SHORTCUT_TEST_DIR/module-cache" -parse-as-library \
    "${SHORTCUT_IMPORTS[@]}" Tests/GlobalShortcuts/main.swift \
    Sources/CopyToolApp/GlobalCopyPasteShortcuts.swift \
    Sources/CopyToolApp/ShortcutInputGuard.swift \
    "${SHORTCUT_CORE_LINK[@]}" -o "$SHORTCUT_TEST_DIR/probe"
"$SHORTCUT_TEST_DIR/probe" "$@"

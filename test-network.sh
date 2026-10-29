#!/bin/zsh
set -eu
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/main.swift').read_text()
marker = 'if CommandLine.arguments.contains("--self-test") {'
assert source.count(marker) == 1
Path(sys.argv[1]).write_text(source.split(marker)[0] + '\n' + Path('Tests/network.swift').read_text())
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework WebKit -framework Security -framework LocalAuthentication "$TEST_DIR/main.swift" Sources/Website.swift -o "$TEST_DIR/network-tests"
"$TEST_DIR/network-tests"

#!/usr/bin/env bash
# Build an isolated screenshot app. Generated files stay in the ignored .demo/ folder.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/.demo"
mkdir -p "$DEMO_DIR"
SOURCE_DIR="$(mktemp -d "$DEMO_DIR/source.XXXXXX")"
DEMO_HOME="$DEMO_DIR/home"

for item in Package.swift Package.resolved Sources Tests Resources VERSION THIRD_PARTY_NOTICES.md; do
  cp -R "$ROOT_DIR/$item" "$SOURCE_DIR/"
done
mkdir -p "$SOURCE_DIR/scripts"
cp "$ROOT_DIR/scripts/build-app.sh" "$SOURCE_DIR/scripts/"

# Patch only the disposable copy, leaving production behavior unchanged.
python3 - "$SOURCE_DIR" "$DEMO_HOME" <<'PY'
import json
from pathlib import Path
import sys
source, home = Path(sys.argv[1]), str(Path(sys.argv[2]).resolve())
p = source / 'Sources/PiG/Models.swift'
s = p.read_text()
s = s.replace('static let home = FileManager.default.homeDirectoryForCurrentUser',
              f'static let home = URL(fileURLWithPath: {json.dumps(home)}, isDirectory: true)')
p.write_text(s)
p = source / 'Sources/PiG/RootView.swift'
p.write_text(p.read_text().replace('let home = FileManager.default.homeDirectoryForCurrentUser.path',
                                   'let home = PiPaths.home.path'))
p = source / 'Sources/PiG/PiEnvironment.swift'
s = p.read_text()
# Force the isolated agent directory even after loading the user's shell environment.
s = s.replace('return environment\n', 'environment["PI_CODING_AGENT_DIR"] = PiPaths.agentDir.path\n        return environment\n')
s = s.replace('return env\n', 'env["PI_CODING_AGENT_DIR"] = PiPaths.agentDir.path\n        return env\n')
p.write_text(s)
# PiPaths.agentDir must not inherit an agent-directory override from the real shell.
p = source / 'Sources/PiG/Models.swift'
s = p.read_text().replace('let value = PiEnvironment.current["PI_CODING_AGENT_DIR"]',
                         'let value: String? = home.appendingPathComponent(".pi/agent").path')
p.write_text(s)
PY

PIG_BUNDLE_ID=com.jacob.pig.demo PIG_SIGN_ID=- \
PIG_BUILD_DIR="$ROOT_DIR/.build/demo" PIG_DIST_DIR="$DEMO_DIR" \
  bash "$SOURCE_DIR/scripts/build-app.sh" "$@"

# Preserve any changes made in the demo between builds.
if [[ ! -e "$DEMO_HOME/Library/Application Support/PiG/projects.json" ]]; then
  python3 "$ROOT_DIR/scripts/seed-demo.py" "$DEMO_HOME"
fi
printf '\nDemo: %s\nRun: open "%s"\n' "$DEMO_DIR/PiG.app" "$DEMO_DIR/PiG.app"

#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$(uname -s)" in
  Linux) PLATFORM=Linux ;;
  Darwin) PLATFORM=macOS ;;
  *) echo "Unsupported host: $(uname -s)" >&2; exit 2 ;;
esac
BUNDLED_PYTHON="$ROOT/../../Dependencies/Non-Packageable/$PLATFORM/python/bin/python3"
if [ -x "$BUNDLED_PYTHON" ]; then
  exec "$BUNDLED_PYTHON" "$ROOT/tool/release.py" "$@"
fi
exec python3 "$ROOT/tool/release.py" "$@"

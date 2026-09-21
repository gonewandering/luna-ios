#!/bin/zsh
set -eu
LUNA_ROOT="${0:A:h:h}"
cd "$LUNA_ROOT"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
fi
if ! .venv/bin/python -c 'import luna' 2>/dev/null; then
  .venv/bin/python -m pip install -r service/requirements.lock
  .venv/bin/python -m pip install -e './service[test]'
fi
cd service
# Keep the demo independent of an existing real-agent .env configuration.
export LUNA_TOKEN=luna-local-demo
export LUNA_HOST=127.0.0.1
export LUNA_PORT=8787
export LUNA_DATABASE=.state/demo.sqlite
exec ../.venv/bin/python -m luna --demo

#!/usr/bin/env bash
# Creates the test owner and Admin API key on the test Ghost. Run by scripts/testenv.sh.
# Writes generated TEST credentials + an Admin API key to .dev/ghost-dev.env (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
H="${GHOST_DEV_URL:-http://localhost:2369}"
ENV=.dev/ghost-dev.env
mkdir -p .dev; umask 077

if [[ ! -f "$ENV" ]]; then
  echo "GHOST_DEV_URL=$H" > "$ENV"
  echo "GHOST_DEV_EMAIL=dev@quill.test" >> "$ENV"
  echo "GHOST_DEV_PASSWORD=$(openssl rand -hex 16)" >> "$ENV"
fi
. "$ENV"

JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
status=$(curl -s "$H/ghost/api/admin/authentication/setup/" | python3 -c 'import json,sys;print(json.load(sys.stdin)["setup"][0]["status"])')
if [[ "$status" == "False" ]]; then
  curl -sf -H "Origin: $H" -H "Content-Type: application/json" \
    -d "{\"setup\":[{\"name\":\"Quill Dev\",\"email\":\"$GHOST_DEV_EMAIL\",\"password\":\"$GHOST_DEV_PASSWORD\",\"blogTitle\":\"Quill Dev\"}]}" \
    "$H/ghost/api/admin/authentication/setup/" >/dev/null
  echo "owner created"
fi
curl -sf -c "$JAR" -H "Origin: $H" -H "Content-Type: application/json" \
  -d "{\"username\":\"$GHOST_DEV_EMAIL\",\"password\":\"$GHOST_DEV_PASSWORD\"}" "$H/ghost/api/admin/session" >/dev/null

if ! grep -q '^GHOST_DEV_ADMIN_KEY=' "$ENV"; then
  KEY=$(curl -sf -b "$JAR" -H "Origin: $H" -H "Content-Type: application/json" \
    -d '{"integrations":[{"name":"Quill tests"}]}' "$H/ghost/api/admin/integrations/?include=api_keys" |
    python3 -c 'import json,sys;i=json.load(sys.stdin)["integrations"][0];print([k["secret"] for k in i["api_keys"] if k["type"]=="admin"][0])')
  echo "GHOST_DEV_ADMIN_KEY=$KEY" >> "$ENV"
  echo "admin key saved"
fi
echo "dev Ghost ready at $H (credentials in $ENV)"

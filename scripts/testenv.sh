#!/usr/bin/env bash
# Manage the test Ghost. See TESTING.md.
#   scripts/testenv.sh up      deploy, start, open the tunnel, seed credentials
#   scripts/testenv.sh tunnel  reopen just the tunnel
#   scripts/testenv.sh status  show what's running
#   scripts/testenv.sh reset   delete all test content and start fresh
#   scripts/testenv.sh down    stop Ghost and close the tunnel (keeps content)
# Settings: QUILL_TEST_HOST (ssh host, default docker-server),
#           QUILL_TEST_DIR  (remote directory, default /opt/ghost-dev)
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${QUILL_TEST_HOST:-docker-server}"
DIR="${QUILL_TEST_DIR:-/opt/ghost-dev}"
URL=http://localhost:2369
PIDFILE=.dev/tunnel.pid
mkdir -p .dev

tunnel_up() { [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

open_tunnel() {
  tunnel_up && return
  ssh -f -N -o ExitOnForwardFailure=yes -L 2369:127.0.0.1:2369 "$HOST"
  pgrep -f "ssh -f -N .*2369:127.0.0.1:2369" | tail -1 > "$PIDFILE"
}

close_tunnel() {
  tunnel_up && kill "$(cat "$PIDFILE")" || true
  rm -f "$PIDFILE"
}

wait_ready() {
  printf 'waiting for Ghost'
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "$URL/ghost/api/admin/site/"; then echo ' ready'; return; fi
    printf '.'; sleep 3
  done
  echo; echo "Ghost didn't come up. Check: ssh $HOST 'cd $DIR && docker compose logs --tail 50'" >&2
  exit 1
}

deploy() {
  ssh "$HOST" "mkdir -p '$DIR/content' && chown 1000:1000 '$DIR/content'"
  scp -q testenv/docker-compose.yml "$HOST:$DIR/docker-compose.yml"
  ssh "$HOST" "cd '$DIR' && docker compose pull -q && docker compose up -d"
}

case "${1:-}" in
  up)
    deploy; open_tunnel; wait_ready; scripts/dev-ghost-seed.sh ;;
  tunnel)
    open_tunnel; wait_ready ;;
  status)
    ssh "$HOST" "cd '$DIR' && docker compose ps --format '{{.Name}} {{.Image}} {{.Status}}'"
    tunnel_up && echo "tunnel: open" || echo "tunnel: closed"
    curl -s -m 5 -o /dev/null -w "ghost at $URL: %{http_code}\n" "$URL/ghost/api/admin/site/" || true
    [[ -f .dev/ghost-dev.env ]] && echo "credentials: .dev/ghost-dev.env" || echo "credentials: missing" ;;
  reset)
    ssh "$HOST" "cd '$DIR' && docker compose down && find content -mindepth 1 -delete"
    rm -f .dev/ghost-dev.env
    deploy; open_tunnel; wait_ready; scripts/dev-ghost-seed.sh ;;
  down)
    close_tunnel
    ssh "$HOST" "cd '$DIR' && docker compose down" ;;
  *)
    sed -n '2,8p' "$0"; exit 1 ;;
esac

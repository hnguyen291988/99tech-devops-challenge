#!/usr/bin/env bash
#
# Boots the stack and asserts the behaviours that were broken. This is the piece
# that stops the bugs coming back: it belongs in CI on every pull request, and it
# is why "we fixed it" becomes a check rather than a claim.
#
#   ./smoke-test.sh              boot, test, leave running
#   ./smoke-test.sh --teardown   boot, test, tear down
#
set -Eeuo pipefail

cd "$(dirname "$0")"
BASE="http://localhost:${LISTEN_PORT:-8080}"
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# expect_status <label> <expected-code> <url> [max-seconds]
expect_status() {
  local label=$1 want=$2 url=$3 budget=${4:-10}
  local out code secs
  out=$(curl -sS -o /dev/null -m "$budget" -w '%{http_code} %{time_total}' "$url" 2>/dev/null || echo "000 $budget")
  code=${out%% *}; secs=${out##* }
  if [[ "$code" == "$want" ]]; then
    ok "$label -> $code in ${secs}s"
  else
    bad "$label -> got $code, wanted $want (${secs}s)"
  fi
}

section "Booting the stack"
docker compose up --build -d --wait
docker compose ps

section "1. The API is reachable through nginx"
# The original stack returned 502 here forever: nginx proxied to :3001, the app
# listened on :3000.
expect_status "GET /api/users" 200 "$BASE/api/users"
if curl -sS -m 10 "$BASE/api/users" | grep -q '"ok":true'; then
  ok "response body has ok:true"
  curl -sS -m 10 "$BASE/api/users" | head -c 200; echo
else
  bad "response body missing ok:true"
fi

section "2. Health endpoints answer through the load balancer"
# /status used to exist on the app but had no nginx location, so it 404'd.
expect_status "GET /healthz" 200 "$BASE/healthz"
expect_status "GET /readyz"  200 "$BASE/readyz"
curl -sS -m 10 "$BASE/readyz"; echo

section "3. Losing the cache degrades the service, it does not break it"
# Previously this took ~10s and returned 500: the handler awaited a Redis write
# on the read path with ioredis' default 20 retries.
docker compose stop redis >/dev/null 2>&1
sleep 1
start=$(date +%s%N)
code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$BASE/api/users" || echo 000)
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
if [[ "$code" == "200" && "$elapsed_ms" -lt 2000 ]]; then
  ok "redis down: still 200, ${elapsed_ms}ms"
else
  bad "redis down: got $code in ${elapsed_ms}ms (wanted 200 under 2000ms)"
fi
if curl -sS -m 10 "$BASE/readyz" | grep -q '"degraded":true'; then
  ok "/readyz reports degraded rather than lying"
else
  bad "/readyz did not report degraded"
fi
docker compose start redis >/dev/null 2>&1

section "4. An unresponsive database fails fast instead of hanging"
# Previously this hung indefinitely: no connectionTimeoutMillis, no
# statement_timeout, so the request never returned and nginx had no read timeout.
docker compose pause postgres >/dev/null 2>&1
expect_status "GET /api/users, postgres frozen" 503 "$BASE/api/users" 12
docker compose unpause postgres >/dev/null 2>&1
sleep 2

section "5. Repeated database failures do not exhaust the connection pool"
# The original handler leaked a client on every failed query. After DB_POOL_MAX
# failures the API hung forever and only a restart brought it back.
docker compose pause postgres >/dev/null 2>&1
for _ in $(seq 1 15); do curl -sS -o /dev/null -m 8 "$BASE/api/users" >/dev/null 2>&1 & done
wait
docker compose unpause postgres >/dev/null 2>&1
sleep 3
expect_status "GET /api/users after 15 failures" 200 "$BASE/api/users"

section "6. Every container declares a healthcheck and a restart policy"
for c in $(docker compose ps -q); do
  name=$(docker inspect --format '{{.Name}}' "$c" | tr -d /)
  hc=$(docker inspect --format '{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$c")
  rp=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$c")
  lo=$(docker inspect --format '{{index .HostConfig.LogConfig.Config "max-size"}}' "$c")
  if [[ "$hc" == "yes" && "$rp" == "unless-stopped" && -n "$lo" ]]; then
    ok "$name: healthcheck=$hc restart=$rp log-max-size=$lo"
  else
    bad "$name: healthcheck=$hc restart=$rp log-max-size=${lo:-none}"
  fi
done

section "7. The API container does not run as root"
uid=$(docker compose exec -T api id -u | tr -d '\r')
[[ "$uid" != "0" ]] && ok "api runs as uid $uid" || bad "api still runs as root"

section "8. The API is not reachable except through nginx"
# Any port with a host binding shows up here; "expose" alone does not.
published=$(docker inspect --format \
  '{{range $p, $c := .NetworkSettings.Ports}}{{if $c}}{{$p}} {{end}}{{end}}' \
  "$(docker compose ps -q api)" | tr -d ' ')
if [[ -n "$published" ]]; then
  bad "api publishes $published to the host"
else
  ok "api has no host port binding; only nginx is exposed"
fi

section "Result"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"

if [[ "${1:-}" == "--teardown" ]]; then
  docker compose down -v
fi

[[ "$FAIL" -eq 0 ]]

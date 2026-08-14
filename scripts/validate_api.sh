#!/usr/bin/env bash
# End-to-end validation of the tool endpoints over the REST API.
#
# Creates a tool via the create_tool RPC, writes a row to its table endpoint,
# reads it back and deletes the tool again. The write happens immediately after
# the create, so this also proves that the pgrst_watch event trigger reloads
# PostgREST's schema cache: without it the new table has no endpoint yet.
#
# Usage:
#   scripts/validate_api.sh [api_url] [postgrest_container]
#
#   scripts/validate_api.sh                              # local stack
#   scripts/validate_api.sh https://db.test.terravac.cloud
#
# The JWT is minted here from PGRST_JWT_SECRET, read out of the container's
# environment; the secret is never printed. Requires curl and openssl.

set -uo pipefail

API="${1:-http://127.0.0.1:3000}"
CONTAINER="${2:-postgrest_container}"
TOOL="OSW$(printf '%032d' "$(date +%s)")"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v curl    >/dev/null || fail "curl not found"
command -v openssl >/dev/null || fail "openssl not found"

SECRET="$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
          | sed -n 's/^PGRST_JWT_SECRET=//p')"
[ -n "$SECRET" ] || fail "PGRST_JWT_SECRET not found in container $CONTAINER"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
payload="$(printf '%s' '{"role":"api_user"}' | b64url)"
signature="$(printf '%s' "$header.$payload" \
             | openssl dgst -binary -sha256 -hmac "$SECRET" | b64url)"
JWT="$header.$payload.$signature"

AUTH="Authorization: Bearer $JWT"
JSON="Content-Type: application/json"

echo "api  : $API"
echo "tool : $TOOL"
echo

# 1. create the tool (RPC) --------------------------------------------------
code="$(curl -s -o /tmp/va_create.out -w '%{http_code}' -X POST "$API/rpc/create_tool" \
        -H "$AUTH" -H "$JSON" -d "{\"osw_tool\":\"$TOOL\"}")"
[ "$code" = "200" ] || fail "create_tool returned $code: $(cat /tmp/va_create.out)"
echo "1. create_tool            OK  $(cat /tmp/va_create.out)"

# 2. write to the new table endpoint ---------------------------------------
# Retry briefly: the schema cache reload triggered by pgrst_watch is async.
row="{\"ch\":\"validation-channel\",\"ts\":\"2026-01-01T00:00:00Z\",\"data\":{\"v\":42}}"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -s -o /tmp/va_write.out -w '%{http_code}' -X POST "$API/$TOOL" \
            -H "$AUTH" -H "$JSON" -H "Prefer: return=representation" -d "$row")"
    [ "$code" = "201" ] && break
    sleep 1
done
[ "$code" = "201" ] || fail "write returned $code after ${attempt}s: $(cat /tmp/va_write.out)"
echo "2. write row              OK  (endpoint live after ${attempt}s, schema cache reloaded)"

# 3. read it back -----------------------------------------------------------
code="$(curl -s -o /tmp/va_read.out -w '%{http_code}' \
        "$API/$TOOL?select=ch,ts,data&ch=eq.validation-channel" -H "$AUTH")"
[ "$code" = "200" ] || fail "read returned $code: $(cat /tmp/va_read.out)"
grep -q '"v"[[:space:]]*:[[:space:]]*42' /tmp/va_read.out \
    || fail "read did not return the written value: $(cat /tmp/va_read.out)"
echo "3. read row               OK  $(cat /tmp/va_read.out)"

# 4. delete the tool again --------------------------------------------------
code="$(curl -s -o /tmp/va_delete.out -w '%{http_code}' -X POST "$API/rpc/delete_tool" \
        -H "$AUTH" -H "$JSON" -d "{\"osw_tool\":\"$TOOL\"}")"
[ "$code" = "200" ] || fail "delete_tool returned $code: $(cat /tmp/va_delete.out)"
echo "4. delete_tool            OK  $(cat /tmp/va_delete.out)"

# 5. confirm the endpoint is gone ------------------------------------------
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -s -o /tmp/va_gone.out -w '%{http_code}' "$API/$TOOL?limit=1" -H "$AUTH")"
    [ "$code" = "404" ] && break
    sleep 1
done
[ "$code" = "404" ] || fail "endpoint still answers with $code after delete_tool"
echo "5. endpoint removed       OK  (404)"

rm -f /tmp/va_create.out /tmp/va_write.out /tmp/va_read.out /tmp/va_delete.out /tmp/va_gone.out
echo
echo "PASS: create, write, read and delete all work over the REST API."

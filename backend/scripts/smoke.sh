#!/usr/bin/env bash
# End-to-end smoke test against a running worker. Creates and deletes its own set.
#   BASE_URL=http://localhost:8898 ./scripts/smoke.sh          # token read from .dev.vars
#   BASE_URL=https://eidetic.<sub>.workers.dev TOKEN=eid_… ./scripts/smoke.sh
# Covers: REST auth, MCP over the APP_TOKEN header (create/add/update/delete),
# review sync (idempotency, ordering, deleted cards), and the full OAuth dance:
# DCR -> PKCE authorize -> wrong code -> app-minted code -> token -> tools/list.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_URL=${BASE_URL:-http://localhost:8898}
TOKEN=${TOKEN:-$(sed -n 's/^APP_TOKEN=//p' .dev.vars)}
JSON="Content-Type: application/json"
ACCEPT="Accept: application/json, text/event-stream"
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

# MCP tool call over the header bypass; prints the tool's JSON payload.
mcp() {
  local name=$1 args=$2 auth=${3:-$TOKEN}
  curl -s -X POST -H "Authorization: Bearer $auth" -H "$JSON" -H "$ACCEPT" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}" \
    "$BASE_URL/mcp" | sed -n 's/^data: //p' | jq -r '.result.content[0].text'
}

# --- auth ---
[[ $(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/library") == 401 ]] || fail "unauthenticated /api should 401"
[[ $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer eid_wrong" "$BASE_URL/api/library") == 401 ]] || fail "wrong token should 401"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer eid_wrong" -H "$JSON" -H "$ACCEPT" -d '{}' "$BASE_URL/mcp") == 401 ]] || fail "wrong token on /mcp should 401"
pass "bad credentials rejected"

# --- MCP CRUD ---
SET=$(mcp create_set '{"name":"smoke test","cards":[{"front":"2+2","back":"4"},{"front":"capital of France","back":"Paris"}]}')
SET_ID=$(jq -r .id <<<"$SET")
[[ $(jq -r .card_count <<<"$SET") == 2 ]] || fail "create_set: $SET"
pass "create_set with 2 cards"

ADDED=$(mcp add_cards "{\"set_id\":\"$SET_ID\",\"cards\":[{\"front\":\"**bold** q\",\"back\":\"a\"}]}")
CARD3=$(jq -r '.added[0].id' <<<"$ADDED")
[[ -n "$CARD3" && "$CARD3" != null ]] || fail "add_cards: $ADDED"
pass "add_cards"

GOT=$(mcp get_set "{\"set_id\":\"$SET_ID\"}")
CARD1=$(jq -r '.cards[0].id' <<<"$GOT")
[[ $(jq -r '.cards | length' <<<"$GOT") == 3 && $(jq -r '.cards[2].front' <<<"$GOT") == "**bold** q" ]] || fail "get_set order: $GOT"
pass "get_set returns cards in order"

[[ $(mcp get_set '{"set_id":"nope"}' | jq -r .error) == "no set nope" ]] || fail "unknown set should be a tool error"
pass "unknown ids are tool errors"

# --- review sync ---
R1=$(uuidgen | tr A-Z a-z)
review() { # id card reviewed_at due
  printf '{"reviews":[{"id":"%s","card_id":"%s","rating":3,"reviewed_at":"%s","duration_ms":1200,"prior_state":"new","card":{"state":"learning","step":1,"stability":2.3,"difficulty":5.1,"due":"%s","reps":1,"lapses":0,"introduced_at":"%s"}}]}' "$1" "$2" "$3" "$4" "$3"
}
SYNC=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "$JSON" -d "$(review "$R1" "$CARD1" 2026-09-20T10:00:00Z 2026-09-20T10:10:00Z)" "$BASE_URL/api/reviews")
[[ $(jq -r '.accepted[0]' <<<"$SYNC") == "$R1" ]] || fail "review sync: $SYNC"
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "$JSON" -d "$(review "$R1" "$CARD1" 2026-09-20T10:00:00Z 2026-09-20T10:10:00Z)" "$BASE_URL/api/reviews" >/dev/null
OLDER=$(uuidgen | tr A-Z a-z)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "$JSON" -d "$(review "$OLDER" "$CARD1" 2026-09-19T10:00:00Z 2030-01-01T00:00:00Z)" "$BASE_URL/api/reviews" >/dev/null
LIB=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/library")
C1=$(jq -c --arg id "$CARD1" '.sets[].cards[] | select(.id == $id)' <<<"$LIB")
[[ $(jq -r .due <<<"$C1") == 2026-09-20T10:10:00Z && $(jq -r .state <<<"$C1") == learning ]] || fail "older replay overwrote newer: $C1"
pass "review sync is idempotent and never moves scheduling backwards"

GHOST=$(uuidgen | tr A-Z a-z)
[[ $(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "$JSON" -d "$(review "$GHOST" deleted-card 2026-09-20T10:00:00Z 2026-09-21T10:00:00Z)" "$BASE_URL/api/reviews" | jq -r '.missing[0]') == "$GHOST" ]] || fail "missing card not reported"
pass "reviews of deleted cards come back as missing"

UPD=$(mcp update_cards "{\"cards\":[{\"card_id\":\"$CARD1\",\"back\":\"four\"}]}")
[[ $(jq -r '.updated[0].back' <<<"$UPD") == four && $(jq -r '.updated[0].reps' <<<"$UPD") == 1 ]] || fail "update keeps progress: $UPD"
UPD=$(mcp update_cards "{\"cards\":[{\"card_id\":\"$CARD1\",\"reset_progress\":true}]}")
[[ $(jq -r '.updated[0].state' <<<"$UPD") == new ]] || fail "reset_progress: $UPD"
pass "update_cards edits text, keeps progress unless reset"

[[ $(mcp delete_cards "{\"card_ids\":[\"$CARD3\",\"ghost\"]}" | jq -c .) == "{\"deleted\":[\"$CARD3\"],\"missing\":[\"ghost\"]}" ]] || fail "delete_cards"
pass "delete_cards"

# --- OAuth ---
AS_META=$(curl -s "$BASE_URL/.well-known/oauth-authorization-server")
jq -e '.code_challenge_methods_supported | index("S256")' <<<"$AS_META" >/dev/null || fail "AS metadata: $AS_META"
CHALLENGE=$(curl -s -o /dev/null -D - -X POST -H "$JSON" -d '{}' "$BASE_URL/mcp")
grep -qi 'www-authenticate:.*resource_metadata' <<<"$CHALLENGE" || fail "bare /mcp missing OAuth challenge"
pass "OAuth discovery + 401 challenge"

REG=$(curl -s -X POST -H "$JSON" -d '{"client_name":"Smoke <b>Client</b>","redirect_uris":["http://localhost:9993/callback"],"token_endpoint_auth_method":"none","grant_types":["authorization_code"],"response_types":["code"]}' "$BASE_URL/register")
CLIENT_ID=$(jq -r .client_id <<<"$REG")
VERIFIER=$(openssl rand -hex 32)
S256=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=\n')
REDIRECT=http%3A%2F%2Flocalhost%3A9993%2Fcallback
PAGE=$(curl -s -c "$JAR" -b "$JAR" "$BASE_URL/authorize?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT&scope=eidetic&state=smokestate&code_challenge=$S256&code_challenge_method=S256&resource=$(jq -rn --arg u "$BASE_URL/mcp" '$u|@uri')")
grep -q 'Smoke &#60;b&#62;Client' <<<"$PAGE" || fail "client name not escaped on consent page"
HANDLE=$(grep -o 'name="handle" value="[^"]*"' <<<"$PAGE" | head -1 | cut -d'"' -f4)
[[ -n "$HANDLE" ]] || fail "consent page missing handle"
pass "consent page rendered (client name escaped)"

WRONG=$(curl -s -c "$JAR" -b "$JAR" -X POST --data-urlencode "handle=$HANDLE" -d "decision=approve&code=AAAA-AAAA&client_id=$CLIENT_ID&redirect_host=localhost" "$BASE_URL/authorize")
grep -q "didn&#39;t match\|didn't match" <<<"$WRONG" || fail "wrong code should re-render with error"
pass "wrong code re-renders the form"

CODE=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/connect-code" | jq -r .code)
LOCATION=$(curl -s -c "$JAR" -b "$JAR" -o /dev/null -D - -X POST --data-urlencode "handle=$HANDLE" -d "decision=approve&code=$(tr A-Z a-z <<<"$CODE")" "$BASE_URL/authorize" | grep -i '^location:' | tr -d '\r' | cut -d' ' -f2)
AUTH_CODE=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$LOCATION")
[[ -n "$AUTH_CODE" ]] && grep -q 'state=smokestate' <<<"$LOCATION" || fail "no auth code in redirect: $LOCATION"
pass "app-minted code approves (case-insensitive) -> auth code"

TOKENS=$(curl -s -X POST -d "grant_type=authorization_code&code=$AUTH_CODE&redirect_uri=$REDIRECT&client_id=$CLIENT_ID&code_verifier=$VERIFIER" "$BASE_URL/token")
ACCESS=$(jq -r .access_token <<<"$TOKENS")
[[ -n "$ACCESS" && "$ACCESS" != null ]] || fail "token exchange: $TOKENS"
TOOLS=$(curl -s -X POST -H "Authorization: Bearer $ACCESS" -H "$JSON" -H "$ACCEPT" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$BASE_URL/mcp" | sed -n 's/^data: //p' | jq -r '.result.tools | length')
[[ "$TOOLS" -ge 9 ]] || fail "tools/list over OAuth: $TOOLS"
pass "OAuth access token lists $TOOLS tools"

# Replaying the spent code: rejected at the code check, before the handle is even tried.
REUSE=$(curl -s -c "$JAR" -b "$JAR" -D - -X POST --data-urlencode "handle=$HANDLE" -d "decision=approve&code=$CODE" "$BASE_URL/authorize")
grep -qi '^location:' <<<"$REUSE" && fail "spent code approved twice"
grep -q "didn&#39;t match\|didn't match" <<<"$REUSE" || fail "spent code should re-render with error"
# Spent handle with a fresh code: the provider refuses it.
CODE2=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/connect-code" | jq -r .code)
REUSE=$(curl -s -c "$JAR" -b "$JAR" -D - -X POST --data-urlencode "handle=$HANDLE" -d "decision=approve&code=$CODE2" "$BASE_URL/authorize")
grep -qi '^location:' <<<"$REUSE" && fail "spent handle approved twice"
grep -q "Start again" <<<"$REUSE" || fail "spent handle should show an error page"
pass "connect codes and consent handles are single-use"

[[ $(mcp delete_set "{\"set_id\":\"$SET_ID\"}" | jq -r .deleted) == "$SET_ID" ]] || fail "delete_set"
pass "delete_set (cleanup)"

#!/usr/bin/env bash
# Tests for caravana-deploy.sh against test/fake_caravana.py.
#
#   bash test/run.sh
#
# Each case starts the fake on a free port with a scenario, runs the script
# with GitHub-like environment variables, and checks the exit code, the
# step's output, the outputs file, the job summary and the requests the fake
# saw. After every case it also checks that the token appears nowhere it
# shouldn't: not in the log, outputs, summary, request paths, or any process
# command line sampled while the script ran.
#
# Needs bash, curl, jq and python3. Works with bash 3.2 (macOS).
# SC2016: backticks in single quotes are literal Markdown. SC2163: "export \"$@\"" exports the VAR=value words.
# shellcheck disable=SC2016,SC2163
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$(dirname "$here")/caravana-deploy.sh"
tmp="$(mktemp -d)"
fake_pid=""
sampler_pid=""

cleanup() {
  [ -n "$fake_pid" ] && kill "$fake_pid" 2> /dev/null
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2> /dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

TOKEN="cvat_TESTTOKEN0123456789abcdefghijklmnopqrstuvwxyzABCDEF"
IMG="ghcr.io/acme/web@sha256:$(printf 'd%.0s' $(seq 1 64))"
REV="0123456789abcdef"

failures=0
checks=0
pass() { checks=$((checks + 1)); }
fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "  FAIL [$case_name] $1"
  [ -n "${2:-}" ] && echo "       $2"
  return 0
}

# --------------------------------------------------------------- scenario

cat > "$tmp/base.json" << EOF
{
  "token": "$TOKEN",
  "delay": 0,
  "app": {
    "defined": true,
    "revision": "$REV",
    "app": {
      "id": "web",
      "source": {"kind": "image"},
      "services": [
        {"name": "web", "image": "ghcr.io/acme/web:latest", "port": 8080, "env": {"A": "1"}}
      ]
    }
  },
  "deploy": {"final": "healthy", "polls": 1, "warnings": []},
  "promote": {"target": "shop--production--web", "final": "healthy", "polls": 1}
}
EOF

cat > "$tmp/def.json" << 'EOF'
{"source": {"kind": "image"}, "services": [{"name": "web", "image": "ghcr.io/acme/web:placeholder", "port": 9999}]}
EOF
cat > "$tmp/def2.json" << 'EOF'
{"source": {"kind": "image"}, "services": [{"name": "web", "image": "a/web:1"}, {"name": "worker", "image": "a/worker:1"}]}
EOF
echo 'this is not json' > "$tmp/bad.json"

TWO_SERVICES='{"app":{"app":{"id":"web","source":{"kind":"image"},"services":[
  {"name":"api","image":"a/api:1","port":8080},{"name":"worker","image":"a/worker:1"}]}}}'

# ----------------------------------------------------------------- running

# run_case NAME OVERLAY [VAR=value ...]
# Runs the script once. VAR=value arguments are exported for the script on top
# of the defaults below ("VAR=" empties one). Afterwards: $status is the exit
# code, $out the step's output file, $outputs, $summary, $log the files.
run_case() {
  case_name="$1"
  local overlay="$2"
  shift 2
  dir="$tmp/case-$case_name"
  mkdir -p "$dir"
  out="$dir/out"
  outputs="$dir/outputs"
  summary="$dir/summary"
  log="$dir/log.json"
  : > "$out"

  printf '%s' "$overlay" > "$dir/overlay.json"
  jq -s '.[0] * .[1]' "$tmp/base.json" "$dir/overlay.json" > "$dir/scenario.json" ||
    { echo "bad overlay in $case_name"; exit 2; }

  python3 -I "$here/fake_caravana.py" "$dir/port" "$log" "$dir/scenario.json" &
  fake_pid=$!
  local i=0
  while [ ! -s "$dir/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$dir/port" ] || { echo "the fake did not start"; exit 2; }
  local port
  port="$(cat "$dir/port")"

  # Sample every process command line while the script runs.
  : > "$dir/ps"
  (while [ ! -e "$dir/done" ]; do ps -axww -o args= >> "$dir/ps" 2> /dev/null; sleep 0.02; done) &
  sampler_pid=$!

  case_token="$TOKEN"
  local a
  for a in "$@"; do
    case "$a" in CARAVANA_TOKEN=*) case_token="${a#CARAVANA_TOKEN=}" ;; esac
  done

  (
    for v in $(env | grep -E '^(GITHUB|CARAVANA)_' | cut -d= -f1); do unset "$v"; done
    export CARAVANA_URL="http://127.0.0.1:$port"
    export CARAVANA_TOKEN="$TOKEN"
    export CARAVANA_POLL_SECONDS=0.1
    export GITHUB_OUTPUT="$outputs"
    export GITHUB_STEP_SUMMARY="$summary"
    export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
    export GITHUB_REF=refs/heads/main
    export GITHUB_ACTOR=ana
    export GITHUB_SERVER_URL=https://github.com
    export GITHUB_REPOSITORY=acme/web
    export GITHUB_RUN_ID=212
    [ "$#" -gt 0 ] && export "$@"
    exec "$script"
  ) > "$out" 2>&1
  status=$?

  touch "$dir/done"
  wait "$sampler_pid" 2> /dev/null
  sampler_pid=""
  kill "$fake_pid" 2> /dev/null
  wait "$fake_pid" 2> /dev/null
  fake_pid=""
  [ -f "$log" ] || echo '[]' > "$log"

  check_no_token_leak
}

# The token may appear in the ::add-mask:: line (that is how the runner learns
# what to hide) and in the Authorization header the fake saw. Nowhere else.
check_no_token_leak() {
  [ -n "$case_token" ] || return 0
  if grep -v '^::add-mask::' "$out" | grep -qF -- "$case_token"; then
    fail "the token is in the step's output"
  else pass; fi
  if [ -f "$outputs" ] && grep -qF -- "$case_token" "$outputs"; then fail "the token is in the outputs file"; else pass; fi
  if [ -f "$summary" ] && grep -qF -- "$case_token" "$summary"; then fail "the token is in the job summary"; else pass; fi
  if jq -r '.[].path' "$log" | grep -qF -- "$case_token"; then fail "the token is in a request URL"; else pass; fi
  if jq -r '.[] | (.body, (.headers | del(.authorization) | tostring))' "$log" | grep -qF -- "$case_token"; then
    fail "the token is in a request body or another header"
  else pass; fi
  if grep -qF -- "$case_token" "$dir/ps"; then fail "the token is on a process command line"; else pass; fi
}

# ------------------------------------------------------------- assertions

exit_is() { # EXPECTED
  if [ "$status" = "$1" ]; then pass; else fail "exit code $status, wanted $1" "$(tail -n 5 "$out" | tr '\n' '|')"; fi
}
out_has() { # TEXT
  if grep -qF -- "$1" "$out"; then pass; else fail "output lacks: $1" "$(tail -n 6 "$out" | tr '\n' '|')"; fi
}
out_lacks() { # TEXT
  if grep -qF -- "$1" "$out"; then fail "output has: $1"; else pass; fi
}
outputs_has() { # name=value
  if [ -f "$outputs" ] && grep -qxF -- "$1" "$outputs"; then pass; else fail "outputs lack: $1" "$(tr '\n' '|' < "$outputs" 2> /dev/null)"; fi
}
outputs_lack() { # name
  if [ -f "$outputs" ] && grep -q "^$1=" "$outputs"; then fail "outputs have $1"; else pass; fi
}
summary_has() { # TEXT
  if [ -f "$summary" ] && grep -qF -- "$1" "$summary"; then pass; else fail "summary lacks: $1" "$(tr '\n' '|' < "$summary" 2> /dev/null)"; fi
}
eq() { # WHAT EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass; else fail "$1: wanted '$2', got '$3'"; fi
}

# count METHOD PATH-REGEX: how many such requests the fake saw.
count() {
  jq --arg m "$1" --arg p "$2" '[.[] | select(.method == $m and (.path | test($p)))] | length' "$log"
}
# req METHOD PATH-REGEX INDEX FILTER: a jq filter on one matching request
# (INDEX 0 is the first, -1 the last); empty string when there is none.
req() {
  jq -r --arg m "$1" --arg p "$2" --argjson i "$3" \
    "[.[] | select(.method == \$m and (.path | test(\$p)))] | .[\$i] // empty | $4" "$log"
}
requests_made() { jq 'length' "$log"; }
no_requests() { eq "requests made" 0 "$(requests_made)"; }

DEPLOYS='^/v1/apps/[^/]+/deployments$'

# The five origin headers a run from the default GitHub environment sends.
origin_sent() { # METHOD PATH-REGEX
  eq "origin commit" 0123456789abcdef0123456789abcdef01234567 "$(req "$1" "$2" -1 '.headers["caravana-origin-commit"]')"
  eq "origin ref" refs/heads/main "$(req "$1" "$2" -1 '.headers["caravana-origin-ref"]')"
  eq "origin actor" ana "$(req "$1" "$2" -1 '.headers["caravana-origin-actor"]')"
  eq "origin run" https://github.com/acme/web/actions/runs/212 "$(req "$1" "$2" -1 '.headers["caravana-origin-run"]')"
  eq "origin repository" acme/web "$(req "$1" "$2" -1 '.headers["caravana-origin-repository"]')"
}

# posted_body METHOD PATH-REGEX INDEX: the request body, normalised.
posted_json() { req "$1" "$2" "$3" '.body | fromjson' | jq -S -c .; }

# ================================================================= cases

echo "== deploying an image to a defined app"
run_case image-healthy '{"delay": 0.1}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "first line is the mask" "::add-mask::$TOKEN" "$(head -n 1 "$out")"
eq "app reads" 1 "$(count GET '^/v1/apps/web$')"
eq "deploys" 1 "$(count POST "$DEPLOYS")"
eq "deployment reads (running, healthy)" 2 "$(count GET '^/v1/apps/web/deployments/dep1$')"
eq "If-Match is the revision" "$REV" "$(req POST "$DEPLOYS" 0 '.headers["if-match"]')"
eq "content type" application/json "$(req POST "$DEPLOYS" 0 '.headers["content-type"]')"
eq "token reached the server as a bearer token" "Bearer $TOKEN" "$(req POST "$DEPLOYS" 0 '.headers.authorization')"
eq "body: image replaced, rest kept" \
  "$(jq -S -c --arg i "$IMG" '.services[0].image = $i' <<< '{"id":"web","source":{"kind":"image"},"services":[{"name":"web","image":"x","port":8080,"env":{"A":"1"}}]}')" \
  "$(posted_json POST "$DEPLOYS" 0)"
origin_sent POST "$DEPLOYS"
outputs_has app-id=web
outputs_has deployment-id=dep1
outputs_has job-version=7
outputs_has status=healthy
outputs_lack promotion-id
out_has "Healthy: job version 7"
summary_has '| Status | `healthy` |'
summary_has '| Deployment | `dep1` |'
summary_has '| Nomad job version | `7` |'
summary_has "| Image | \`web: $IMG\` |"
summary_has '| Commit | `0123456789ab` |'
# The sampler must have seen curl running, or "not on a command line" proves nothing.
if grep -q 'curl --silent' "$dir/ps"; then pass; else fail "the process sampler never saw curl"; fi

echo "== no outputs file, no summary file"
run_case no-github-files '{}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" GITHUB_OUTPUT= GITHUB_STEP_SUMMARY=
exit_is 0
if [ -e "$outputs" ] || [ -e "$summary" ]; then fail "files were written"; else pass; fi

echo "== the app ID"
id_case() { # NAME EXPECTED-ID VAR=value...
  local name="$1" want="$2"
  shift 2
  run_case "id-$name" '{}' CARAVANA_WAIT=false "$@"
  exit_is 0
  eq "app read path" 1 "$(count GET "^/v1/apps/$want\$")"
  outputs_has "app-id=$want"
}
id_case bare web CARAVANA_APP=web
id_case default-place web CARAVANA_PROJECT=default CARAVANA_ENVIRONMENT=production CARAVANA_NAME=web
id_case place labci--staging--web CARAVANA_PROJECT=labci CARAVANA_ENVIRONMENT=staging CARAVANA_NAME=web
id_case full labci--staging--web CARAVANA_APP=labci--staging--web
id_case default-staging default--staging--web CARAVANA_PROJECT=default CARAVANA_ENVIRONMENT=staging CARAVANA_NAME=web

echo "== inputs that are refused before any request"
bad_input() { # NAME TEXT VAR=value...
  local name="$1" text="$2"
  shift 2
  run_case "bad-$name" '{}' "$@"
  exit_is 1
  out_has "::error::"
  out_has "$text"
  no_requests
}
bad_input no-url "'url'" CARAVANA_URL= CARAVANA_APP=web
bad_input url-no-scheme "'url'" CARAVANA_URL=caravana.example.com CARAVANA_APP=web
bad_input no-token "'token'" CARAVANA_TOKEN= CARAVANA_APP=web
bad_input token-quote "'token'" 'CARAVANA_TOKEN=cvat_abc"def' CARAVANA_APP=web
bad_input token-space "'token'" 'CARAVANA_TOKEN=cvat_abc def' CARAVANA_APP=web
bad_input no-app "'project' is empty"
bad_input app-and-place "not both" CARAVANA_APP=web CARAVANA_PROJECT=shop
bad_input no-environment "'environment' is empty" CARAVANA_PROJECT=shop CARAVANA_NAME=web
bad_input no-name "'name' is empty" CARAVANA_PROJECT=shop CARAVANA_ENVIRONMENT=staging
bad_input app-uppercase "'app'" CARAVANA_APP=Web
bad_input app-two-parts "'app'" CARAVANA_APP=shop--web
bad_input app-four-parts "'app'" CARAVANA_APP=a--b--c--d
bad_input app-default-prod "bare name" CARAVANA_APP=default--production--web
bad_input name-double-dash "'name'" CARAVANA_PROJECT=shop CARAVANA_ENVIRONMENT=staging CARAVANA_NAME=we--b
bad_input project-uppercase "'project'" CARAVANA_PROJECT=Shop CARAVANA_ENVIRONMENT=staging CARAVANA_NAME=web
bad_input wait-value "'wait'" CARAVANA_APP=web CARAVANA_WAIT=maybe
bad_input timeout-word "'timeout'" CARAVANA_APP=web CARAVANA_TIMEOUT=soon
bad_input timeout-zero "'timeout'" CARAVANA_APP=web CARAVANA_TIMEOUT=0
bad_input fos-value "'fail-on-superseded'" CARAVANA_APP=web CARAVANA_FAIL_ON_SUPERSEDED=yes
bad_input promote-name "'promote'" CARAVANA_APP=web CARAVANA_PROMOTE=Prod
bad_input promote-no-wait "needs 'wait'" CARAVANA_APP=web CARAVANA_PROMOTE=production CARAVANA_WAIT=false
bad_input service-name "'service'" CARAVANA_APP=web CARAVANA_SERVICE=Bad_Name
bad_input definition-missing "'definition'" CARAVANA_APP=web "CARAVANA_DEFINITION=$tmp/nope.json"
bad_input definition-not-json "'definition'" CARAVANA_APP=web "CARAVANA_DEFINITION=$tmp/bad.json"

echo "== redeploy as stored"
run_case redeploy '{}' CARAVANA_APP=web
exit_is 0
eq "POST body is empty" "" "$(req POST "$DEPLOYS" 0 '.body')"
eq "no If-Match" "" "$(req POST "$DEPLOYS" 0 '.headers["if-match"] // ""')"
origin_sent POST "$DEPLOYS"
outputs_has status=healthy
outputs_has deployment-id=dep1
out_has "redeploying app 'web' as stored"
summary_has '| Image | `web: ghcr.io/acme/web:latest@sha256:'

run_case redeploy-ignores-definition '{}' CARAVANA_APP=web "CARAVANA_DEFINITION=$tmp/def.json"
exit_is 0
eq "POST body is empty" "" "$(req POST "$DEPLOYS" 0 '.body')"
out_has "'definition' is ignored"

echo "== the image replaces the stored one, not the definition file"
run_case image-and-definition-defined '{}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" "CARAVANA_DEFINITION=$tmp/def.json"
exit_is 0
eq "stored port kept" 8080 "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].port')"
eq "image set" "$IMG" "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].image')"
eq "If-Match sent" "$REV" "$(req POST "$DEPLOYS" 0 '.headers["if-match"]')"
out_has "'definition' is ignored"

echo "== define from a file"
run_case define-missing-app '{"app": null}' CARAVANA_APP=labci--staging--web "CARAVANA_DEFINITION=$tmp/def.json" "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "deploys" 1 "$(count POST '^/v1/apps/labci--staging--web/deployments$')"
eq "no If-Match" "" "$(req POST "$DEPLOYS" 0 '.headers["if-match"] // ""')"
eq "file's app, image replaced" \
  "$(jq -S -c --arg i "$IMG" '.services[0].image = $i' "$tmp/def.json")" \
  "$(posted_json POST "$DEPLOYS" 0)"
origin_sent POST "$DEPLOYS"
outputs_has status=healthy
out_has "defining it from"

run_case define-without-image '{"app": null}' CARAVANA_APP=web "CARAVANA_DEFINITION=$tmp/def.json"
exit_is 0
eq "file as it is" "$(jq -S -c . "$tmp/def.json")" "$(posted_json POST "$DEPLOYS" 0)"

run_case define-undefined-app '{"app": {"defined": false, "app": {"id": "web", "source": {"kind": "image"}, "services": []}}}' \
  CARAVANA_APP=web "CARAVANA_DEFINITION=$tmp/def.json" "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "deploys" 1 "$(count POST "$DEPLOYS")"
eq "image set" "$IMG" "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].image')"
eq "no If-Match" "" "$(req POST "$DEPLOYS" 0 '.headers["if-match"] // ""')"

echo "== no definition anywhere"
NODEF="has no definition: give 'definition' (or 'image' with a definition file)"
run_case nodef-missing-image '{"app": null}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::App 'web' $NODEF"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case nodef-missing-plain '{"app": null}' CARAVANA_APP=web
exit_is 1
out_has "$NODEF"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case nodef-undefined-image '{"app": {"defined": false, "app": {"id": "web", "source": {"kind": "image"}, "services": []}}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "$NODEF"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case nodef-undefined-plain '{"app": {"defined": false, "app": {"id": "web", "source": {"kind": "image"}, "services": []}}}' CARAVANA_APP=web
exit_is 1
out_has "$NODEF"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"

echo "== services"
run_case multi-no-service "$TWO_SERVICES" CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::App 'web' has 2 services (api, worker): give the input 'service'"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case multi-service "$TWO_SERVICES" CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" CARAVANA_SERVICE=worker
exit_is 0
eq "worker image set" "$IMG" "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[1].image')"
eq "api image kept" a/api:1 "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].image')"
eq "api port kept" 8080 "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].port')"
run_case multi-service-unknown "$TWO_SERVICES" CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" CARAVANA_SERVICE=nope
exit_is 1
out_has "The input 'service' ('nope') is not a service of app 'web' (it has: api, worker)."
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case single-service-named '{}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" CARAVANA_SERVICE=web
exit_is 0
eq "image set" "$IMG" "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].image')"
run_case define-multi-no-service '{"app": null}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" "CARAVANA_DEFINITION=$tmp/def2.json"
exit_is 1
out_has "give the input 'service'"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case define-multi-service '{"app": null}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" "CARAVANA_DEFINITION=$tmp/def2.json" CARAVANA_SERVICE=web
exit_is 0
eq "web image set" "$IMG" "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[0].image')"
eq "worker kept" a/worker:1 "$(req POST "$DEPLOYS" 0 '.body | fromjson | .services[1].image')"

echo "== the app changed under us (412)"
run_case stale-once '{"deploy": {"stale_once": 1}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "app read twice" 2 "$(count GET '^/v1/apps/web$')"
eq "deploy sent twice" 2 "$(count POST "$DEPLOYS")"
eq "first If-Match" "$REV" "$(req POST "$DEPLOYS" 0 '.headers["if-match"]')"
eq "second If-Match is the new revision" fedcba9876543210 "$(req POST "$DEPLOYS" 1 '.headers["if-match"]')"
out_has "reading it again and retrying once"
outputs_has status=healthy
run_case stale-always '{"deploy": {"always_stale": true}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
eq "deploy sent twice, no more" 2 "$(count POST "$DEPLOYS")"
out_has "::error::Caravana answered 412 deploying app 'web': app_changed:"

echo "== how a deploy ends"
run_case failed '{"deploy": {"final": "failed", "error": "health check never passed"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::The deploy ended 'failed': health check never passed"
outputs_has status=failed
outputs_has deployment-id=dep1
outputs_has job-version=7
summary_has '| Status | `failed` |'
summary_has "The deploy ended \`failed\`: health check never passed"
run_case reverted '{"deploy": {"final": "reverted", "error": "rolled back to version 6"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::The deploy ended 'reverted': rolled back to version 6"
outputs_has status=reverted
run_case superseded '{"deploy": {"final": "superseded", "error": "a newer deploy replaced it"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
out_has "::notice::The deployment dep1 was superseded"
outputs_has status=superseded
summary_has '| Status | `superseded` |'
run_case superseded-fail '{"deploy": {"final": "superseded", "error": "a newer deploy replaced it"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" CARAVANA_FAIL_ON_SUPERSEDED=true
exit_is 1
out_has "::error::The deployment dep1 was superseded by a newer deploy: a newer deploy replaced it"
outputs_has status=superseded
run_case superseded-at-once '{"deploy": {"initial": "superseded", "final": "superseded"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "no polling needed" 0 "$(count GET '/deployments/dep1$')"
outputs_has status=superseded
run_case warnings '{"deploy": {"warnings": [{"field": "services[0].secrets", "message": "secret DB_PASS is deleted\nbye"}, {"field": "", "message": "plain note"}]}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
out_has "::warning::services[0].secrets: secret DB_PASS is deleted bye"
out_has "::warning::plain note"
run_case warnings-on-failure '{"deploy": {"final": "failed", "error": "boom", "warnings": [{"field": "x", "message": "careful"}]}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::warning::x: careful"
run_case timeout '{"deploy": {"final": "never"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" CARAVANA_TIMEOUT=1
exit_is 1
out_has "::error::The deployment dep1 was still 'running' after 1 seconds; giving up waiting. Caravana goes on with it."
outputs_has status=running
outputs_has deployment-id=dep1
summary_has "still \`running\` after 1 seconds"
run_case wait-false '{}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG" CARAVANA_WAIT=false
exit_is 0
out_has "Deployment started: dep1"
eq "no polling" 0 "$(count GET '/deployments/dep1$')"
outputs_has deployment-id=dep1
outputs_has status=pending
outputs_has job-version=
summary_has '(not waited for)'
run_case transient-503 '{"deploy": {"transient_503": 2}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
out_has "::warning::Caravana answered 503 reading the deployment; trying again."
outputs_has status=healthy
run_case absolute-location '{"deploy": {"absolute_location": true}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "polled" 2 "$(count GET '^/v1/apps/web/deployments/dep1$')"

echo "== Caravana says no"
run_case wrong-token '{"token": "cvat_somethingelse"}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::Caravana answered 401 reading app 'web': check the input 'token'"
eq "stopped at the first request" 1 "$(requests_made)"
run_case scope '{"forbid": true}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "Caravana answered 403 reading app 'web': token_scope: this token can only deploy app web of project shop."
out_has "Check the input 'token'"
eq "stopped at the first request" 1 "$(requests_made)"
run_case unreachable '{}' CARAVANA_URL=http://127.0.0.1:1 CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::Could not reach http://127.0.0.1:1: check the input 'url'"
run_case plain-http-warning '{}' CARAVANA_URL=http://caravana.invalid:1 CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::warning::The input 'url' is plain http"
run_case stopped '{"app": {"stoppedAt": "2026-10-18T09:00:00Z"}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::The app is stopped: start it first"
eq "no deploy" 0 "$(count POST "$DEPLOYS")"
run_case stopped-409 '{"deploy": {"post_error": {"status": 409, "error": {"code": "app_stopped", "message": "app web is stopped"}}}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::The app is stopped: start it first (Caravana said app_stopped: app web is stopped)"
run_case image-not-found '{"deploy": {"post_error": {"status": 422, "error": {"code": "image_not_found", "message": "no such tag", "field": "services[0].image"}}}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "::error::Caravana answered 422 deploying app 'web': image_not_found: no such tag (services[0].image)"
run_case server-error '{"deploy": {"post_error": {"status": 500, "raw": "kaboom from a proxy"}}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "Caravana answered 500 deploying app 'web': kaboom from a proxy"
run_case deploy-403 '{"deploy": {"post_error": {"status": 403, "error": {"code": "token_scope", "message": "out of scope"}}}}' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 1
out_has "token_scope: out of scope"
out_has "Check the input 'token'"

echo "== promote"
PROMO_ENV=(CARAVANA_APP=shop--staging--web "CARAVANA_IMAGE=$IMG" CARAVANA_PROMOTE=production)
SHOP_APP='{"app": {"app": {"id": "shop--staging--web", "source": {"kind": "image"}, "services": [{"name": "web", "image": "a/web:1"}]}}}'
run_case promote-healthy "$(jq -c -s '.[0] * {"delay": 0.1}' <<< "$SHOP_APP")" "${PROMO_ENV[@]}"
exit_is 0
eq "promote requests" 1 "$(count POST '^/v1/apps/shop--staging--web/promote$')"
eq "promote body" '{"to":"production"}' "$(posted_json POST '/promote$' 0)"
eq "promote content type" application/json "$(req POST '/promote$' 0 '.headers["content-type"]')"
eq "promote has no If-Match" "" "$(req POST '/promote$' 0 '.headers["if-match"] // ""')"
origin_sent POST '/promote$'
eq "promotion polled on the target" 2 "$(count GET '^/v1/apps/shop--production--web/deployments/prom1$')"
eq "promote came after the deploy was healthy" 2 "$(count GET '^/v1/apps/shop--staging--web/deployments/dep1$')"
outputs_has app-id=shop--staging--web
outputs_has deployment-id=dep1
outputs_has status=healthy
outputs_has promotion-id=prom1
outputs_has promotion-status=healthy
out_has "Promotion healthy: job version 7"
summary_has '| Promotion to production | `healthy` |'
summary_has '| Promotion deployment | `prom1` |'
summary_has '| Promoted app | `shop--production--web` |'
echo "== promote only (no image, no definition: nothing is deployed first)"
ONLY_ENV=(CARAVANA_APP=shop--staging--web CARAVANA_PROMOTE=production)
run_case promote-only "$SHOP_APP" "${ONLY_ENV[@]}"
exit_is 0
eq "no deploy request" 0 "$(count POST '/deployments$')"
eq "the app was read" 1 "$(count GET '^/v1/apps/shop--staging--web$')"
eq "no source deployment read" 0 "$(count GET '^/v1/apps/shop--staging--web/deployments/')"
eq "promoted" 1 "$(count POST '^/v1/apps/shop--staging--web/promote$')"
eq "promote body" '{"to":"production"}' "$(posted_json POST '/promote$' 0)"
origin_sent POST '/promote$'
eq "promotion polled until healthy" 2 "$(count GET '^/v1/apps/shop--production--web/deployments/prom1$')"
outputs_has app-id=shop--staging--web
outputs_has promotion-id=prom1
outputs_has promotion-status=healthy
outputs_lack deployment-id
outputs_lack status
outputs_lack job-version
out_has "Promotion healthy: job version 7"
summary_has "Promoted the newest healthy deployment of shop--staging--web to production."
summary_has '| Promotion to production | `healthy` |'
run_case promote-only-bare '{}' CARAVANA_APP=web CARAVANA_PROMOTE=production
exit_is 0
eq "no deploy request" 0 "$(count POST '/deployments$')"
eq "promoted" 1 "$(count POST '^/v1/apps/web/promote$')"
promote_only_refused() { # NAME STATUS CODE MESSAGE
  run_case "promote-only-$1" "{\"promote\": {\"post_error\": {\"status\": $2, \"error\": {\"code\": \"$3\", \"message\": \"$4\"}}}}" "${ONLY_ENV[@]}"
  exit_is 1
  eq "no deploy request" 0 "$(count POST '/deployments$')"
  out_has "::error::Caravana answered $2 promoting app 'shop--staging--web' to 'production': $3: $4"
  outputs_lack promotion-id
  outputs_lack status
}
promote_only_refused not-healthy 409 deployment_not_healthy "the newest deployment is failed"
promote_only_refused no-definition 409 definition_not_recorded "the deployment has no recorded definition"
promote_only_refused not-in-env 404 app_not_in_environment "no app web in environment production"
run_case promote-only-failed '{"promote": {"final": "failed", "error": "target unhealthy"}}' "${ONLY_ENV[@]}"
exit_is 1
eq "no deploy request" 0 "$(count POST '/deployments$')"
out_has "::error::The promotion ended 'failed': target unhealthy"
outputs_has promotion-status=failed
run_case promote-only-timeout '{"promote": {"final": "never"}}' "${ONLY_ENV[@]}" CARAVANA_TIMEOUT=1
exit_is 1
out_has "The promotion prom1 was still 'running' after 1 seconds"
outputs_has promotion-status=running
run_case promote-only-superseded '{"promote": {"final": "superseded", "error": "replaced"}}' "${ONLY_ENV[@]}"
exit_is 0
outputs_has promotion-status=superseded
run_case promote-only-stopped '{"app": {"stoppedAt": "2026-10-18T09:00:00Z"}}' "${ONLY_ENV[@]}"
exit_is 1
out_has "::error::The app is stopped: start it first"
eq "no promote request" 0 "$(count POST '/promote$')"
run_case promote-only-no-app '{"app": null}' "${ONLY_ENV[@]}"
exit_is 1
out_has "::error::App 'shop--staging--web' does not exist: there is nothing to promote."
eq "no promote request" 0 "$(count POST '/promote$')"
run_case promote-only-401 '{"token": "cvat_other"}' "${ONLY_ENV[@]}"
exit_is 1
out_has "check the input 'token'"
run_case promote-definition-deploys-first '{}' "${ONLY_ENV[@]}" "CARAVANA_DEFINITION=$tmp/def.json"
exit_is 0
eq "a definition means a deploy first" 1 "$(count POST '/deployments$')"
eq "then promoted" 1 "$(count POST '/promote$')"
run_case promote-after-failed '{"deploy": {"final": "failed", "error": "nope"}}' "${PROMO_ENV[@]}"
exit_is 1
eq "no promote request" 0 "$(count POST '/promote$')"
outputs_lack promotion-id
run_case promote-refused '{"promote": {"post_error": {"status": 409, "error": {"code": "promotion_removes_service", "message": "the target has a service the source lacks", "field": "services.db"}}}}' "${PROMO_ENV[@]}"
exit_is 1
out_has "::error::Caravana answered 409 promoting app 'shop--staging--web' to 'production': promotion_removes_service: the target has a service the source lacks (services.db)"
outputs_has status=healthy
outputs_lack promotion-id
summary_has "Promoting to \`production\` was refused (409)"
run_case promote-failed '{"promote": {"final": "failed", "error": "target unhealthy"}}' "${PROMO_ENV[@]}"
exit_is 1
out_has "::error::The promotion ended 'failed': target unhealthy"
outputs_has promotion-id=prom1
outputs_has promotion-status=failed
outputs_has status=healthy
summary_has "The promotion to \`production\` ended \`failed\`: target unhealthy"
run_case promote-timeout '{"promote": {"final": "never"}}' "${PROMO_ENV[@]}" CARAVANA_TIMEOUT=1
exit_is 1
out_has "The promotion prom1 was still 'running' after 1 seconds"
outputs_has promotion-status=running
run_case promote-superseded '{"promote": {"final": "superseded", "error": "replaced"}}' "${PROMO_ENV[@]}"
exit_is 0
outputs_has promotion-status=superseded
out_has "::notice::The promotion prom1 was superseded"
run_case promote-superseded-fail '{"promote": {"final": "superseded", "error": "replaced"}}' "${PROMO_ENV[@]}" CARAVANA_FAIL_ON_SUPERSEDED=true
exit_is 1
run_case promote-after-superseded '{"deploy": {"final": "superseded", "error": "replaced"}}' "${PROMO_ENV[@]}"
exit_is 0
eq "no promote request" 0 "$(count POST '/promote$')"
out_has "::warning::Not promoting to 'production': this deployment was superseded."
run_case promote-403 '{"promote": {"post_error": {"status": 403, "error": {"code": "token_scope", "message": "out of scope"}}}}' "${PROMO_ENV[@]}"
exit_is 1
out_has "Check the input 'token'"

echo "== origin headers"
no_origin() { # METHOD PATH-REGEX HEADER
  eq "no $3" "" "$(req "$1" "$2" 0 ".headers[\"$3\"] // \"\"")"
}
run_case origin-none '{}' CARAVANA_APP=web GITHUB_SHA= GITHUB_REF= GITHUB_ACTOR= GITHUB_SERVER_URL= GITHUB_REPOSITORY= GITHUB_RUN_ID=
exit_is 0
for h in commit ref actor run repository; do no_origin POST "$DEPLOYS" "caravana-origin-$h"; done
run_case origin-bad-sha '{}' CARAVANA_APP=web GITHUB_SHA=xyz
exit_is 0
no_origin POST "$DEPLOYS" caravana-origin-commit
eq "ref still sent" refs/heads/main "$(req POST "$DEPLOYS" 0 '.headers["caravana-origin-ref"]')"
run_case origin-short-sha '{}' CARAVANA_APP=web GITHUB_SHA=abc1234
exit_is 0
eq "7 hex digits is enough" abc1234 "$(req POST "$DEPLOYS" 0 '.headers["caravana-origin-commit"]')"
run_case origin-long-ref '{}' CARAVANA_APP=web "GITHUB_REF=$(printf 'a%.0s' $(seq 1 300))"
exit_is 0
eq "ref cut to 255" 255 "$(req POST "$DEPLOYS" 0 '.headers["caravana-origin-ref"] | length')"
run_case origin-unprintable '{}' CARAVANA_APP=web "GITHUB_REF=$(printf 'x\ty')"
exit_is 0
eq "tab removed" xy "$(req POST "$DEPLOYS" 0 '.headers["caravana-origin-ref"]')"
run_case origin-http-server '{}' CARAVANA_APP=web GITHUB_SERVER_URL=http://ghe.local
exit_is 0
no_origin POST "$DEPLOYS" caravana-origin-run
run_case origin-no-run-id '{}' CARAVANA_APP=web GITHUB_RUN_ID=
exit_is 0
no_origin POST "$DEPLOYS" caravana-origin-run
eq "commit still sent" 0123456789abcdef0123456789abcdef01234567 "$(req POST "$DEPLOYS" 0 '.headers["caravana-origin-commit"]')"
run_case origin-ghes '{}' CARAVANA_APP=web GITHUB_SERVER_URL=https://git.example.com/ GITHUB_RUN_ID=9
exit_is 0
eq "run URL from the server URL" https://git.example.com/acme/web/actions/runs/9 "$(req POST "$DEPLOYS" 0 '.headers["caravana-origin-run"]')"

echo "== the token in the log"
# A token no real run would have, to prove masking and stdin are not luck of
# the default: characters a Caravana token can contain, shell-hostile ones too.
run_case odd-token '{"token": "cvat_a+b/c=d.e~f-g_h"}' 'CARAVANA_TOKEN=cvat_a+b/c=d.e~f-g_h' CARAVANA_APP=web "CARAVANA_IMAGE=$IMG"
exit_is 0
eq "token sent intact" "Bearer cvat_a+b/c=d.e~f-g_h" "$(req POST "$DEPLOYS" 0 '.headers.authorization')"
eq "first line is the mask" "::add-mask::cvat_a+b/c=d.e~f-g_h" "$(head -n 1 "$out")"

echo
if [ "$failures" -eq 0 ]; then
  echo "All $checks checks passed."
else
  echo "$failures of $checks checks failed."
  exit 1
fi

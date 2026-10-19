#!/usr/bin/env bash
# Deploy an app to Caravana, wait for the rollout, and optionally promote it.
#
# This is the script behind the caravana-action GitHub Action (see action.yml
# and README.md). It talks only to Caravana's public HTTP API, with curl and
# jq, so other CI systems can call it too.
#
# Inputs, all environment variables:
#   CARAVANA_URL          console address, e.g. https://caravana.example.com (required)
#   CARAVANA_TOKEN        an API token or deploy token, cvat_... (required)
#   CARAVANA_APP          the app ID, OR
#   CARAVANA_PROJECT, CARAVANA_ENVIRONMENT, CARAVANA_NAME   its place
#   CARAVANA_IMAGE        the image to deploy, e.g. ghcr.io/owner/app@sha256:...
#   CARAVANA_SERVICE      which service gets the image (needed with several)
#   CARAVANA_DEFINITION   path to a JSON file with an App, to define the app
#   CARAVANA_WAIT         "true" (default) waits for the rollout; "false" does not
#   CARAVANA_TIMEOUT      seconds to wait (default 600)
#   CARAVANA_PROMOTE      an environment to promote to once healthy
#   CARAVANA_FAIL_ON_SUPERSEDED  "true" fails the step when a newer deploy won
#   CARAVANA_POLL_SECONDS seconds between reads of a rollout (default 5)
# From GitHub Actions, when set: GITHUB_SHA, GITHUB_REF, GITHUB_ACTOR,
# GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID (sent as origin headers),
# GITHUB_OUTPUT and GITHUB_STEP_SUMMARY (outputs and the job summary).
#
# The token goes to curl on stdin as a config line, never as an argument, and
# is never printed.
set -euo pipefail

# ---------------------------------------------------------------- messages

# A workflow command must stay on one line, and Caravana's text could hold
# line breaks.
oneline() { printf '%s' "$1" | tr '\r\n' '  '; }
error()   { echo "::error::$(oneline "$1")"; }
warning() { echo "::warning::$(oneline "$1")"; }
notice()  { echo "::notice::$(oneline "$1")"; }
die()     { error "$1"; exit 1; }

# ------------------------------------------------------------------ inputs

for tool in curl jq; do
  command -v "$tool" > /dev/null 2>&1 || die "$tool is not installed on this runner; the action needs curl and jq."
done

URL="${CARAVANA_URL:-}"
TOKEN="${CARAVANA_TOKEN:-}"
APP_INPUT="${CARAVANA_APP:-}"
PROJECT="${CARAVANA_PROJECT:-}"
ENVIRONMENT="${CARAVANA_ENVIRONMENT:-}"
NAME="${CARAVANA_NAME:-}"
IMAGE="${CARAVANA_IMAGE:-}"
SERVICE="${CARAVANA_SERVICE:-}"
DEFINITION="${CARAVANA_DEFINITION:-}"
WAIT="${CARAVANA_WAIT:-true}"
TIMEOUT="${CARAVANA_TIMEOUT:-600}"
PROMOTE="${CARAVANA_PROMOTE:-}"
FAIL_ON_SUPERSEDED="${CARAVANA_FAIL_ON_SUPERSEDED:-false}"
POLL_SECONDS="${CARAVANA_POLL_SECONDS:-5}"

# Masking comes first: from here on the token may not appear anywhere.
if [ -n "$TOKEN" ]; then
  echo "::add-mask::$TOKEN"
fi

[ -n "$URL" ]   || die "The input 'url' is empty: give your Caravana address, for example https://caravana.example.com."
[ -n "$TOKEN" ] || die "The input 'token' is empty: give an API token or a deploy token (store it as a repository secret)."

# The token is written into a curl config line, so a character that could end
# the line or the quoted string is refused (a real token never has one). The
# message does not repeat the token.
if ! printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9._~+/=-]+$'; then
  die "The input 'token' has characters a Caravana token never has (check for quotes, spaces or line breaks)."
fi

case "$URL" in
  https://*) ;;
  http://127.0.0.1|http://127.0.0.1[:/]*|http://localhost|http://localhost[:/]*|http://\[::1\]*) ;;
  http://*) warning "The input 'url' is plain http: the token travels unencrypted. Use https." ;;
  *) die "The input 'url' must start with https:// (got '$URL')." ;;
esac
base="${URL%/}"

case "$WAIT" in true|false) ;; *) die "The input 'wait' must be 'true' or 'false' (got '$WAIT')." ;; esac
case "$FAIL_ON_SUPERSEDED" in true|false) ;; *) die "The input 'fail-on-superseded' must be 'true' or 'false' (got '$FAIL_ON_SUPERSEDED')." ;; esac
case "$TIMEOUT" in
  ''|*[!0-9]*|0) die "The input 'timeout' must be a whole number of seconds above 0 (got '$TIMEOUT')." ;;
esac

LABEL_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

# valid_name INPUT VALUE: a lowercase DNS label that does not contain "--".
valid_name() {
  if ! printf '%s' "$2" | grep -Eq "$LABEL_RE" || [ "${2#*--}" != "$2" ]; then
    die "The input '$1' ('$2') must be a lowercase name: a-z, 0-9 and '-', at most 63 characters, no '--'."
  fi
}

# The app ID: the bare name in project "default", environment "production";
# otherwise <project>--<environment>--<name>. This is Caravana's rule.
if [ -n "$APP_INPUT" ]; then
  if [ -n "$PROJECT$ENVIRONMENT$NAME" ]; then
    die "Give the input 'app', or 'project' with 'environment' and 'name', not both."
  fi
  APP_ID="$APP_INPUT"
  if [ "${APP_ID#*--}" = "$APP_ID" ]; then
    valid_name app "$APP_ID"
  else
    rest="${APP_ID#*--}"
    p="${APP_ID%%--*}"
    e="${rest%%--*}"
    n="${rest#*--}"
    if [ "${rest#*--}" = "$rest" ] || [ "${n#*--}" != "$n" ]; then
      die "The input 'app' ('$APP_ID') must be a name, or <project>--<environment>--<name>."
    fi
    valid_name app-project "$p"
    valid_name app-environment "$e"
    valid_name app-name "$n"
    if [ "$p" = default ] && [ "$e" = production ]; then
      die "The input 'app' ('$APP_ID') should be written '$n' (the bare name) for project default, environment production."
    fi
  fi
else
  [ -n "$PROJECT" ]     || die "Give the input 'app', or all of 'project', 'environment' and 'name' ('project' is empty)."
  [ -n "$ENVIRONMENT" ] || die "Give the input 'app', or all of 'project', 'environment' and 'name' ('environment' is empty)."
  [ -n "$NAME" ]        || die "Give the input 'app', or all of 'project', 'environment' and 'name' ('name' is empty)."
  valid_name project "$PROJECT"
  valid_name environment "$ENVIRONMENT"
  valid_name name "$NAME"
  if [ "$PROJECT" = default ] && [ "$ENVIRONMENT" = production ]; then
    APP_ID="$NAME"
  else
    APP_ID="$PROJECT--$ENVIRONMENT--$NAME"
  fi
fi

if [ -n "$SERVICE" ]; then valid_name service "$SERVICE"; fi
if [ -n "$PROMOTE" ]; then
  valid_name promote "$PROMOTE"
  [ "$WAIT" = true ] || die "The input 'promote' needs 'wait' to be true: a promotion starts from a healthy deployment."
fi
if [ -n "$DEFINITION" ]; then
  [ -f "$DEFINITION" ] || die "The input 'definition' ('$DEFINITION') is not a file."
  jq -e 'type == "object"' "$DEFINITION" > /dev/null 2>&1 ||
    die "The input 'definition' ('$DEFINITION') is not a JSON file holding an app: {\"source\":{\"kind\":\"image\"},\"services\":[...]}."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
body="$work/body"
headers="$work/headers"

# ----------------------------------------------------------------- outputs

# set_output NAME VALUE, when the runner gave us a file for it.
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$(oneline "$2")" >> "$GITHUB_OUTPUT"
  fi
}

set_output app-id "$APP_ID"

# --------------------------------------------------------------- origin

# The origin headers say where the deploy came from. Each is sent only when
# its source is set and fits Caravana's rule for it (a header that breaks a
# rule would be refused, and an origin is never worth a failed deploy).
origin_args=()

# printable VALUE MAX: the printable ASCII part of VALUE, cut to MAX.
printable() { printf '%s' "$1" | LC_ALL=C tr -cd '[:print:]' | cut -c "1-$2"; }

add_origin() {
  if [ -n "$2" ]; then origin_args+=(-H "$1: $2"); fi
}

sha="${GITHUB_SHA:-}"
if printf '%s' "$sha" | grep -Eq '^[0-9a-fA-F]{7,64}$'; then add_origin Caravana-Origin-Commit "$sha"; fi
add_origin Caravana-Origin-Ref "$(printable "${GITHUB_REF:-}" 255)"
add_origin Caravana-Origin-Actor "$(printable "${GITHUB_ACTOR:-}" 100)"
add_origin Caravana-Origin-Repository "$(printable "${GITHUB_REPOSITORY:-}" 200)"
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="$(printable "${GITHUB_SERVER_URL%/}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" 500)"
  case "$run_url" in https://*) add_origin Caravana-Origin-Run "$run_url" ;; esac
fi

# -------------------------------------------------------------- the calls

HTTP_CODE=""

# call METHOD PATH [curl args...]: one request. Leaves the status in
# HTTP_CODE, the answer in $body and the answer's headers in $headers. The
# token goes to curl on stdin as a config line, not as an argument, so it is in
# no process list. A request that gets no answer at all ends the script.
call() {
  local method="$1" path="$2"
  shift 2
  : > "$body"
  : > "$headers"
  if ! HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl --silent --show-error --max-time 60 --config - \
      -X "$method" -o "$body" -D "$headers" -w '%{http_code}' "$@" "$base$path" 2> "$work/curl.err")"; then
    HTTP_CODE="000"
  fi
}

# call_or_die behaves as call and ends the script when nothing answered.
call_or_die() {
  call "$@"
  if [ "$HTTP_CODE" = "000" ]; then
    die "Could not reach $base: check the input 'url' ($(head -c 200 "$work/curl.err"))."
  fi
}

# describe_error: "code: message" from Caravana's error body, or the start of
# the body when it is something else (a proxy's page, say).
describe_error() {
  jq -er 'select(.error) | .error | "\(.code): \(.message)" + (if (.field // "") != "" then " (" + .field + ")" else "" end)' \
    "$body" 2> /dev/null || head -c 300 "$body" | tr '\r\n' '  '
}

error_code() { jq -r '.error.code // ""' "$body" 2> /dev/null || true; }

# fail_http WHAT: the call just made answered something we can't go on from.
fail_http() {
  case "$HTTP_CODE" in
    401) die "Caravana answered 401 $1: check the input 'token' (is it revoked, expired or for another host?)." ;;
    403) die "Caravana answered 403 $1: $(describe_error). Check the input 'token': a deploy token works only for its own app." ;;
    *)
      if [ "$(error_code)" = app_stopped ]; then
        die "The app is stopped: start it first (Caravana said $(describe_error))."
      fi
      die "Caravana answered $HTTP_CODE $1: $(describe_error)"
      ;;
  esac
}

# location_of: the Location header's path, or empty.
location_of() {
  tr -d '\r' < "$headers" | awk 'tolower($1) == "location:" { print $2 }' | tail -n 1
}

# --------------------------------------------------------- read the app

echo "Deploying app '$APP_ID' on $base"

app_defined=false
revision=""
record="$work/record.json"

read_app() {
  call_or_die GET "/v1/apps/$APP_ID"
  case "$HTTP_CODE" in
    200)
      cp "$body" "$record"
      app_defined="$(jq -r '.defined' "$record")"
      revision="$(jq -r '.revision // ""' "$record")"
      if [ "$(jq -r '.stoppedAt // ""' "$record")" != "" ]; then
        die "The app is stopped: start it first (in Caravana's console, or with startApp), then run the step again."
      fi
      ;;
    404)
      app_defined=false
      revision=""
      ;;
    *) fail_http "reading app '$APP_ID'" ;;
  esac
}

read_app

# set_image FILE: FILE holds an App; its one service (or the one
# named by the 'service' input) gets the image from the 'image' input.
set_image() {
  local file="$1" count target
  count="$(jq '(.services // []) | length' "$file")"
  if [ "$count" -eq 0 ]; then
    die "The app has no services to put the image '$IMAGE' on: check the input 'definition'."
  fi
  if [ -n "$SERVICE" ]; then
    if [ "$(jq --arg s "$SERVICE" '[.services[] | select(.name == $s)] | length' "$file")" -eq 0 ]; then
      die "The input 'service' ('$SERVICE') is not a service of app '$APP_ID' (it has: $(jq -r '[.services[].name] | join(", ")' "$file"))."
    fi
    target="$SERVICE"
  elif [ "$count" -gt 1 ]; then
    die "App '$APP_ID' has $count services ($(jq -r '[.services[].name] | join(", ")' "$file")): give the input 'service' to say which gets the image."
  else
    target="$(jq -r '.services[0].name' "$file")"
  fi
  jq --arg s "$target" --arg image "$IMAGE" \
    '.services |= map(if .name == $s then .image = $image else . end)' "$file" > "$file.new"
  mv "$file.new" "$file"
}

# ----------------------------------------------------------- the deploy

payload="$work/payload.json"
mode=""            # replace-image | define | redeploy
if [ -n "$IMAGE" ] && [ "$app_defined" = true ]; then
  mode=replace-image
  if [ -n "$DEFINITION" ]; then
    notice "The input 'definition' is ignored: app '$APP_ID' is already defined, so the image goes into the stored app."
  fi
elif [ -n "$DEFINITION" ] && [ "$app_defined" != true ]; then
  mode=define
elif [ -n "$IMAGE" ]; then
  die "App '$APP_ID' has no definition: give 'definition' (or 'image' with a definition file)."
elif [ "$app_defined" = true ]; then
  mode=redeploy
  if [ -n "$DEFINITION" ]; then
    notice "The input 'definition' is ignored: app '$APP_ID' is already defined, so it is redeployed as stored."
  fi
else
  die "App '$APP_ID' has no definition: give 'definition' (or 'image' with a definition file)."
fi

# build_payload makes $payload for the mode, from the app as just read.
build_payload() {
  case "$mode" in
    replace-image)
      jq '.app' "$record" > "$payload"
      set_image "$payload"
      ;;
    define)
      cp "$DEFINITION" "$payload"
      if [ -n "$IMAGE" ]; then set_image "$payload"; fi
      ;;
  esac
}

# send_deploy POSTs the payload (or an empty body) and leaves the answer in
# HTTP_CODE, $body and $headers.
send_deploy() {
  local path="/v1/apps/$APP_ID/deployments"
  case "$mode" in
    replace-image)
      call_or_die POST "$path" -H 'Content-Type: application/json' -H "If-Match: $revision" \
        ${origin_args[@]+"${origin_args[@]}"} --data-binary "@$payload"
      ;;
    define)
      call_or_die POST "$path" -H 'Content-Type: application/json' \
        ${origin_args[@]+"${origin_args[@]}"} --data-binary "@$payload"
      ;;
    redeploy)
      call_or_die POST "$path" -H 'Content-Type: application/json' \
        ${origin_args[@]+"${origin_args[@]}"} --data-binary ''
      ;;
  esac
}

build_payload
case "$mode" in
  replace-image) echo "Deploying image $IMAGE (the app's other settings stay as stored)." ;;
  define)        echo "App '$APP_ID' has no definition yet; defining it from $DEFINITION." ;;
  redeploy)      echo "No image given: redeploying app '$APP_ID' as stored (tags are looked up again)." ;;
esac

send_deploy
if [ "$HTTP_CODE" = 412 ] && [ "$(error_code)" = app_changed ] && [ "$mode" = replace-image ]; then
  echo "The app changed since it was read; reading it again and retrying once."
  read_app
  if [ "$app_defined" != true ]; then
    die "App '$APP_ID' has no definition any more: give 'definition' (or 'image' with a definition file)."
  fi
  build_payload
  send_deploy
fi
[ "$HTTP_CODE" = 202 ] || fail_http "deploying app '$APP_ID'"

# --------------------------------------------------------- follow it

# Warnings count on success too (a dropped secret, a changed meaning).
print_warnings() {
  jq -r '.warnings[]? | "::warning::" + (((.field // "") | if . == "" then "" else . + ": " end) + .message | gsub("[\r\n]+"; " "))' "$body"
}

# track reads the 202 answer in $body and $headers and sets deploy_id,
# deploy_url (a path on the same host as the url input) and deploy_status.
deploy_id=""
deploy_url=""
deploy_status=""
track() {
  deploy_id="$(jq -r '.id // ""' "$body")"
  deploy_status="$(jq -r '.status // ""' "$body")"
  deploy_url="$(location_of)"
  case "$deploy_url" in
    http://*|https://*) deploy_url="/${deploy_url#*://*/}" ;;
  esac
  if [ -z "$deploy_id" ] && [ -n "$deploy_url" ]; then deploy_id="${deploy_url##*/}"; fi
  [ -n "$deploy_id" ] || die "Caravana answered 202 without a deployment ID."
  if [ -z "$deploy_url" ]; then deploy_url="/v1/apps/$APP_ID/deployments/$deploy_id"; fi
}

is_final() {
  case "$1" in healthy|failed|reverted|superseded) return 0 ;; esac
  return 1
}

# wait_final: polls deploy_url until its status is final or the deadline
# passes. The final answer is left in $body. Returns 1 on a timeout.
wait_final() {
  local deadline=$((SECONDS + TIMEOUT)) last="" got
  if is_final "$deploy_status"; then return 0; fi
  while :; do
    call GET "$deploy_url"
    got="$HTTP_CODE"
    case "$got" in
      200)
        deploy_status="$(jq -r '.status' "$body")"
        if [ "$deploy_status" != "$last" ]; then echo "Status: $deploy_status"; last="$deploy_status"; fi
        if is_final "$deploy_status"; then return 0; fi
        ;;
      000) warning "Could not read the deployment; trying again." ;;
      5??) warning "Caravana answered $got reading the deployment; trying again." ;;
      *) fail_http "reading deployment $deploy_id" ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then return 1; fi
    sleep "$POLL_SECONDS"
  done
}

describe_wait() {
  if [ $((TIMEOUT % 60)) -eq 0 ]; then echo "$((TIMEOUT / 60)) minutes"; else echo "$TIMEOUT seconds"; fi
}

# ------------------------------------------------------------- summary

summary_lines=()
summary_note=""
add_summary() { summary_lines+=("$1"); }

write_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "### Caravana"
    echo
    echo "| | |"
    echo "| --- | --- |"
    for line in ${summary_lines[@]+"${summary_lines[@]}"}; do echo "$line"; done
    if [ -n "$summary_note" ]; then echo; echo "$summary_note"; fi
  } >> "$GITHUB_STEP_SUMMARY"
}

# A step that ends in a hurry still leaves its summary.
exit_with_summary() { write_summary; exit "$1"; }

# digests_of: the answer's pinned images, one per line.
digests_of() { jq -r '(.digests // {}) | to_entries[] | "\(.key): \(.value)"' "$body" 2> /dev/null || true; }

summary_digests() {
  local d
  while IFS= read -r d; do
    if [ -n "$d" ]; then add_summary "| Image | \`$d\` |"; fi
  done < <(digests_of)
}

origin_summary() {
  if [ -n "${GITHUB_SHA:-}" ]; then add_summary "| Commit | \`$(printable "${GITHUB_SHA:0:12}" 12)\` |"; fi
}

# --------------------------------------------------------- first deploy

track
set_output deployment-id "$deploy_id"
echo "Deployment started: $deploy_id"

if [ "$WAIT" = false ]; then
  set_output status "$deploy_status"
  set_output job-version "$(jq -r '.jobVersion // ""' "$body")"
  echo "Not waiting (wait is false). Follow it at $base$deploy_url"
  add_summary "| Status | \`$deploy_status\` (not waited for) |"
  add_summary "| Deployment | \`$deploy_id\` |"
  add_summary "| App | \`$APP_ID\` |"
  write_summary
  exit 0
fi

echo "Waiting for the rollout (up to $(describe_wait))."
if ! wait_final; then
  set_output status "$deploy_status"
  error "The deployment $deploy_id was still '$deploy_status' after $(describe_wait); giving up waiting. Caravana goes on with it."
  add_summary "| Status | \`$deploy_status\` |"
  add_summary "| Deployment | \`$deploy_id\` |"
  summary_note="The deployment was still \`$deploy_status\` after $(describe_wait). Caravana goes on with it."
  exit_with_summary 1
fi

set_output status "$deploy_status"
set_output job-version "$(jq -r '.jobVersion // ""' "$body")"
print_warnings
add_summary "| App | \`$APP_ID\` |"
add_summary "| Status | \`$deploy_status\` |"
add_summary "| Deployment | \`$deploy_id\` |"
add_summary "| Nomad job version | \`$(jq -r '.jobVersion // "unknown"' "$body")\` |"
summary_digests
origin_summary
reason="$(jq -r '.error // ""' "$body")"

case "$deploy_status" in
  healthy) echo "Healthy: job version $(jq -r '.jobVersion // "unknown"' "$body")" ;;
  superseded)
    if [ "$FAIL_ON_SUPERSEDED" = true ]; then
      error "The deployment $deploy_id was superseded by a newer deploy: ${reason:-no reason given}"
      summary_note="The deployment was superseded by a newer deploy: ${reason:-no reason given}"
      exit_with_summary 1
    fi
    notice "The deployment $deploy_id was superseded by a newer deploy; that one is what runs. (fail-on-superseded is false.)"
    if [ -n "$PROMOTE" ]; then
      warning "Not promoting to '$PROMOTE': this deployment was superseded."
    fi
    exit_with_summary 0
    ;;
  *)
    error "The deploy ended '$deploy_status': ${reason:-no reason given}"
    summary_note="The deploy ended \`$deploy_status\`: ${reason:-no reason given}"
    exit_with_summary 1
    ;;
esac

# ------------------------------------------------------------- promote

if [ -n "$PROMOTE" ]; then
  echo "Promoting app '$APP_ID' to environment '$PROMOTE'."
  call_or_die POST "/v1/apps/$APP_ID/promote" -H 'Content-Type: application/json' \
    ${origin_args[@]+"${origin_args[@]}"} --data "$(jq -nc --arg to "$PROMOTE" '{to: $to}')"
  if [ "$HTTP_CODE" != 202 ]; then
    summary_note="Promoting to \`$PROMOTE\` was refused ($HTTP_CODE): $(describe_error)"
    write_summary
    fail_http "promoting app '$APP_ID' to '$PROMOTE'"
  fi
  track
  set_output promotion-id "$deploy_id"
  echo "Promotion started: deployment $deploy_id"
  if ! wait_final; then
    set_output promotion-status "$deploy_status"
    error "The promotion $deploy_id was still '$deploy_status' after $(describe_wait); giving up waiting. Caravana goes on with it."
    add_summary "| Promotion to $PROMOTE | \`$deploy_status\` |"
    add_summary "| Promotion deployment | \`$deploy_id\` |"
    summary_note="The promotion was still \`$deploy_status\` after $(describe_wait). Caravana goes on with it."
    exit_with_summary 1
  fi
  set_output promotion-status "$deploy_status"
  print_warnings
  add_summary "| Promotion to $PROMOTE | \`$deploy_status\` |"
  add_summary "| Promotion deployment | \`$deploy_id\` |"
  add_summary "| Promoted app | \`$(jq -r '.appId // ""' "$body")\` |"
  add_summary "| Promotion Nomad job version | \`$(jq -r '.jobVersion // "unknown"' "$body")\` |"
  reason="$(jq -r '.error // ""' "$body")"
  case "$deploy_status" in
    healthy) echo "Promotion healthy: job version $(jq -r '.jobVersion // "unknown"' "$body")" ;;
    superseded)
      if [ "$FAIL_ON_SUPERSEDED" = true ]; then
        error "The promotion $deploy_id was superseded by a newer deploy: ${reason:-no reason given}"
        summary_note="The promotion was superseded by a newer deploy: ${reason:-no reason given}"
        exit_with_summary 1
      fi
      notice "The promotion $deploy_id was superseded by a newer deploy. (fail-on-superseded is false.)"
      ;;
    *)
      error "The promotion ended '$deploy_status': ${reason:-no reason given}"
      summary_note="The promotion to \`$PROMOTE\` ended \`$deploy_status\`: ${reason:-no reason given}"
      exit_with_summary 1
      ;;
  esac
fi

write_summary

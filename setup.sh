#!/usr/bin/env bash
#
# One command for the whole demo rig.
#
#   ./setup.sh                          # menu
#   ./setup.sh aws                      # menu, AWS preselected
#   ./setup.sh aws site                 # 1: deploy the mock site
#   ./setup.sh aws pipeline             # 2: create the ingestion pipeline
#   ./setup.sh aws pipeline --token ID  # 2, without the prompt (CI)
#   ./setup.sh aws destroy              # 3: tear it all down
#   ./setup.sh gcp status               # what is deployed right now
#   ./setup.sh aws traffic              # send mock traffic, then score it
#
# Steps 1 and 2 are two halves of one Terraform stack, applied in order: the
# site first, so there is traffic worth logging, then the ingestion module that
# ships those logs to Obsero. Step 2 is the only one that needs your tracking
# ID -- nothing before it talks to Obsero at all.
#
# Tearing down is ./destroy.sh, which this script calls for you.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Written into terraform.tfvars by step 1, which has no use for a real token.
# Step 2 refuses to apply while this is still the value.
PLACEHOLDER="set-in-step-2"

CLOUD=""
ACTION=""
TOKEN=""
ASSUME_YES=false
N="${N:-40}"

# --- output -----------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; OFF=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
warn() { printf '%s !%s %s\n' "$YELLOW" "$OFF" "$*"; }
bad()  { printf '%s x%s %s\n' "$RED" "$OFF" "$*"; }
ok()   { printf '%s v%s %s\n' "$GREEN" "$OFF" "$*"; }
hint() { printf '   %s%s%s\n' "$DIM" "$*" "$OFF"; }

usage() {
  sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- arguments --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    aws|gcp)  CLOUD="$1" ;;
    site|1)       ACTION=site ;;
    pipeline|2)   ACTION=pipeline ;;
    destroy|3)    ACTION=destroy ;;
    traffic|4)    ACTION=traffic ;;
    status|5)     ACTION=status ;;
    --token)  TOKEN="${2:-}"; shift ;;
    -n|--count) N="${2:-40}"; shift ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage 0 ;;
    *) bad "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

# --- small helpers ----------------------------------------------------------

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  bad "$1 is not installed"
  [[ -n "${2:-}" ]] && hint "$2"
  return 1
}

confirm() {
  $ASSUME_YES && return 0
  local reply
  printf '%s [y/N] ' "$1"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

tfdir()   { printf '%s/%s/site/terraform' "$ROOT" "$1"; }
tfvars()  { printf '%s/terraform.tfvars' "$(tfdir "$1")"; }
tf()      { local c="$1"; shift; terraform -chdir="$(tfdir "$c")" "$@"; }

# An output that does not exist yet is not an error here -- it just means that
# half of the stack has not been applied.
tf_output() { tf "$1" output -raw "$2" 2>/dev/null || true; }

# Value of a top-level key in a tfvars file, unquoted. Empty when unset.
tfvar_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
    | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?(.*[^"])"?[[:space:]]*$/\1/'
}

# Set or replace a key. Written with awk rather than sed so a token containing
# / or & cannot corrupt the file.
tfvar_set() {
  local file="$1" key="$2" value="$3"
  touch "$file"; chmod 600 "$file"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    awk -v k="$key" -v v="$value" \
      '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" { printf "%s = \"%s\"\n", k, v; next } { print }' \
      "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    printf '%s = "%s"\n' "$key" "$value" >> "$file"
  fi
  chmod 600 "$file"
}

mask() {
  local t="$1"
  if [[ ${#t} -le 10 ]]; then printf '%s' "****"; else printf '%s...%s' "${t:0:4}" "${t: -4}"; fi
}

# The google provider wants Application Default Credentials. A token from the
# active gcloud login avoids a second, separate browser login just to apply --
# the same trick gcp/Makefile uses.
gcp_env() {
  if [[ -z "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]] && command -v gcloud >/dev/null 2>&1; then
    GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
    export GOOGLE_OAUTH_ACCESS_TOKEN
  fi
  [[ -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]
}

# --- preflight --------------------------------------------------------------

preflight() {
  local cloud="$1" fail=0
  step "Checking your machine"

  need terraform "https://developer.hashicorp.com/terraform/install" || fail=1
  need node "Node 18 or newer -- the traffic harness and the adapter tests need it" || fail=1

  if [[ "$cloud" == "aws" ]]; then
    need aws "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" || fail=1
    if [[ $fail -eq 0 ]]; then
      local who
      who="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
      if [[ -z "$who" ]]; then
        bad "the AWS CLI is not authenticated"
        hint "run: aws configure   (or set AWS_PROFILE)"
        fail=1
      else
        ok "AWS: ${who##*/}"
      fi
    fi
  else
    need gcloud "https://cloud.google.com/sdk/docs/install" || fail=1
    need docker "the adapter and site images are built locally, not in Cloud Build" || fail=1
    if [[ $fail -eq 0 ]]; then
      if ! gcp_env; then
        bad "gcloud is not authenticated"
        hint "run: gcloud auth login"
        fail=1
      else
        ok "GCP: $(gcloud config get-value account 2>/dev/null)"
      fi
    fi
  fi

  [[ $fail -eq 0 ]] || { say ""; bad "fix the above, then re-run"; return 1; }
  ok "everything this needs is here"
}

# roles/editor deliberately excludes log-routing config, so a plain Editor gets
# all the way to the sink before failing. Say so up front instead.
gcp_api_check() {
  local project="$1"
  local wanted=(compute run pubsub logging artifactregistry iam)
  local enabled missing=()
  enabled="$(gcloud services list --enabled --project="$project" --format='value(config.name)' 2>/dev/null || true)"
  [[ -z "$enabled" ]] && return 0   # cannot list them; let apply be the judge

  local api
  for api in "${wanted[@]}"; do
    grep -q "^${api}\.googleapis\.com$" <<< "$enabled" || missing+=("${api}.googleapis.com")
  done
  [[ ${#missing[@]} -eq 0 ]] && { ok "required APIs are enabled"; return 0; }

  warn "these APIs are not enabled in $project:"
  local a; for a in "${missing[@]}"; do hint "$a"; done
  if confirm "   Enable them now?"; then
    gcloud services enable "${missing[@]}" --project="$project"
    ok "enabled"
  else
    hint "terraform apply will fail until they are"
  fi
}

# --- stack setup ------------------------------------------------------------

ensure_init() {
  local cloud="$1"
  [[ -d "$(tfdir "$cloud")/.terraform" ]] && return 0
  step "terraform init"
  tf "$cloud" init -input=false
}

# Both stacks take obsero_site_token, which has no default -- so even step 1,
# which never uses it, cannot plan without a value. GCP additionally needs
# project_id, and destroy.sh later reads it back out of this same file.
ensure_tfvars() {
  local cloud="$1" file; file="$(tfvars "$cloud")"

  if [[ "$cloud" == "gcp" ]]; then
    local project; project="$(tfvar_get "$file" project_id)"
    if [[ -z "$project" ]]; then
      local suggested; suggested="$(gcloud config get-value project 2>/dev/null || true)"
      printf 'GCP project id%s: ' "${suggested:+ [$suggested]}"
      read -r project
      project="${project:-$suggested}"
      [[ -n "$project" ]] || { bad "a project id is required"; return 1; }
      tfvar_set "$file" project_id "$project"
    fi
    ok "project: $project"
    gcp_api_check "$project"
  fi

  [[ -n "$(tfvar_get "$file" obsero_site_token)" ]] || tfvar_set "$file" obsero_site_token "$PLACEHOLDER"
}

site_url() { tf_output "$1" site_url; }

# Host to send as x-obsero-domain when checking a token by hand. The deployed
# adapters read it off each request's Host header; this is only for the probe.
site_host() {
  local url; url="$(site_url "$1")"
  [[ -z "$url" ]] && { printf 'example.com'; return; }
  url="${url#http://}"; url="${url#https://}"; printf '%s' "${url%%/*}"
}

pipeline_up() {
  tf "$1" state list 2>/dev/null | grep -q '^module\.ingestion\.'
}

# --- 1: the mock site -------------------------------------------------------

# The site and the pipeline live in one stack, so "site only" is a targeted
# apply. Targeting the leaves pulls in everything they depend on: the bucket,
# the OAC, the NEG, the image build.
action_site() {
  local cloud="$1"
  preflight "$cloud" || return 1
  ensure_tfvars "$cloud" || return 1
  ensure_init "$cloud"

  step "Deploying the mock site"
  if [[ "$cloud" == "aws" ]]; then
    hint "private S3 bucket -> CloudFront. Takes about 3-5 minutes; CloudFront is the slow part."
    tf aws apply -auto-approve -input=false \
      -target=aws_s3_bucket_ownership_controls.site \
      -target=aws_s3_bucket_server_side_encryption_configuration.site \
      -target=aws_s3_object.site \
      -target=aws_s3_bucket_policy.site \
      -target=aws_cloudfront_distribution.site
  else
    hint "static pages on Cloud Run behind a global external Application LB + Cloud CDN."
    hint "Takes about 5-8 minutes, and builds a container image locally on the way."
    tf gcp apply -auto-approve -input=false \
      -target=google_compute_global_forwarding_rule.site \
      -target=google_cloud_run_v2_service_iam_member.public
  fi

  local url; url="$(site_url "$cloud")"
  step "Site is up"
  printf '   %s%s%s\n' "$BOLD$BLUE" "$url" "$OFF"
  say ""
  hint "Open it. Nothing is being sent to Obsero yet -- that is step 2."
  [[ "$cloud" == "gcp" ]] && hint "A new LB IP can take a few minutes to answer. A 404 early on is propagation."
  return 0
}

# --- 2: the ingestion pipeline ---------------------------------------------

action_pipeline() {
  local cloud="$1"
  preflight "$cloud" || return 1
  ensure_tfvars "$cloud" || return 1
  ensure_init "$cloud"

  local file; file="$(tfvars "$cloud")"
  local existing; existing="$(tfvar_get "$file" obsero_site_token)"

  # --- the tracking ID ---
  step "Your Obsero tracking ID"
  hint "The site token Obsero issued you. It is sent as the x-obsero-key header"
  hint "on every forwarded event, and is what proves the domain is yours."
  say ""

  if [[ -n "$TOKEN" ]]; then
    : # passed with --token, for CI
  elif [[ -n "$existing" && "$existing" != "$PLACEHOLDER" ]]; then
    say "   A tracking ID is already saved: ${BOLD}$(mask "$existing")${OFF}"
    if confirm "   Use it?"; then
      TOKEN="$existing"
    fi
  fi

  while [[ -z "$TOKEN" ]]; do
    printf '   Tracking ID: '
    read -rs TOKEN; echo
    [[ -n "$TOKEN" ]] || warn "cannot be empty"
  done
  ok "using $(mask "$TOKEN")"

  # Storing it here rather than passing -var keeps `terraform destroy` and
  # every later apply working without re-prompting. The file is gitignored.
  tfvar_set "$file" obsero_site_token "$TOKEN"
  hint "saved to ${file#"$ROOT"/} (gitignored, chmod 600)"

  # --- the site it will be collecting from ---
  local url; url="$(site_url "$cloud")"
  step "Collecting from"
  if [[ -n "$url" ]]; then
    printf '   %s%s%s\n' "$BOLD$BLUE" "$url" "$OFF"
    hint "every request to this URL becomes one POST to Obsero"
  else
    warn "no site deployed yet"
    hint "this apply will build it as well -- step 1 first is just the quicker feedback loop"
  fi

  # --- optional: prove the token before building anything ---
  local ingest; ingest="$(tfvar_get "$file" obsero_ingest_url)"
  ingest="${ingest:-https://analytics-staging.obsero.ai/v1/events}"
  if confirm "
   Send one test event first, to check the ID is accepted?"; then
    if node "$ROOT/obsero.mjs" --token "$TOKEN" --domain "$(site_host "$cloud")" --url "$ingest"; then
      ok "Obsero accepted it"
    else
      bad "Obsero rejected it -- the pipeline would silently forward into nothing"
      confirm "   Deploy anyway?" || { say "stopped"; return 1; }
    fi
  fi

  step "Building the ingestion pipeline"
  if [[ "$cloud" == "aws" ]]; then
    hint "CloudFront standard logs -> Firehose -> adapter Lambda -> POST /v1/events"
  else
    hint "LB request logs -> Log Router sink -> Pub/Sub -> Cloud Run adapter -> POST /v1/events"
  fi
  tf "$cloud" apply -auto-approve -input=false

  step "Pipeline is live"
  printf '   %-18s %s%s%s\n' "site" "$BOLD$BLUE" "$(site_url "$cloud")" "$OFF"
  if [[ "$cloud" == "aws" ]]; then
    printf '   %-18s %s\n' "log source" "$(tf_output aws log_source)"
    printf '   %-18s %s\n' "adapter" "$(tf_output aws adapter_function)"
    say ""
    hint "First events land in 60-90s: CloudFront flushes, then Firehose buffers for"
    hint "at least 60s. That is a floor, not a setting."
  else
    printf '   %-18s %s\n' "backend service" "$(tf_output gcp backend_service)"
    printf '   %-18s %s\n' "adapter" "$(tf_output gcp adapter_service)"
    say ""
    hint "The header allow-list takes several minutes to reach the edge. Events that"
    hint "arrive headerless right after this are propagation, not breakage."
  fi
  say ""
  say "   Next: ${BOLD}./setup.sh $cloud traffic${OFF}  to send mock agent traffic and score what arrived"
  warn "the demo rig bills while it is up -- ./setup.sh $cloud destroy when you are done"
  return 0
}

# --- 3: destroy -------------------------------------------------------------

action_destroy() {
  local cloud="$1"
  step "Tearing down $cloud"
  if [[ "$cloud" == "gcp" ]]; then
    hint "the forwarding rule bills at idle, so this is the one that matters"
  fi
  local args=("$cloud")
  $ASSUME_YES && args+=(--yes)
  "$ROOT/destroy.sh" "${args[@]}"
}

# --- 4: traffic -------------------------------------------------------------

action_traffic() {
  local cloud="$1"
  local url; url="$(site_url "$cloud")"
  [[ -n "$url" ]] || { bad "nothing deployed -- run step 1 first"; return 1; }

  if ! pipeline_up "$cloud"; then
    warn "the ingestion pipeline is not deployed, so nothing will reach Obsero"
    confirm "   Send traffic anyway?" || return 1
  fi

  step "Sending $N requests to $url"
  hint "19 client personas: AI agents, AI crawlers, search bots and real browsers"
  make -C "$ROOT/$cloud" traffic "N=$N"

  local wait=60
  [[ "$cloud" == "aws" ]] && wait=90
  step "Waiting ${wait}s for delivery"
  hint "$([[ "$cloud" == "aws" ]] && echo "CloudFront flush + Firehose's 60s minimum buffer" || echo "Cloud Logging -> sink -> Pub/Sub -> adapter")"
  sleep "$wait"

  step "Scoring what actually arrived"
  make -C "$ROOT/$cloud" check
}

# --- 5: status --------------------------------------------------------------

action_status() {
  local cloud="$1"
  local file; file="$(tfvars "$cloud")"

  step "$cloud"
  local url; url="$(site_url "$cloud")"
  if [[ -n "$url" ]]; then
    ok "site        $url"
  else
    say "   ${DIM}site        not deployed${OFF}"
  fi

  if pipeline_up "$cloud"; then
    ok "pipeline    deployed"
  else
    say "   ${DIM}pipeline    not deployed${OFF}"
  fi

  local token; token="$(tfvar_get "$file" obsero_site_token)"
  if [[ -z "$token" || "$token" == "$PLACEHOLDER" ]]; then
    say "   ${DIM}tracking ID not set${OFF}"
  else
    ok "tracking ID $(mask "$token")"
  fi

  # destroy.sh --check also finds resources no longer in state, which a plan
  # will never mention.
  "$ROOT/destroy.sh" "$cloud" --check
}

# --- menu -------------------------------------------------------------------

pick_cloud() {
  say ""
  say "${BOLD}Which cloud?${OFF}"
  say "  1) aws   CloudFront -> Firehose -> Lambda adapter"
  say "  2) gcp   Load balancer logs -> Pub/Sub -> Cloud Run adapter"
  local reply
  printf 'Choose [1]: '
  read -r reply
  case "${reply:-1}" in
    1|aws) CLOUD=aws ;;
    2|gcp) CLOUD=gcp ;;
    q|quit) exit 0 ;;
    *) bad "pick 1 or 2"; pick_cloud ;;
  esac
}

menu() {
  local reply
  while true; do
    say ""
    say "${BOLD}Obsero ingestion -- $CLOUD${OFF}"
    say ""
    say "  ${BOLD}1${OFF}) Deploy a mock site            a site worth collecting logs from"
    say "  ${BOLD}2${OFF}) Create the ingestion pipeline ${DIM}asks for your tracking ID${OFF}"
    say "  ${BOLD}3${OFF}) Destroy everything            ${DIM}the rig bills while it is up${OFF}"
    say ""
    say "  ${DIM}4) Send mock traffic and score what arrived${OFF}"
    say "  ${DIM}5) Status -- what is deployed right now${OFF}"
    say "  ${DIM}6) Switch cloud${OFF}"
    say "  ${DIM}q) Quit${OFF}"
    say ""
    printf 'Choose: '
    read -r reply || exit 0

    case "$reply" in
      1) action_site "$CLOUD" || true ;;
      2) action_pipeline "$CLOUD" || true ;;
      3) action_destroy "$CLOUD" || true ;;
      4) action_traffic "$CLOUD" || true ;;
      5) action_status "$CLOUD" || true ;;
      6) pick_cloud ;;
      q|quit|"") say "bye"; exit 0 ;;
      *) bad "no such option: $reply" ;;
    esac
    TOKEN=""   # never reuse a prompt answer across menu choices
  done
}

# --- run --------------------------------------------------------------------

if [[ -z "$CLOUD" ]]; then
  if [[ -t 0 ]]; then
    pick_cloud
  else
    bad "which cloud? e.g. ./setup.sh aws ${ACTION:-site}"
    exit 1
  fi
fi

if [[ -n "$ACTION" ]]; then
  "action_$ACTION" "$CLOUD"
  exit 0
fi

menu

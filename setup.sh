#!/usr/bin/env bash
#
# One command for the whole demo rig.
#
#   ./setup.sh                          # menu
#   ./setup.sh aws                      # menu, AWS preselected
#   ./setup.sh aws site                 # 1: deploy the mock site
#   ./setup.sh aws pipeline             # 2: deploy the ingestion pipeline
#   ./setup.sh aws pipeline --token ID  # 2, without the prompt (CI)
#   ./setup.sh aws connect              # 3: pick distributions in your account
#   ./setup.sh aws connect --dist E1,E2 # 3, without the picker ("none" clears,
#                                       #    "+E3" adds to what is connected)
#   ./setup.sh aws destroy              # 4: tear it all down
#   ./setup.sh gcp status               # what is deployed right now
#   ./setup.sh aws traffic              # send mock traffic, then score it
#
# On AWS the three steps are independent: the mock site, the pipeline, and the
# connection between the pipeline and any CloudFront distributions already in
# your account -- the mock site is just one of them. Step 2 is the only one
# that needs your tracking ID. On GCP the pipeline attaches to the mock site
# directly, so there is no step 3.
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
DISTS=""
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
  sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- arguments --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    aws|gcp)  CLOUD="$1" ;;
    site|1)       ACTION=site ;;
    pipeline|2)   ACTION=pipeline ;;
    connect|3)    ACTION=connect ;;
    destroy|4)    ACTION=destroy ;;
    traffic|5)    ACTION=traffic ;;
    status|6)     ACTION=status ;;
    --token)  TOKEN="${2:-}"; shift ;;
    --dist)   DISTS="${DISTS:+$DISTS,}${2:-}"; shift ;;
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

# Lists and maps are written on one line each, so they can be replaced whole.
tfvar_set_raw() {
  local file="$1" key="$2" hcl="$3"
  touch "$file"; chmod 600 "$file"
  awk -v k="$key" '$0 !~ "^[[:space:]]*"k"[[:space:]]*=" { print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  printf '%s = %s\n' "$key" "$hcl" >> "$file"
  chmod 600 "$file"
}

# Reads a secret into the variable named $1, echoing one * per character so a
# paste visibly landed. Backspace works. Without a terminal, reads plainly.
read_secret() {
  local -n _out=$1
  local ch
  _out=""
  if [[ ! -t 0 ]]; then read -r _out; return; fi
  while IFS= read -rsn1 ch; do
    case "$ch" in
      "") break ;;                         # Enter
      $'\x7f'|$'\b')                       # Backspace
        if [[ -n "$_out" ]]; then _out="${_out%?}"; printf '\b \b'; fi ;;
      $'\r'|$'\n') break ;;
      *) _out+="$ch"; printf '*' ;;
    esac
  done
  echo
  [[ -n "$_out" ]] && say "   ${DIM}got ${#_out} characters: $(mask "$_out")${OFF}"
  return 0
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
  if [[ "$cloud" == "aws" ]]; then
    hint "Open it. Nothing is being sent to Obsero yet -- step 2 builds the pipeline,"
    hint "step 3 connects this site (or any other distribution) to it."
  else
    hint "Open it. Nothing is being sent to Obsero yet -- that is step 2."
  fi
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
    printf '   Tracking ID (paste, then Enter): '
    read_secret TOKEN
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
  if [[ "$cloud" == "aws" ]]; then
    prune_connections || return 1
    local arns; arns="$(connected_arns)"
    if [[ -n "$arns" ]]; then
      local arn; for arn in $arns; do printf '   %s%s%s\n' "$BOLD$BLUE" "${arn##*/}" "$OFF"; done
      hint "every request to these distributions becomes one POST to Obsero"
    else
      say "   ${DIM}nothing yet -- the pipeline is built idle, and step 3 connects it${OFF}"
      hint "to any CloudFront distribution in your account, the mock site included"
    fi
  elif [[ -n "$url" ]]; then
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
    # Only the pipeline: the mock site is step 1 and is not needed here.
    apply_pipeline || return 1
  else
    hint "LB request logs -> Log Router sink -> Pub/Sub -> Cloud Run adapter -> POST /v1/events"
    tf "$cloud" apply -auto-approve -input=false
  fi

  step "Pipeline is live"
  if [[ "$cloud" == "aws" ]]; then
    printf '   %-18s %s\n' "adapter" "$(tf_output aws adapter_function)"
    printf '   %-18s %s\n' "firehose" "$(tf_output aws firehose_stream)"
    printf '   %-18s %s\n' "connected" "$(connected_ids_display)"
    say ""
    if [[ -z "$(connected_arns)" ]]; then
      say "   Next: ${BOLD}./setup.sh aws connect${OFF}  to pick the distributions it collects from"
      hint "the pipeline bills per record, so it costs next to nothing while idle"
      return 0
    fi
    hint "First events land in 60-90s: CloudFront flushes, then Firehose buffers for"
    hint "at least 60s. That is a floor, not a setting."
  else
    printf '   %-18s %s%s%s\n' "site" "$BOLD$BLUE" "$(site_url "$cloud")" "$OFF"
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

# --- 3: connect (AWS) -------------------------------------------------------

aws_region()  { local r; r="$(tfvar_get "$(tfvars aws)" region)";  printf '%s' "${r:-us-east-1}"; }
aws_project() { local p; p="$(tfvar_get "$(tfvars aws)" project)"; printf '%s' "${p:-agent-analytics-mock-site}"; }

# ARNs the pipeline is (or will be, on the next apply) connected to, one per
# line. terraform.tfvars is the source of truth; the state follows it.
connected_arns() {
  grep -E '^[[:space:]]*connected_distribution_arns[[:space:]]*=' "$(tfvars aws)" 2>/dev/null \
    | grep -oE 'arn:aws:cloudfront::[0-9]+:distribution/[A-Z0-9]+' || true
}

connected_ids_display() {
  local arns out="" arn
  arns="$(connected_arns)"
  [[ -z "$arns" ]] && { printf 'nothing yet'; return; }
  for arn in $arns; do out+="${out:+, }${arn##*/}"; done
  printf '%s' "$out"
}

# Every CloudFront distribution in the account, one row each, fields split by
# the ASCII unit separator -- not tab, which `read` collapses when a field such
# as the comment is empty:
#   id  arn  status  enabled  domain  aliases  comment  existing-source
# existing-source names a standard logging v2 source the distribution already
# has that this stack did not create -- the console makes one the first time
# anyone turns standard logging v2 on. Only one is allowed, so we reuse it.
DIST_ROWS=""
load_distributions() {
  local dists sources
  if ! dists="$(aws cloudfront list-distributions --output json 2>&1)"; then
    bad "could not list CloudFront distributions"
    hint "$dists"
    return 1
  fi
  sources="$(aws logs describe-delivery-sources --region "$(aws_region)" --output json 2>/dev/null || echo '{}')"
  DIST_ROWS="$(DISTS_JSON="$dists" SOURCES_JSON="$sources" PROJECT="$(aws_project)" node -e '
    const d = JSON.parse(process.env.DISTS_JSON || "{}");
    const s = JSON.parse(process.env.SOURCES_JSON || "{}");
    const clean = (v) => String(v ?? "").replace(/[\x1f\n]/g, " ");
    const existing = {};
    for (const src of s.deliverySources || []) {
      if (src.logType !== "ACCESS_LOGS") continue;
      for (const arn of src.resourceArns || []) {
        const id = arn.split("/").pop();
        if (src.name !== `${process.env.PROJECT}-${id}`) existing[arn] = src.name;
      }
    }
    for (const it of (d.DistributionList || {}).Items || []) {
      console.log([it.Id, it.ARN, it.Status, it.Enabled, it.DomainName,
        ((it.Aliases || {}).Items || []).join(","), it.Comment, existing[it.ARN] || ""].map(clean).join("\x1f"));
    }
  ')"
}

# Drop connections whose distribution no longer exists -- after the mock site
# is destroyed and redeployed, say, its old ARN would fail the whole apply.
prune_connections() {
  local arns keep=() arn
  arns="$(connected_arns)"
  [[ -z "$arns" ]] && return 0
  load_distributions || return 1
  for arn in $arns; do
    if awk -F'\037' -v a="$arn" '$2 == a { found = 1 } END { exit !found }' <<< "$DIST_ROWS"; then
      keep+=("$arn")
    else
      warn "${arn##*/} no longer exists in this account -- disconnecting it"
    fi
  done
  [[ ${#keep[@]} -eq $(wc -w <<< "$arns") ]] && return 0
  write_connections "${keep[@]}"
}

# Writes the chosen ARNs to terraform.tfvars, together with the existing
# sources the module must reuse instead of creating its own. Needs DIST_ROWS.
write_connections() {
  local file list="" map="" arn src
  file="$(tfvars aws)"
  for arn in "$@"; do
    list+="${list:+, }\"$arn\""
    src="$(awk -F'\037' -v a="$arn" '$2 == a { print $8 }' <<< "$DIST_ROWS")"
    [[ -n "$src" ]] && map+="${map:+, }\"$arn\" = \"$src\""
  done
  tfvar_set_raw "$file" connected_distribution_arns "[${list}]"
  tfvar_set_raw "$file" existing_delivery_sources "{${map}}"
}

# The pipeline module only. It does not reference the mock site, so -target
# keeps this from building the site too.
apply_pipeline() {
  tf aws apply -auto-approve -input=false -target=module.ingestion
}

# Numbered list of DIST_ROWS; $1 names an associative array of selected ARNs.
print_distributions() {
  local -n _sel=$1
  local site_arn i=0 id arn status enabled domain aliases comment src mark note
  site_arn="$(tf_output aws distribution_arn)"
  say ""
  while IFS=$'\x1f' read -r id arn status enabled domain aliases comment src; do
    [[ -z "$id" ]] && continue
    i=$((i + 1))
    mark="[ ]"; [[ -n "${_sel[$arn]:-}" ]] && mark="${GREEN}[x]${OFF}"
    printf '  %s%2d%s) %s %-15s %s\n' "$BOLD" "$i" "$OFF" "$mark" "$id" "${aliases:-$domain}"
    note=""
    [[ "$arn" == "$site_arn" ]] && note+="${BLUE}the mock site${OFF}  "
    [[ -n "$comment" ]] && note+="\"$comment\"  "
    [[ "${enabled,,}" != "true" ]] && note+="${YELLOW}disabled${OFF}  "
    [[ "$status" != "Deployed" ]] && note+="${DIM}$status${OFF}  "
    [[ -n "$aliases" ]] && note+="${DIM}$domain${OFF}  "
    [[ -n "$note" ]] && printf '             %s\n' "$note"
    [[ -n "$src" ]] && printf '             %sreuses its existing logging source "%s"%s\n' "$DIM" "$src" "$OFF"
  done <<< "$DIST_ROWS"
  say ""
}

action_connect() {
  local cloud="$1"
  if [[ "$cloud" != "aws" ]]; then
    bad "connect is AWS-only"
    hint "the GCP pipeline attaches straight to the mock site's backend service in step 2"
    return 1
  fi
  if (( BASH_VERSINFO[0] < 4 )); then
    bad "the picker needs bash 4 or newer (this is $BASH_VERSION)"
    hint "macOS ships bash 3.2: brew install bash, then re-run"
    return 1
  fi
  preflight aws || return 1
  ensure_tfvars aws || return 1
  ensure_init aws

  local token; token="$(tfvar_get "$(tfvars aws)" obsero_site_token)"
  if [[ -z "$token" || "$token" == "$PLACEHOLDER" ]]; then
    bad "no tracking ID yet -- deploy the pipeline first (step 2)"
    return 1
  fi

  step "CloudFront distributions in this account"
  load_distributions || return 1
  local ids=() arns=() id arn rest
  while IFS=$'\x1f' read -r id arn rest; do
    [[ -z "$id" ]] && continue
    ids+=("$id"); arns+=("$arn")
  done <<< "$DIST_ROWS"
  if [[ ${#ids[@]} -eq 0 ]]; then
    warn "there are none"
    hint "step 1 deploys a mock site you can connect"
    return 1
  fi

  local -A selected=() before=()
  for arn in $(connected_arns); do selected[$arn]=1; before[$arn]=1; done

  if [[ -n "$DISTS" ]]; then
    # --dist E1,E2: exactly this set, no picker. "none" disconnects everything.
    # --dist +E1: add to what is already connected instead.
    [[ "$DISTS" == +* ]] || selected=()
    local wanted want i found
    IFS=',' read -ra wanted <<< "$DISTS"
    for want in "${wanted[@]}"; do
      want="${want#+}"
      [[ -z "$want" || "$want" == "none" ]] && continue
      found=""
      for i in "${!ids[@]}"; do
        if [[ "${ids[$i]}" == "$want" || "${arns[$i]}" == "$want" ]]; then
          selected[${arns[$i]}]=1; found=1
        fi
      done
      [[ -n "$found" ]] || { bad "no distribution $want in this account"; return 1; }
    done
    print_distributions selected
  else
    [[ -t 0 ]] || { bad "no terminal to pick from -- pass --dist <id>[,<id>] or --dist none"; return 1; }
    local reply n
    while true; do
      print_distributions selected
      hint "numbers toggle (e.g. \"1 3\"), a = all, n = none, Enter = done, q = cancel"
      printf 'Connect: '
      read -r reply || return 1
      case "$reply" in
        "") break ;;
        q|quit) say "cancelled"; return 1 ;;
        a|all) for arn in "${arns[@]}"; do selected[$arn]=1; done ;;
        n|none) selected=() ;;
        *)
          for n in ${reply//,/ }; do
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#arns[@]} )); then
              arn="${arns[$((n - 1))]}"
              if [[ -n "${selected[$arn]:-}" ]]; then unset "selected[$arn]"; else selected[$arn]=1; fi
            else
              bad "no such distribution: $n"
            fi
          done ;;
      esac
    done
  fi

  local add=() remove=()
  for arn in "${!selected[@]}"; do [[ -n "${before[$arn]:-}" ]] || add+=("$arn"); done
  for arn in "${!before[@]}"; do [[ -n "${selected[$arn]:-}" ]] || remove+=("$arn"); done
  if [[ ${#add[@]} -eq 0 && ${#remove[@]} -eq 0 ]]; then
    ok "nothing to change"
    return 0
  fi

  step "Changes"
  for arn in "${add[@]}"; do say "   ${GREEN}+ connect${OFF}     ${arn##*/}"; done
  for arn in "${remove[@]}"; do say "   ${RED}- disconnect${OFF}  ${arn##*/}"; done
  hint "the distributions themselves are not modified: this adds or removes a"
  hint "standard logging v2 delivery from each one into the pipeline's Firehose"
  confirm "   Apply?" || { say "cancelled"; return 1; }

  # Keep the order the account lists them in, so the tfvars diff stays stable.
  local chosen=()
  for arn in "${arns[@]}"; do [[ -n "${selected[$arn]:-}" ]] && chosen+=("$arn"); done
  write_connections "${chosen[@]}"
  apply_pipeline || return 1

  step "Connected"
  printf '   %-18s %s\n' "collecting from" "$(connected_ids_display)"
  if [[ ${#chosen[@]} -gt 0 ]]; then
    say ""
    hint "First events land in 60-90s: CloudFront flushes, then Firehose buffers for"
    hint "at least 60s. Watch them arrive with: make -C aws logs"
  fi
  return 0
}

# --- 4: destroy -------------------------------------------------------------

action_destroy() {
  local cloud="$1"
  step "Tearing down $cloud"
  if [[ "$cloud" == "gcp" ]]; then
    hint "the forwarding rule bills at idle, so this is the one that matters"
  fi
  local args=("$cloud")
  $ASSUME_YES && args+=(--yes)
  "$ROOT/destroy.sh" "${args[@]}" || return 1

  # The connections went with the pipeline. Forget them, so the next pipeline
  # starts idle rather than reaching for a mock site that no longer exists.
  if [[ "$cloud" == "aws" && -f "$(tfvars aws)" ]]; then
    tfvar_set_raw "$(tfvars aws)" connected_distribution_arns "[]"
    tfvar_set_raw "$(tfvars aws)" existing_delivery_sources "{}"
  fi
}

# --- 5: traffic -------------------------------------------------------------

action_traffic() {
  local cloud="$1"
  local url; url="$(site_url "$cloud")"
  [[ -n "$url" ]] || { bad "nothing deployed -- run step 1 first"; return 1; }

  if ! pipeline_up "$cloud"; then
    warn "the ingestion pipeline is not deployed, so nothing will reach Obsero"
    confirm "   Send traffic anyway?" || return 1
  elif [[ "$cloud" == "aws" ]] && ! connected_arns | grep -qxF "$(tf_output aws distribution_arn)"; then
    warn "the mock site is not connected to the pipeline, so nothing will reach Obsero"
    hint "connect it with: ./setup.sh aws connect"
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

# --- 6: status --------------------------------------------------------------

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
    if [[ "$cloud" == "aws" ]]; then
      local connected
      connected="$(tf aws output -json connected_distributions 2>/dev/null | tr -d '[]" \n' | sed 's/,/, /g' || true)"
      if [[ -n "$connected" ]]; then
        ok "connected   $connected"
      else
        say "   ${DIM}connected   nothing -- ./setup.sh aws connect${OFF}"
      fi
    fi
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
    say "  ${BOLD}1${OFF}) Deploy the mock site          a site worth collecting logs from"
    say "  ${BOLD}2${OFF}) Deploy the ingestion pipeline ${DIM}asks for your tracking ID${OFF}"
    if [[ "$CLOUD" == "aws" ]]; then
      say "  ${BOLD}3${OFF}) Connect                       ${DIM}pick distributions already in your account${OFF}"
    else
      say "  ${DIM}3) Connect                       aws only -- gcp attaches in step 2${OFF}"
    fi
    say "  ${BOLD}4${OFF}) Destroy everything            ${DIM}the rig bills while it is up${OFF}"
    say ""
    say "  ${DIM}5) Send mock traffic and score what arrived${OFF}"
    say "  ${DIM}6) Status -- what is deployed right now${OFF}"
    say "  ${DIM}7) Switch cloud${OFF}"
    say "  ${DIM}q) Quit${OFF}"
    say ""
    printf 'Choose: '
    read -r reply || exit 0

    case "$reply" in
      1) action_site "$CLOUD" || true ;;
      2) action_pipeline "$CLOUD" || true ;;
      3) action_connect "$CLOUD" || true ;;
      4) action_destroy "$CLOUD" || true ;;
      5) action_traffic "$CLOUD" || true ;;
      6) action_status "$CLOUD" || true ;;
      7) pick_cloud ;;
      q|quit|"") say "bye"; exit 0 ;;
      *) bad "no such option: $reply" ;;
    esac
    TOKEN=""; DISTS=""   # never reuse a prompt answer across menu choices
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

#!/usr/bin/env bash
#
# Tear down everything this repo deploys.
#
#   ./destroy.sh              # both clouds, after confirming
#   ./destroy.sh aws          # one cloud
#   ./destroy.sh --dry-run    # show what would go, touch nothing
#   ./destroy.sh --check      # only report what is still deployed
#   ./destroy.sh --yes        # no prompt (CI)
#   ./destroy.sh --sweep      # also delete leftovers Terraform did not own
#
# Terraform does the work. This wrapper handles the three things it cannot:
# emptying S3 buckets it does not own the contents of, running each stack with
# the right credentials, and checking afterwards that nothing is still billing.
set -euo pipefail
# The AWS queries below contain [?...], which bash would otherwise try to glob.
set -f

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGETS=()
ASSUME_YES=false
DRY_RUN=false
CHECK_ONLY=false
SWEEP=false

# Resource name prefix, matching the `project` / `name_prefix` variable
# defaults. Only used by the leftover sweep, which cannot read Terraform state.
PREFIX="${PREFIX:-agent-analytics-mock-site}"

# --- output -----------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
warn() { printf '%s !%s %s\n' "$YELLOW" "$OFF" "$*"; }
bad()  { printf '%s x%s %s\n' "$RED" "$OFF" "$*"; }
ok()   { printf '%s v%s %s\n' "$GREEN" "$OFF" "$*"; }

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- arguments --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    aws|gcp) TARGETS+=("$1") ;;
    all)     TARGETS+=(aws gcp) ;;
    -y|--yes) ASSUME_YES=true ;;
    -n|--dry-run) DRY_RUN=true ;;
    -c|--check) CHECK_ONLY=true ;;
    --sweep) SWEEP=true ;;
    --prefix) PREFIX="$2"; shift ;;
    -h|--help) usage 0 ;;
    *) bad "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(aws gcp)

need() {
  command -v "$1" >/dev/null 2>&1 || { bad "$1 is not installed"; return 1; }
}

# --- what is actually deployed ----------------------------------------------

stack_dir() { printf '%s/%s/site/terraform' "$ROOT" "$1"; }

# Resource count in a stack's state, or 0 when there is no state to speak of.
stack_count() {
  local dir; dir="$(stack_dir "$1")"
  [[ -f "$dir/terraform.tfstate" ]] || { echo 0; return; }
  # grep -c already prints 0 when it matches nothing; it just exits 1 doing so.
  terraform -chdir="$dir" state list 2>/dev/null | grep -c . || true
}

# The google provider wants Application Default Credentials; a token from the
# active gcloud login avoids a second, separate browser login just to destroy.
gcp_env() {
  if [[ -z "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]] && command -v gcloud >/dev/null 2>&1; then
    GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
    export GOOGLE_OAUTH_ACCESS_TOKEN
  fi
}

# --- AWS --------------------------------------------------------------------

# Terraform refuses to delete a bucket holding objects it does not manage. The
# demo site sets backup_force_destroy, but a stack applied before that variable
# existed still has force_destroy = false in state, so empty them here too.
empty_aws_buckets() {
  local dir; dir="$(stack_dir aws)"
  local bucket
  for output in bucket_name backup_bucket; do
    bucket="$(terraform -chdir="$dir" output -raw "$output" 2>/dev/null || true)"
    [[ -z "$bucket" || "$bucket" == *"No outputs"* ]] && continue
    if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
      say "  ${DIM}$bucket already gone${OFF}"
      continue
    fi
    local n
    n="$(aws s3api list-objects-v2 --bucket "$bucket" --query 'KeyCount' --output text 2>/dev/null || echo 0)"
    [[ "$n" == "None" || -z "$n" ]] && n=0
    if [[ "$n" == "0" ]]; then
      say "  ${DIM}$bucket is empty${OFF}"
    else
      warn "$bucket holds $n object(s) -- deleting them"
      [[ "$output" == "backup_bucket" ]] && warn "  these are events that never reached Obsero"
      aws s3 rm "s3://$bucket" --recursive --only-show-errors
    fi
  done
}

destroy_aws() {
  local dir; dir="$(stack_dir aws)"
  need terraform || return 1
  need aws || return 1

  if $DRY_RUN; then
    terraform -chdir="$dir" plan -destroy -input=false
    return
  fi

  step "AWS: emptying S3 buckets"
  empty_aws_buckets

  step "AWS: terraform destroy"
  terraform -chdir="$dir" destroy -auto-approve -input=false
}

# Anything still carrying the prefix. Terraform state can be lost, a partial
# destroy can strand resources, and neither shows up in a plan.
sweep_aws() {
  step "AWS: checking for leftovers"
  SWEEP_FOUND=0

  # CloudFront is the one thing that cannot be deleted in a single call: it has
  # to be disabled, then deleted once the change has propagated. Report it.
  local dists
  dists="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Comment, \`$PREFIX\`)].Id" \
    --output text 2>/dev/null || true)"
  # With every distribution gone the query has nothing to filter, and the CLI
  # prints the literal "None" rather than an empty string.
  [[ "$dists" == "None" ]] && dists=""
  for id in $dists; do
    bad "cloudfront distribution $id"
    say "    ${DIM}disable it, wait for Deployed, then delete -- CloudFront needs both, minutes apart${OFF}"
    SWEEP_FOUND=$((SWEEP_FOUND + 1))
  done

  sweep_aws_kind "s3 bucket" \
    "aws s3api list-buckets --query Buckets[?starts_with(Name,\`$PREFIX\`)].Name --output text" \
    "aws s3 rb s3://NAME --force"
  sweep_aws_kind "firehose stream" \
    "aws firehose list-delivery-streams --query DeliveryStreamNames[?starts_with(@,\`$PREFIX\`)] --output text" \
    "aws firehose delete-delivery-stream --delivery-stream-name NAME"
  sweep_aws_kind "kinesis stream (bills ~\$11/month)" \
    "aws kinesis list-streams --query StreamNames[?starts_with(@,\`$PREFIX\`)] --output text" \
    "aws kinesis delete-stream --stream-name NAME --enforce-consumer-deletion"
  sweep_aws_kind "lambda" \
    "aws lambda list-functions --query Functions[?starts_with(FunctionName,\`$PREFIX\`)].FunctionName --output text" \
    "aws lambda delete-function --function-name NAME"
  sweep_aws_kind "log group" \
    "aws logs describe-log-groups --query logGroups[?contains(logGroupName,\`$PREFIX\`)].logGroupName --output text" \
    "aws logs delete-log-group --log-group-name NAME"

  sweep_aws_roles

  [[ $SWEEP_FOUND -eq 0 ]] && ok "nothing left"
  return 0
}

# Lists one kind of resource; deletes each with --sweep, otherwise prints the
# command that would. Adds what it finds to SWEEP_FOUND.
sweep_aws_kind() {
  local label="$1" list_cmd="$2" delete_tpl="$3"
  local names name cmd

  # Word-split deliberately: the list command is a fixed string built above,
  # never user input. AWS returns tab-separated names on one line, which the
  # loop below splits on whitespace.
  names="$($list_cmd 2>/dev/null || true)"
  [[ -z "$names" || "$names" == "None" ]] && return 0

  for name in $names; do
    bad "$label $name"
    SWEEP_FOUND=$((SWEEP_FOUND + 1))
    cmd="${delete_tpl//NAME/$name}"
    if $SWEEP; then
      if eval "$cmd" >/dev/null 2>&1; then
        ok "  deleted"
      else
        warn "  could not delete -- something may still depend on it"
      fi
    else
      say "    ${DIM}$cmd${OFF}"
    fi
  done
  return 0
}

# IAM roles need their policies removed before the role itself will go, so they
# do not fit the generic helper.
sweep_aws_roles() {
  local roles role policy
  roles="$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`$PREFIX\`)].RoleName" --output text 2>/dev/null || true)"
  [[ -z "$roles" || "$roles" == "None" ]] && return 0

  for role in $roles; do
    bad "iam role $role"
    SWEEP_FOUND=$((SWEEP_FOUND + 1))
    if ! $SWEEP; then
      say "    ${DIM}detach its policies, then: aws iam delete-role --role-name $role${OFF}"
      continue
    fi
    for policy in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null || true); do
      aws iam delete-role-policy --role-name "$role" --policy-name "$policy" >/dev/null 2>&1 || true
    done
    for policy in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" >/dev/null 2>&1 || true
    done
    if aws iam delete-role --role-name "$role" >/dev/null 2>&1; then
      ok "  deleted"
    else
      warn "  could not delete"
    fi
  done
  return 0
}

# --- GCP --------------------------------------------------------------------

destroy_gcp() {
  local dir; dir="$(stack_dir gcp)"
  need terraform || return 1
  need gcloud || return 1
  gcp_env

  # project_id has no default, so a stack applied with one tfvars cannot be
  # destroyed without it. Say so plainly rather than letting Terraform fail
  # with a variable prompt in a script that runs unattended.
  if [[ -f "$dir/terraform.tfstate" ]] && ! grep -qs '^project_id' "$dir/terraform.tfvars"; then
    bad "gcp/site/terraform/terraform.tfvars has no project_id"
    say "  ${DIM}add the project this stack was applied to, then re-run${OFF}"
    return 1
  fi

  if $DRY_RUN; then
    terraform -chdir="$dir" plan -destroy -input=false
    return
  fi

  step "GCP: terraform destroy"
  say "  ${DIM}the forwarding rule bills at idle, so this is the one that matters${OFF}"
  terraform -chdir="$dir" destroy -auto-approve -input=false
}

sweep_gcp() {
  local project="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  [[ -z "$project" ]] && { warn "no gcloud project set, skipping the GCP sweep"; return 0; }
  local region="${REGION:-us-central1}"

  # Service account IDs cap at 30 characters, so the module truncates the
  # prefix to 21 and drops any trailing hyphen. Match what it actually created,
  # or the accounts are missed: "agent-analytics-mock-site" becomes
  # "agent-analytics-mock-pusher", which does not start with the full prefix.
  local sa_prefix="${PREFIX:0:21}"
  while [[ "$sa_prefix" == *- ]]; do sa_prefix="${sa_prefix%-}"; done

  step "GCP: checking for leftovers in $project"
  SWEEP_FOUND=0

  # Forwarding rules first: that is the one that bills while it sits there.
  # Then the rest of the load balancer, in dependency order, because a URL map
  # cannot go while a proxy still points at it.
  sweep_gcp_kind "forwarding rule" \
    "gcloud compute forwarding-rules list --global --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud compute forwarding-rules delete NAME --global --project=$project --quiet"
  sweep_gcp_kind "target proxy" \
    "gcloud compute target-http-proxies list --global --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud compute target-http-proxies delete NAME --global --project=$project --quiet"
  sweep_gcp_kind "url map" \
    "gcloud compute url-maps list --global --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud compute url-maps delete NAME --global --project=$project --quiet"
  sweep_gcp_kind "backend service" \
    "gcloud compute backend-services list --global --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud compute backend-services delete NAME --global --project=$project --quiet"
  sweep_gcp_kind "network endpoint group" \
    "gcloud compute network-endpoint-groups list --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud compute network-endpoint-groups delete NAME --region=$region --project=$project --quiet"
  sweep_gcp_kind "static address" \
    "gcloud compute addresses list --global --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud compute addresses delete NAME --global --project=$project --quiet"
  sweep_gcp_kind "cloud run service" \
    "gcloud run services list --project=$project --filter=metadata.name~^$PREFIX --format=value(metadata.name)" \
    "gcloud run services delete NAME --project=$project --region=$region --quiet"
  sweep_gcp_kind "pubsub subscription" \
    "gcloud pubsub subscriptions list --project=$project --filter=name~$PREFIX --format=value(name)" \
    "gcloud pubsub subscriptions delete NAME --project=$project --quiet"
  sweep_gcp_kind "pubsub topic" \
    "gcloud pubsub topics list --project=$project --filter=name~$PREFIX --format=value(name)" \
    "gcloud pubsub topics delete NAME --project=$project --quiet"
  sweep_gcp_kind "log sink" \
    "gcloud logging sinks list --project=$project --filter=name~^$PREFIX --format=value(name)" \
    "gcloud logging sinks delete NAME --project=$project --quiet"
  sweep_gcp_kind "artifact repository" \
    "gcloud artifacts repositories list --project=$project --location=$region --filter=name~$PREFIX --format=value(name)" \
    "gcloud artifacts repositories delete NAME --project=$project --location=$region --quiet"
  sweep_gcp_kind "service account" \
    "gcloud iam service-accounts list --project=$project --filter=email~^$sa_prefix --format=value(email)" \
    "gcloud iam service-accounts delete NAME --project=$project --quiet"

  [[ $SWEEP_FOUND -eq 0 ]] && ok "nothing left"
  return 0
}

# Lists one kind of resource; deletes each with --sweep, otherwise prints the
# command that would. Adds what it finds to SWEEP_FOUND.
sweep_gcp_kind() {
  local label="$1" list_cmd="$2" delete_tpl="$3"
  local names name cmd

  # Word-split deliberately: the list command is a fixed string built above,
  # never user input.
  names="$($list_cmd 2>/dev/null || true)"
  [[ -z "$names" ]] && return 0

  while read -r name; do
    [[ -z "$name" ]] && continue
    name="${name##*/}" # topics and subscriptions come back fully qualified
    bad "$label $name"
    SWEEP_FOUND=$((SWEEP_FOUND + 1))
    cmd="${delete_tpl//NAME/$name}"
    if $SWEEP; then
      if eval "$cmd" >/dev/null 2>&1; then
        ok "  deleted"
      else
        warn "  could not delete -- something may still depend on it"
      fi
    else
      say "    ${DIM}$cmd${OFF}"
    fi
  done <<< "$names"
  return 0
}

# --- run --------------------------------------------------------------------

if $CHECK_ONLY; then
  for target in "${TARGETS[@]}"; do
    count="$(stack_count "$target")"
    say "  ${BOLD}$target${OFF}  $count resources in Terraform state"
    SWEEP=false "sweep_$target" || true
  done
  exit 0
fi

step "Planned teardown"
TO_RUN=()
for target in "${TARGETS[@]}"; do
  count="$(stack_count "$target")"
  if [[ "$count" == "0" ]]; then
    say "  ${DIM}$target  no Terraform state -- nothing to destroy${OFF}"
    # Still worth sweeping: state can be lost while the resources live on.
    TO_RUN+=("$target:sweep-only")
  else
    say "  ${BOLD}$target${OFF}  $count resources"
    TO_RUN+=("$target:destroy")
  fi
done

if [[ ${#TO_RUN[@]} -eq 0 ]]; then
  ok "nothing to do"
  exit 0
fi

if ! $DRY_RUN && ! $ASSUME_YES; then
  printf '\n%sThis permanently deletes the infrastructure above.%s\n' "$RED$BOLD" "$OFF"
  $SWEEP && printf '%s--sweep is on: leftovers matching "%s" will be deleted too.%s\n' "$RED" "$PREFIX" "$OFF"
  printf 'Type %sdestroy%s to continue: ' "$BOLD" "$OFF"
  read -r reply
  [[ "$reply" == "destroy" ]] || { say "aborted"; exit 1; }
fi

FAILED=()
for entry in "${TO_RUN[@]}"; do
  target="${entry%%:*}"
  mode="${entry##*:}"

  if [[ "$mode" == "destroy" ]]; then
    if ! "destroy_$target"; then
      bad "$target: terraform destroy did not finish"
      FAILED+=("$target")
    fi
  fi

  # The sweep only reads unless --sweep, so it is safe in a dry run too.
  "sweep_$target" || true
done

if $DRY_RUN; then
  step "Dry run -- nothing was deleted"
  exit 0
fi

step "Done"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  bad "these did not destroy cleanly: ${FAILED[*]}"
  say "Re-run to retry. If Terraform is stuck on a resource that is already gone,"
  say "drop it from state with: terraform -chdir=<cloud>/site/terraform state rm <address>"
  exit 1
fi
ok "all destroyed"
say "${DIM}Local leftovers, safe to delete by hand: */site/terraform/terraform.tfstate*, */ingestion/.build/, */test/.runs/${OFF}"

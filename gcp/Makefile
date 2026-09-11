# Test-site + ingestion pipeline. Run `make` for the list.
TF      := terraform -chdir=site/terraform
# Defaults to your active gcloud project; override with PROJECT=<id>.
PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
REGION  ?= us-central1
N       ?= 40
SEED    ?=
KIND    ?=
ONLY    ?=
TOKEN   ?=
DOMAIN  ?= example.com
INGEST_URL ?= https://analytics-staging.obsero.ai/v1/events

# Terraform's google provider wants Application Default Credentials. Handing it
# a token from the active gcloud login avoids a second, separate browser login
# just to run apply. `gcloud auth application-default login` also works.
GOOGLE_OAUTH_ACCESS_TOKEN ?= $(shell gcloud auth print-access-token 2>/dev/null)
export GOOGLE_OAUTH_ACCESS_TOKEN

.DEFAULT_GOAL := help

## help: show this list
help:
	@echo "Obsero GCP ingestion - dev tasks\n"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  make /' | column -t -s ':'
	@echo "\n  vars: N=<count> SEED=<n> KIND=<kind> ONLY=<persona,...>\n"

## test: check the adapter payload against the Obsero contract (no GCP needed)
test:
	@node --test test/adapter.test.mjs

## event: POST one hand-made event to Obsero, to check the token (TOKEN= DOMAIN=)
event:
	@node ../obsero.mjs --token "$(TOKEN)" --domain "$(DOMAIN)" --url "$(INGEST_URL)"

## init: download providers for the test site
init:
	$(TF) init -input=false

## plan: preview infrastructure changes
plan:
	$(TF) plan

## site: apply only the site + LB + header logging (phase 1-2, no log routing)
site:
	$(TF) apply -auto-approve \
	  -target=google_compute_global_forwarding_rule.site \
	  -target=google_cloud_run_v2_service_iam_member.public \
	  -target=module.ingestion.terraform_data.request_logging

## deploy: apply the test site and the whole ingestion pipeline
deploy:
	$(TF) apply -auto-approve

## url: print the deployed site URL
url:
	@$(TF) output -raw site_url && echo

## headers: show the header allow-list the load balancer is logging
headers:
	@gcloud compute backend-services describe $$($(TF) output -raw backend_service) \
	  --global --project=$(PROJECT) --format="yaml(logConfig)"

## sample: print the newest raw log entry, to confirm headers are arriving
sample:
	@gcloud logging read \
	  'resource.type="http_load_balancer" AND resource.labels.backend_service_name="'$$($(TF) output -raw backend_service)'"' \
	  --project=$(PROJECT) --limit=1 --freshness=1h --format=json

## traffic: send mock agent/browser traffic (N=40)
traffic:
	@node test/mock-traffic.mjs -n $(N) \
	  $(if $(SEED),--seed $(SEED),) $(if $(KIND),--kind $(KIND),) $(if $(ONLY),--only $(ONLY),)

## check: score the last traffic run against what reached the endpoint
check:
	@node test/check-ingest.mjs --project $(PROJECT) --region $(REGION)

## personas: list the client personas the harness can impersonate
personas:
	@node test/mock-traffic.mjs --list

## e2e: deploy, send traffic, wait for log delivery, then score it
e2e: deploy
	@node test/mock-traffic.mjs -n $(N)
	@echo "waiting 60s for log delivery..."
	@sleep 60
	@node test/check-ingest.mjs --project $(PROJECT) --region $(REGION)

## logs: recent adapter output
logs:
	@gcloud logging read \
	  'resource.type="cloud_run_revision" AND resource.labels.service_name="'$$($(TF) output -raw adapter_service)'"' \
	  --project=$(PROJECT) --limit=50 --freshness=15m \
	  --format='value(timestamp,jsonPayload.message,textPayload)'

## failures: peek at messages the adapter never accepted
failures:
	@gcloud pubsub subscriptions pull $$($(TF) output -raw dead_letter_subscription) \
	  --project=$(PROJECT) --limit=10 --format=json || echo "(none)"

## fmt: format all terraform
fmt:
	@terraform fmt -recursive .

## validate: validate the module and the test site
validate:
	@terraform -chdir=ingestion init -backend=false -input=false >/dev/null && terraform -chdir=ingestion validate
	@$(TF) validate

## destroy: tear down everything (the load balancer bills at idle -- do this)
destroy:
	@../destroy.sh gcp

## leftovers: list cloud resources still around, deleting nothing
leftovers:
	@../destroy.sh gcp --check

.PHONY: help test event leftovers init plan site deploy url headers sample traffic check personas e2e logs failures fmt validate destroy

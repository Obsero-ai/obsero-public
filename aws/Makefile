# Test-site + ingestion pipeline. Run `make` for the list.
TF      := terraform -chdir=site/terraform
N       ?= 40
SEED    ?=
KIND    ?=
ONLY    ?=
TOKEN   ?=
DOMAIN  ?= example.com
INGEST_URL ?= https://analytics-staging.obsero.ai/v1/events

.DEFAULT_GOAL := help

## help: show this list
help:
	@echo "Obsero AWS ingestion - dev tasks\n"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  make /' | column -t -s ':'
	@echo "\n  vars: N=<count> SEED=<n> KIND=<kind> ONLY=<persona,...>\n"

## test: check the adapter payload against the Obsero contract (no AWS needed)
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

## deploy: apply the test site and the ingestion pipeline
deploy:
	$(TF) apply -auto-approve

## url: print the deployed site URL
url:
	@$(TF) output -raw site_url && echo

## traffic: send mock agent/browser traffic (N=40)
traffic:
	@node test/mock-traffic.mjs -n $(N) \
	  $(if $(SEED),--seed $(SEED),) $(if $(KIND),--kind $(KIND),) $(if $(ONLY),--only $(ONLY),)

## check: score the last traffic run against what reached the endpoint
check:
	@node test/check-ingest.mjs

## personas: list the client personas the harness can impersonate
personas:
	@node test/mock-traffic.mjs --list

## e2e: deploy, send traffic, wait for the buffer, then score it
e2e: deploy
	@node test/mock-traffic.mjs -n $(N)
	@echo "waiting 90s for the CloudFront flush + Firehose buffer..."
	@sleep 90
	@node test/check-ingest.mjs

## logs: follow the adapter Lambda as it forwards
logs:
	@aws logs tail $$($(TF) output -raw adapter_log_group) --follow --format short

## failures: list batches the endpoint never accepted
failures:
	@aws s3 ls s3://$$($(TF) output -raw backup_bucket)/ --recursive || echo "(none)"

## fmt: format all terraform
fmt:
	@terraform fmt -recursive .

## validate: validate the module and the test site
validate:
	@terraform -chdir=ingestion init -backend=false -input=false >/dev/null && terraform -chdir=ingestion validate
	@$(TF) validate

## destroy: tear down the demo site and the pipeline
destroy:
	@../destroy.sh aws

## leftovers: list cloud resources still around, deleting nothing
leftovers:
	@../destroy.sh aws --check

.PHONY: help test event leftovers init plan deploy url traffic check personas e2e logs failures fmt validate destroy

# GCP permissions

What the identity running `terraform apply` needs. **`roles/editor` alone is
not enough** — it deliberately excludes log-routing configuration and
resource-level `setIamPolicy`, which are the core of this pipeline.

## Roles

| Role | For |
|---|---|
| `roles/editor` | load balancer, CDN, backend services, NEGs, Pub/Sub topics and subscriptions, Artifact Registry |
| `roles/logging.configWriter` | the Log Router sink, and the `_Default` exclusion that stops you paying to store logs you already routed |
| `roles/pubsub.admin` | `pubsub.topics.setIamPolicy`, to grant the sink's writer identity publisher on the topic |
| `roles/run.admin` | deploying the adapter and setting its invoker policy |
| `roles/iam.serviceAccountAdmin` | the two service accounts the module creates |

Two of those are easy to get wrong:

- **`roles/pubsub.editor` does not cover `pubsub.topics.setIamPolicy`.** It has
  to be `roles/pubsub.admin`. Without it the sink is created but silently
  publishes nothing.
- **`roles/logging.configWriter` is not implied by Editor.** Without it
  `terraform apply` fails at the sink.

```bash
PROJECT=your-project
MEMBER=user:you@example.com

for ROLE in logging.configWriter pubsub.admin run.admin iam.serviceAccountAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="$MEMBER" --role="roles/$ROLE"
done
```

If you cannot get `roles/pubsub.admin`, and you hold
`resourcemanager.projects.setIamPolicy`, you can grant the sink's writer
identity `roles/pubsub.publisher` at the **project** level instead of the topic
level. Functionally identical for a single-topic project, just less
least-privilege — fine for a test rig, not what you want in a customer's
project.

## APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  run.googleapis.com \
  pubsub.googleapis.com \
  logging.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  --project="$PROJECT"
```

## Checking before you apply

`testIamPermissions` answers this directly, rather than inferring from role
names. Note there is no `gcloud projects test-iam-permissions` subcommand — the
REST call is the way:

```bash
curl -s -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"permissions":[
        "logging.sinks.create","logging.sinks.update",
        "logging.exclusions.create","logging.buckets.update",
        "pubsub.topics.setIamPolicy"
      ]}' \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT:testIamPermissions"
```

An empty `permissions` array back means none are granted; all five listed means
you are unblocked.

## Org policy

Only project-level IAM is visible from here. Org-level constraints surface at
apply time. The two most likely to bite:

- a constraint blocking external HTTP(S) load balancers
- `constraints/iam.disableServiceAccountKeyCreation`

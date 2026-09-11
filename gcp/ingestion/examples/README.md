# Examples

| Example | Shape |
|---|---|
| `existing-backend-service/` | You already run a load balancer; attach the pipeline to it. |

The test rig in `../../site/terraform` is the third shape: it creates the
backend service and the pipeline together, and is the reference integration
under test.

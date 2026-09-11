# Examples

- **existing-distribution/** — attach the pipeline to a distribution Terraform
  already manages. One module block, one ARN on the cache behaviour.

If your distribution is **not** managed by Terraform, apply the module on its
own and attach the ARN by hand:

```bash
terraform apply                                  # prints realtime_log_config_arn
aws cloudfront get-distribution-config --id EXXXX > dist.json
# set DefaultCacheBehavior.RealtimeLogConfigArn to that ARN, then:
aws cloudfront update-distribution --id EXXXX \
  --distribution-config file://config.json --if-match <ETag>
```

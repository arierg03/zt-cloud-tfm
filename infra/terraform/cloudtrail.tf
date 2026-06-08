data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  cloudtrail_name = "${var.project_name}-zt-audit-trail"
  cloudtrail_arn  = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"
}

resource "aws_cloudtrail" "zt_audit" {
  name                          = local.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = merge(local.common_tags, {
    Name = local.cloudtrail_name
  })

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs
  ]
}

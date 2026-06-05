resource "aws_s3_bucket" "images" {
  bucket = "events-images-296368270177-eu-south-2-an"

  tags = merge(local.common_tags, {
    Name = "events-images-296368270177-eu-south-2-an"
  })
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = false
  }
}

resource "aws_s3_bucket" "k8s_artifacts" {
  bucket = "tfm-app-k8s-artifacts-296368270177-eu-south-2"

  tags = merge(local.common_tags, {
    Name = "tfm-app-k8s-artifacts-296368270177-eu-south-2"
  })
}

resource "aws_s3_bucket_public_access_block" "k8s_artifacts" {
  bucket = aws_s3_bucket.k8s_artifacts.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "k8s_artifacts" {
  bucket = aws_s3_bucket.k8s_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = false
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "k8s_artifacts" {
  bucket = aws_s3_bucket.k8s_artifacts.id

  rule {
    id     = "expire-k8s-artifacts"
    status = "Enabled"

    filter {
      prefix = "manifests/"
    }

    expiration {
      days = 7
    }
  }
}

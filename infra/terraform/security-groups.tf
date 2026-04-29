resource "aws_security_group" "rds" {
  name        = "tfm-app-rds-sg"
  description = "Created by RDS management console"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "tfm-app-rds-sg"
  })
}
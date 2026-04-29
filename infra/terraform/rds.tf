resource "aws_db_subnet_group" "rds" {
  count = var.create_rds ? 1 : 0

  name        = "tfm-app-rds-subnet-group"
  description = "Subnet group for TFM app RDS"

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-rds-subnet-group"
  })
}

resource "aws_db_instance" "rds" {
  count = var.create_rds ? 1 : 0

  identifier = "tfm-app-rds"

  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.rds[0].name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  multi_az            = false

  backup_retention_period = 0
  deletion_protection     = false
  skip_final_snapshot     = true

  tags = merge(local.common_tags, {
    Name = "tfm-app-rds"
  })
}
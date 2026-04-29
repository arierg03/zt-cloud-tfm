resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "tfm-app-vpc"
  })
}

resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/20"
  availability_zone = "eu-south-2a"

  tags = merge(local.common_tags, {
    Name = "tfm-app-subnet-public1-eu-south-2a"
  })
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.16.0/20"
  availability_zone = "eu-south-2b"

  tags = merge(local.common_tags, {
    Name = "tfm-app-subnet-public2-eu-south-2b"
  })
}

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.128.0/20"
  availability_zone = "eu-south-2a"

  tags = merge(local.common_tags, {
    Name = "tfm-app-subnet-private1-eu-south-2a"
  })
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.144.0/20"
  availability_zone = "eu-south-2b"

  tags = merge(local.common_tags, {
    Name = "tfm-app-subnet-private2-eu-south-2b"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "tfm-app-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "tfm-app-rtb-public"
  })
}

resource "aws_route_table" "private_1" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "tfm-app-rtb-private1-eu-south-2a"
  })
}

resource "aws_route_table" "private_2" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "tfm-app-rtb-private2-eu-south-2b"
  })
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_1.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_2.id
}

resource "aws_eip" "nat" {
  count = var.create_nat ? 1 : 0

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "tfm-app-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  count = var.create_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public_1.id

  tags = merge(local.common_tags, {
    Name = "tfm-app-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "private_1_nat" {
  count = var.create_nat ? 1 : 0

  route_table_id         = aws_route_table.private_1.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route" "private_2_nat" {
  count = var.create_nat ? 1 : 0

  route_table_id         = aws_route_table.private_2.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private_1.id,
    aws_route_table.private_2.id
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-s3-vpce"
  })
}
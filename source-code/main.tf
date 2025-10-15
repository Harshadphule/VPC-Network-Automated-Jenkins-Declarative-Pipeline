# ---------------- VPC ----------------
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "Main-VPC"
  }
}

# ---------------- Subnets ----------------
resource "aws_subnet" "Public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags = {
    Name = "Public"
  }
}

resource "aws_subnet" "Private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone
  tags = {
    Name = "Private"
  }
}

# ---------------- Internet Gateway ----------------
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "IGW"
  }
}

# ---------------- NAT Gateway ----------------
resource "aws_eip" "nat_eip" {}

resource "aws_nat_gateway" "NAT" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.Public.id
  tags = {
    Name = "gw NAT"
  }
  depends_on = [aws_internet_gateway.gw]
}

# ---------------- Route Tables ----------------
resource "aws_route_table" "MRT" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "MRT"
  }
}

resource "aws_route_table" "CRT" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.NAT.id
  }

  tags = {
    Name = "CRT"
  }
}

# ---------------- Route Table Associations ----------------
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.Public.id
  route_table_id = aws_route_table.MRT.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.Private.id
  route_table_id = aws_route_table.CRT.id
}
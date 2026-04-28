output "vpc_id" {
  description = "ID de la VPC principal"
  value       = aws_vpc.main.id
}
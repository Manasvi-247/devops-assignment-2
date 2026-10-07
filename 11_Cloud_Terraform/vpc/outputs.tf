output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of every public subnet"
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "AZs the subnets landed in"
  value       = aws_subnet.public[*].availability_zone
}

output "security_group_id" {
  description = "ID of the web security group"
  value       = aws_security_group.web.id
}

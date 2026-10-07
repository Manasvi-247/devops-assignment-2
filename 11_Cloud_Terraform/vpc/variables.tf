variable "aws_region" {
  description = "Region to build the network in"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Prefix for every resource name"
  type        = string
  default     = "devops-course"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One CIDR per availability zone"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "allowed_http_cidr" {
  description = "Who may reach port 80"
  type        = string
  default     = "0.0.0.0/0"
}

variable "use_localstack" {
  description = "Target a local LocalStack container instead of real AWS"
  type        = bool
  default     = true
}

variable "localstack_endpoint" {
  description = "Where LocalStack is listening"
  type        = string
  default     = "http://localhost:4566"
}

variable "instance_type" {
  description = "Size of the web instance"
  type        = string
  default     = "t3.micro"
}

variable "assets_bucket" {
  description = "Globally unique bucket name for static assets"
  type        = string
  default     = "devops-course-24bcs10406-assets"
}

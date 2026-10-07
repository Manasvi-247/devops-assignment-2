variable "aws_region" {
  description = "Region to create the bucket in"
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "Globally unique bucket name"
  type        = string
  default     = "devops-course-24bcs10406-demo"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev"
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

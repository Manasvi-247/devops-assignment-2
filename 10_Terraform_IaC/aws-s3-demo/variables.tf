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

variable "project_name" {
  description = "Name used in generated file names"
  type        = string
  default     = "devops-lab"
}

variable "environment" {
  description = "Environment this configuration represents"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "instance_count" {
  description = "How many config files to generate"
  type        = number
  default     = 3
}

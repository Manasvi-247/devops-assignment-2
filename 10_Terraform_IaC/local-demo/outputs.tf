output "cluster_name" {
  description = "Generated cluster identifier"
  value       = "${var.project_name}-${var.environment}-${random_pet.suffix.id}"
}

output "config_files" {
  description = "Paths of every generated config file"
  value       = local_file.node_config[*].filename
}

output "api_key" {
  description = "Generated API key"
  value       = random_password.api_key.result
  sensitive   = true
}

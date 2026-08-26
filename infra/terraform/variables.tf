variable "aws_region" {
  description = "AWS region to deploy the pilot into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to prefix and tag all resources."
  type        = string
  default     = "warehouse"
}

variable "environment" {
  description = "Deployment environment name (e.g. pilot, staging, prod)."
  type        = string
  default     = "pilot"
}

variable "vpc_id" {
  description = "VPC to deploy the Fargate service and RDS instance into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Fargate service and RDS instance."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the load balancer."
  type        = list(string)
}

variable "container_image" {
  description = "Container image URI for the umbrella app (ingestion + warehouse_web) release."
  type        = string
}

variable "container_port" {
  description = "Port the Phoenix endpoint listens on inside the container."
  type        = number
  default     = 4000
}

variable "fargate_cpu" {
  description = "Fargate task CPU units (single pilot task)."
  type        = number
  default     = 512
}

variable "fargate_memory" {
  description = "Fargate task memory in MiB (single pilot task)."
  type        = number
  default     = 1024
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "warehouse"
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
  default     = "warehouse_app"
}

variable "db_password" {
  description = "PostgreSQL master password. Supply via a secure variable source, not source control."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class for the pilot database."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "domain_name" {
  description = "Domain name to issue the ACM certificate for (e.g. warehouse.example.com)."
  type        = string
}

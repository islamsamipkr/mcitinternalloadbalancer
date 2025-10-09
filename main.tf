# Terraform & Provider Configuration
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.10.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  credentials=var.credentials
}

# --- Input Variables ---
variable "project_id" {
  description = "uclodia-424702"
  type        = string
  default="uclodia-424702"
}
variable "credentials" {
  description = "Service account JSON"
  type        = string
  sensitive   = true
}


variable "region" {
  description = "The GCP region for all resources."
  type        = string
  default     = "us-central1"
}

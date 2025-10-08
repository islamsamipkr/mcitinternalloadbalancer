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
}

# --- Input Variables ---
variable "project_id" {
  description = "uclodia-424702"
  type        = string
default="uclodia-424702"
}

variable "region" {
  description = "The GCP region for all resources."
  type        = string
  default     = "us-central1"
}

# --- 1. Enable Required APIs ---
# This ensures all necessary services are active before creating resources.
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "vpcaccess.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com"
  ])
  service            = each.key
  disable_on_destroy = false
}

# --- 2. VPC Network and Subnets ---
resource "google_compute_network" "vpc" {
  name                    = "my-internal-app-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

# Subnet for the Serverless VPC Connector
resource "google_compute_subnetwork" "connector_subnet" {
  name          = "connector-subnet"
  ip_cidr_range = "10.8.0.0/28" # A /28 CIDR is required
  network       = google_compute_network.vpc.id
  region        = var.region
}

# Subnet for the Internal Load Balancer's proxy
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "proxy-subnet"
  purpose       = "REGIONAL_MANAGED_PROXY" # This purpose is required for the ILB
  role          = "ACTIVE"
  ip_cidr_range = "10.1.2.0/24"
  network       = google_compute_network.vpc.id
  region        = var.region
}

# --- 3. Serverless VPC Access Connector ---
# Creates a bridge between your serverless app and your VPC.
resource "google_vpc_access_connector" "connector" {
  name          = "serverless-connector"
  network       = google_compute_network.vpc.id
  ip_cidr_range = google_compute_subnetwork.connector_subnet.ip_cidr_range
  region        = var.region
  depends_on    = [google_project_service.apis]
}

# --- 4. Cloud Run Service ---
# Deploys a sample "hello" Cloud Run service connected to the VPC.
resource "google_cloud_run_v2_service" "default" {
  name     = "cloud-run-service"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" # Restricts traffic to the ILB

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
    }
    # Link Cloud Run to the VPC Connector for egress traffic
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "ALL_TRAFFIC"
    }
  }
  depends_on = [google_vpc_access_connector.connector]
}

# --- 5. Internal Load Balancer Components ---

# Serverless Network Endpoint Group (NEG) pointing to the Cloud Run service
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "cr-serverless-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_v2_service.default.name
  }
  depends_on = [google_cloud_run_v2_service.default]
}

# Health Check for the backend service
resource "google_compute_region_health_check" "default" {
  name   = "serverless-health-check"
  region = var.region
  http_health_check {
    port = 8080 # Default port for the sample Cloud Run container
  }
}

# Backend Service that connects the NEG and Health Check
resource "google_compute_region_backend_service" "default" {
  name                  = "serverless-backend-service"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "HTTP"
  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }
  health_checks = [google_compute_region_health_check.default.id]
}

# URL Map to route all traffic to the backend service
resource "google_compute_region_url_map" "default" {
  name            = "ilb-url-map"
  region          = var.region
  default_service = google_compute_region_backend_service.default.id
}

# HTTP Proxy that uses the URL map
resource "google_compute_region_target_http_proxy" "default" {
  name    = "ilb-http-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.default.id
}

# Forwarding Rule (the ILB's frontend IP address)
resource "google_compute_forwarding_rule" "default" {
  name                  = "ilb-forwarding-rule"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.proxy_subnet.id
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  allow_global_access   = true # Allows access from any region within the VPC
}

# --- 6. Firewall Rule for Health Checks ---
# Allows GCP's health checkers to reach the load balancer.
resource "google_compute_firewall" "allow_health_checks" {
  name    = "fw-allow-health-checks"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["8080"] # Must match the health check port
  }
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"] # Official GCP health checker IPs
}

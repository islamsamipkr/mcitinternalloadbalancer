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
  project     = var.project_id
  region      = var.region
  credentials = var.credentials
}

# --- Input Variables ---
variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "uclodia-424702"
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

# --- 1. Enable Required APIs ---
resource "google_project_service" "apis" {
  project = var.project_id
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
  ip_cidr_range = "10.8.0.0/28" # /28 is valid for connectors
  network       = google_compute_network.vpc.name
  region        = var.region
}

# Proxy-only subnet for Internal L7 LB
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "proxy-subnet"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
  ip_cidr_range = "10.1.2.0/28" # /28 is enough
  network       = google_compute_network.vpc.name
  region        = var.region
}

# --- 3. Serverless VPC Access Connector ---
resource "google_vpc_access_connector" "connector" {
  project = var.project_id
  name    = "serverless-conn"
  region  = var.region
  # network = google_compute_network.vpc.name   # <-- REMOVE this line

  # choose ONE scaling mode; instance-based here:
  min_instances = 2
  max_instances = 3

  subnet {
    name    = google_compute_subnetwork.connector_subnet.name
    project = var.project_id
  }

  depends_on = [google_project_service.apis]
}
# --- 4. Cloud Run Service ---
resource "google_cloud_run_v2_service" "default" {
  name     = "cloud-run-service"
  location = var.region

  # Valid values: INGRESS_TRAFFIC_ALL, INGRESS_TRAFFIC_INTERNAL_ONLY,
  # INGRESS_TRAFFIC_INTERNAL_AND_CLOUD_LOAD_BALANCING
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"  # for an internal ILB
  # (If you also plan to front with an external ALB, use
  #  INGRESS_TRAFFIC_INTERNAL_AND_CLOUD_LOAD_BALANCING)

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
    }
    # Only needed if your service makes egress calls into the VPC
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "ALL_TRAFFIC"
    }
  }

  depends_on = [google_vpc_access_connector.connector]
}

# --- 5. Internal Load Balancer Components ---

# Serverless NEG pointing to the Cloud Run service
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "cr-serverless-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_v2_service.default.name
  }
  depends_on = [google_cloud_run_v2_service.default]
}

# Backend Service (NO health checks for serverless NEGs)
resource "google_compute_region_backend_service" "default" {
  name                  = "serverless-backend-service"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }
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

# Forwarding Rule (ILB frontend IP)
resource "google_compute_forwarding_rule" "default" {
  name                  = "ilb-forwarding-rule"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = google_compute_network.vpc.name
  subnetwork            = google_compute_subnetwork.proxy_subnet.name
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  allow_global_access   = true
}

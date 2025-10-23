# ─────────────────────────────────────────────────────────────────────────────
# GCP Internal Application Load Balancer (Regional HTTP/HTTPS) — Terraform Module
#
# Files in this single document are separated by markers like:
#   // --- FILE: <path>
# Copy each block into that path in your repo.
# ─────────────────────────────────────────────────────────────────────────────

// --- FILE: modules/gcp-internal-alb/main.tf
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# Reserve a regional INTERNAL address (optional). If var.ip_address is provided,
# we create a static address; otherwise the forwarding rule will allocate ephemeral.
resource "google_compute_address" "ilb_ip" {
  count        = var.ip_address != null ? 1 : 0
  name         = var.ip_name
  project      = var.project_id
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  address      = var.ip_address
  purpose      = "GCE_ENDPOINT"
}

# Health check (regional) used by backend service
resource "google_compute_region_health_check" "this" {
  project = var.project_id
  region  = var.region
  name    = var.name

  dynamic "http_health_check" {
    for_each = var.health_check.protocol == "HTTP" ? [1] : []
    content {
      port               = var.health_check.port
      request_path       = var.health_check.request_path
      response           = var.health_check.response
      proxy_header       = var.health_check.proxy_header
      port_specification = var.health_check.port_specification
    }
  }

  dynamic "https_health_check" {
    for_each = var.health_check.protocol == "HTTPS" ? [1] : []
    content {
      port               = var.health_check.port
      request_path       = var.health_check.request_path
      response           = var.health_check.response
      proxy_header       = var.health_check.proxy_header
      port_specification = var.health_check.port_specification
    }
  }

  check_interval_sec  = var.health_check.check_interval_sec
  timeout_sec         = var.health_check.timeout_sec
  healthy_threshold   = var.health_check.healthy_threshold
  unhealthy_threshold = var.health_check.unhealthy_threshold
  log_config {
    enable = var.enable_logging
  }
}

# Backend service
resource "google_compute_region_backend_service" "this" {
  project        = var.project_id
  region         = var.region
  name           = var.name
  protocol       = var.enable_https ? "HTTPS" : "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  session_affinity     = var.session_affinity
  timeout_sec          = var.backend_timeout_sec

  health_checks = [google_compute_region_health_check.this.id]

  dynamic "backend" {
    for_each = var.backends
    content {
      group                 = backend.value.group
      balancing_mode        = try(backend.value.balancing_mode, null)
      capacity_scaler       = try(backend.value.capacity_scaler, null)
      max_connections       = try(backend.value.max_connections, null)
      max_connections_per_instance = try(backend.value.max_connections_per_instance, null)
      max_rate              = try(backend.value.max_rate, null)
      max_rate_per_instance = try(backend.value.max_rate_per_instance, null)
      max_utilization       = try(backend.value.max_utilization, null)
      failover              = try(backend.value.failover, null)
    }
  }

  log_config {
    enable = var.enable_logging
    sample_rate = var.log_sample_rate
  }
}

# URL Map (regional)
resource "google_compute_region_url_map" "this" {
  project = var.project_id
  region  = var.region
  name    = var.name

  default_service = google_compute_region_backend_service.this.id

  dynamic "host_rule" {
    for_each = var.host_rules
    content {
      hosts        = host_rule.value.hosts
      path_matcher = host_rule.value.path_matcher
    }
  }

  dynamic "path_matcher" {
    for_each = var.path_matchers
    content {
      name            = path_matcher.value.name
      default_service = try(path_matcher.value.default_service, google_compute_region_backend_service.this.id)

      dynamic "path_rule" {
        for_each = try(path_matcher.value.path_rules, [])
        content {
          paths   = path_rule.value.paths
          service = path_rule.value.service
        }
      }
    }
  }
}

# Target proxies (regional)
resource "google_compute_region_target_http_proxy" "http" {
  count   = var.enable_https ? 0 : 1
  project = var.project_id
  region  = var.region
  name    = var.name
  url_map = google_compute_region_url_map.this.id
}

resource "google_compute_region_ssl_certificate" "cert" {
  count        = var.enable_https ? 1 : 0
  project      = var.project_id
  region       = var.region
  name         = "${var.name}-cert"
  private_key  = var.tls_private_key
  certificate  = var.tls_certificate
}

resource "google_compute_region_target_https_proxy" "https" {
  count   = var.enable_https ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = var.name
  url_map = google_compute_region_url_map.this.id
  ssl_certificates = [
    google_compute_region_ssl_certificate.cert[0].self_link
  ]
}

# Forwarding rule (regional, INTERNAL_MANAGED)
resource "google_compute_forwarding_rule" "this" {
  project               = var.project_id
  region                = var.region
  name                  = var.name
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = var.network
  subnetwork            = var.subnetwork
  ip_protocol           = "TCP"
  is_mirroring_collector = false

  # Use static address if provided
  ip_address = var.ip_address != null ? google_compute_address.ilb_ip[0].address : null

  # Ports: 80 for HTTP, 443 for HTTPS
  ports  = var.enable_https ? ["443"] : ["80"]

  target = var.enable_https
    ? google_compute_region_target_https_proxy.https[0].self_link
    : google_compute_region_target_http_proxy.http[0].self_link
}

# --- FILE: modules/gcp-internal-alb/variables.tf
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Region for the ILB"
  type        = string
}

variable "network" {
  description = "Self link or name of the VPC network"
  type        = string
}

variable "subnetwork" {
  description = "Self link or name of the subnetwork (must be in region)"
  type        = string
}

variable "name" {
  description = "Base name used for all ILB resources"
  type        = string
}

variable "enable_https" {
  description = "If true, create HTTPS ILB; otherwise HTTP"
  type        = bool
  default     = false
}

variable "tls_certificate" {
  description = "PEM-encoded certificate chain for HTTPS (required if enable_https)"
  type        = string
  default     = null
}

variable "tls_private_key" {
  description = "PEM-encoded private key for HTTPS (required if enable_https)"
  type        = string
  default     = null
  sensitive   = true
}

variable "ip_name" {
  description = "Name for the static internal IP (used only if ip_address is set)"
  type        = string
  default     = null
}

variable "ip_address" {
  description = "Optional fixed internal IP to reserve; leave null for ephemeral"
  type        = string
  default     = null
}

variable "health_check" {
  description = "Health check configuration"
  type = object({
    protocol            = string         # "HTTP" or "HTTPS"
    port                = number
    request_path        = optional(string, "/healthz")
    response            = optional(string)
    proxy_header        = optional(string, "NONE")
    port_specification  = optional(string, "USE_FIXED_PORT")
    check_interval_sec  = optional(number, 5)
    timeout_sec         = optional(number, 5)
    healthy_threshold   = optional(number, 2)
    unhealthy_threshold = optional(number, 2)
  })
  default = {
    protocol = "HTTP"
    port     = 80
  }
}

variable "enable_logging" {
  description = "Enable logging on health check and backend service"
  type        = bool
  default     = true
}

variable "log_sample_rate" {
  description = "Sampling rate for load balancer logs (0.0 to 1.0)"
  type        = number
  default     = 1.0
}

variable "session_affinity" {
  description = "Session affinity setting for backend service"
  type        = string
  default     = "NONE" # Options: NONE, CLIENT_IP, CLIENT_IP_PORT_PROTO, CLIENT_IP_NO_DESTINATION
}

variable "backend_timeout_sec" {
  description = "Backend service timeout in seconds"
  type        = number
  default     = 30
}

variable "backends" {
  description = <<EOT
List of backend attachments. For Internal Managed HTTP(S), backends can be managed instance groups
or NEGs with GCE endpoints. Provide the self_link in `group`.
Example:
[
  {
    group            = google_compute_region_instance_group_manager.example.instance_group
    balancing_mode   = "UTILIZATION"
    capacity_scaler  = 1.0
    max_utilization  = 0.8
  }
]
EOT
  type = list(object({
    group                         = string
    balancing_mode                = optional(string)
    capacity_scaler               = optional(number)
    max_connections               = optional(number)
    max_connections_per_instance  = optional(number)
    max_rate                      = optional(number)
    max_rate_per_instance         = optional(number)
    max_utilization               = optional(number)
    failover                      = optional(bool)
  }))
}

variable "host_rules" {
  description = "Optional host rules for the URL map"
  type = list(object({
    hosts        = list(string)
    path_matcher = string
  }))
  default = []
}

variable "path_matchers" {
  description = "Optional path matchers and rules for the URL map"
  type = list(object({
    name            = string
    default_service = optional(string)
    path_rules = optional(list(object({
      paths   = list(string)
      service = string
    })))
  }))
  default = []
}

# --- FILE: modules/gcp-internal-alb/outputs.tf
output "forwarding_rule" {
  description = "Forwarding rule resource"
  value       = google_compute_forwarding_rule.this
}

output "address" {
  description = "Internal IP address used by the ILB"
  value       = coalesce(try(google_compute_address.ilb_ip[0].address, null), google_compute_forwarding_rule.this.ip_address)
}

output "backend_service" {
  description = "Regional backend service self_link"
  value       = google_compute_region_backend_service.this.self_link
}

output "url_map" {
  description = "Regional URL map self_link"
  value       = google_compute_region_url_map.this.self_link
}

# --- FILE: examples/basic-http/main.tf
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Example MIG and instance template omitted for brevity; assume you already have:
#   google_compute_region_instance_group_manager.app
# whose `instance_group` self_link you can reference.

module "ilb_http" {
  source     = "../../modules/gcp-internal-alb"
  project_id = var.project_id
  region     = var.region
  network    = var.network
  subnetwork = var.subnetwork
  name       = "my-internal-http"

  enable_https = false

  health_check = {
    protocol = "HTTP"
    port     = 8080
    request_path = "/healthz"
  }

  backends = [
    {
      group            = google_compute_region_instance_group_manager.app.instance_group
      balancing_mode   = "UTILIZATION"
      max_utilization  = 0.8
      capacity_scaler  = 1.0
    }
  ]
}

output "ilb_ip" { value = module.ilb_http.address }

# --- FILE: examples/basic-http/variables.tf
variable "project_id" { type = string }
variable "region"     { type = string }
variable "network"    { type = string }
variable "subnetwork" { type = string }

# --- FILE: examples/https-selfmanaged/main.tf
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "ilb_https" {
  source     = "../../modules/gcp-internal-alb"
  project_id = var.project_id
  region     = var.region
  network    = var.network
  subnetwork = var.subnetwork
  name       = "my-internal-https"

  enable_https   = true
  tls_certificate = file(var.cert_path)
  tls_private_key = file(var.key_path)

  # Optional: fixed IP
  ip_name    = "ilb-https-ip"
  ip_address = var.fixed_ip

  # Optional routing
  host_rules = [
    { hosts = ["app.internal.example.local"], path_matcher = "pm1" }
  ]
  path_matchers = [
    {
      name = "pm1"
      path_rules = [
        { paths = ["/api*"], service = google_compute_region_backend_service.api.self_link },
      ]
    }
  ]

  health_check = {
    protocol     = "HTTPS"
    port         = 8443
    request_path = "/status"
  }

  backends = [
    {
      group           = google_compute_region_instance_group_manager.app.instance_group
      balancing_mode  = "UTILIZATION"
      max_utilization = 0.8
    }
  ]
}

# --- FILE: examples/https-selfmanaged/variables.tf
variable "project_id" { type = string }
variable "region"     { type = string }
variable "network"    { type = string }
variable "subnetwork" { type = string }
variable "cert_path"  { type = string }
variable "key_path"   { type = string }
variable "fixed_ip"   { type = string, default = null }

// --- FILE: README.md
# GCP Internal Application Load Balancer (Regional HTTP/HTTPS)

This module provisions a **Regional Internal Managed HTTP(S) Load Balancer** for private services inside your VPC subnets. It supports HTTP or HTTPS (self‑managed certificates), path/host routing via URL maps, logging, and customizable backends (MIG or NEG self_links).

## Requirements
- Google provider `>= 5.0`
- VPC + regional subnetwork
- Backends: regional managed instance groups or NEGs with GCE endpoints
- For HTTPS, provide PEM `tls_certificate` and `tls_private_key` (managed certs are not supported for internal HTTPS at the time of writing)

## Inputs (highlights)
- `project_id`, `region`, `network`, `subnetwork`, `name`
- `enable_https` (bool), `tls_certificate`, `tls_private_key`
- `ip_address` (optional to reserve), `ip_name`
- `health_check` object (HTTP/HTTPS)
- `backends` list: `{ group = <self_link>, balancing_mode, ... }`
- Optional `host_rules`, `path_matchers`

## Outputs
- `address` – ILB internal IP
- `forwarding_rule`, `backend_service`, `url_map`

## Notes
- This is **Internal Managed** (regional) LB for L7 HTTP(S). Not to be confused with Internal TCP/UDP L4 LB.
- The forwarding rule is created on ports 80 or 443 depending on `enable_https`.
- Ensure firewall rules allow traffic from client subnets to backend VMs on your app ports and allow health checks (from Google Health Checker ranges in your region).

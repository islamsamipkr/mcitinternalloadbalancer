##Internal load balancer
terraform {


log_config {
enable = var.enable_logging
sample_rate = var.log_sample_rate
}
}


# URL Map (regional)
resource "google_compute_region_url_map" "this" {
project = var.project_id
region = var.region
name = var.name


default_service = google_compute_region_backend_service.this.id


dynamic "host_rule" {
for_each = var.host_rules
content {
hosts = host_rule.value.hosts
path_matcher = host_rule.value.path_matcher
}
}


dynamic "path_matcher" {
for_each = var.path_matchers
content {
name = path_matcher.value.name
default_service = try(path_matcher.value.default_service, google_compute_region_backend_service.this.id)


dynamic "path_rule" {
for_each = try(path_matcher.value.path_rules, [])
content {
paths = path_rule.value.paths
service = path_rule.value.service
}
}
}
}
}


# Target proxies (regional)
resource "google_compute_region_target_http_proxy" "http" {
count = var.enable_https ? 0 : 1
project = var.project_id
region = var.region
name = var.name
url_map = google_compute_region_url_map.this.id
}


resource "google_compute_region_ssl_certificate" "cert" {
count = var.enable_https ? 1 : 0
project = var.project_id
region = var.region
name = "${var.name}-cert"
private_key = var.tls_private_key
certificate = var.tls_certificate
}


resource "google_compute_region_target_https_proxy" "https" {
count = var.enable_https ? 1 : 0
project = var.project_id
region = var.region
name = var.name
url_map = google_compute_region_url_map.this.id
ssl_certificates = [
google_compute_region_ssl_certificate.cert[0].self_link
]
}


# Forwarding rule (regional, INTERNAL_MANAGED)
resource "google_compute_forwarding_rule" "this" {
project = var.project_id
region = var.region
name = var.name
load_balancing_scheme = "INTERNAL_MANAGED"
network = var.network
subnetwork = var.subnetwork
ip_protocol = "TCP"
is_mirroring_collector = false


# Use static address if provided
ip_address = var.ip_address != null ? google_compute_address.ilb_ip[0].address : null


# Ports: 80 for HTTP, 443 for HTTPS
ports = var.enable_https ? ["443"] : ["80"]


target = var.enable_https
? google_compute_region_target_https_proxy.https[0].self_link
: google_compute_region_target_http_proxy.http[0].self_link
}

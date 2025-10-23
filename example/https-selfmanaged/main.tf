terraform {
required_version = ">= 1.3.0"
required_providers {
google = {
source = "hashicorp/google"
version = ">= 5.0"
}
}
}


provider "google" {
project = var.project_id
region = var.region
}


module "ilb_https" {
source = "../../modules/gcp-internal-alb"
project_id = var.project_id
region = var.region
network = var.network
subnetwork = var.subnetwork
name = "my-internal-https"


enable_https = true
tls_certificate = file(var.cert_path)
tls_private_key = file(var.key_path)


# Optional: fixed IP
ip_name = "ilb-https-ip"
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
protocol = "HTTPS"
port = 8443
request_path = "/status"
}


backends = [
{
group = google_compute_region_instance_group_manager.app.instance_group
balancing_mode = "UTILIZATION"
max_utilization = 0.8
}
]
}

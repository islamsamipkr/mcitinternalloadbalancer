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


# Example MIG and instance template omitted for brevity; assume you already have:
# google_compute_region_instance_group_manager.app
# whose `instance_group` self_link you can reference.


module "ilb_http" {
source = "../../modules/gcp-internal-alb"
project_id = var.project_id
region = var.region
network = var.network
subnetwork = var.subnetwork
name = "my-internal-http"


enable_https = false


health_check = {
protocol = "HTTP"
port = 8080
request_path = "/healthz"
}


backends = [
{
group = google_compute_region_instance_group_manager.app.instance_group
balancing_mode = "UTILIZATION"
max_utilization = 0.8
capacity_scaler = 1.0
}
]
}


output "ilb_ip" { value = module.ilb_http.address }

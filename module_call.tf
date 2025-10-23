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

# Example backend — assume you already have a managed instance group
resource "google_compute_region_instance_group_manager" "app" {
  name               = "app-mig"
  base_instance_name = "app"
  region             = var.region
  version {
    instance_template = google_compute_instance_template.app.id
  }
  target_size = 2
}

resource "google_compute_instance_template" "app" {
  name         = "app-template"
  machine_type = "e2-medium"
  region       = var.region

  disk {
    auto_delete  = true
    boot         = true
    source_image = "debian-cloud/debian-11"
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
  }

  metadata_startup_script = <<EOT
    #!/bin/bash
    echo "Hello, Internal LB" > /var/www/html/index.html
    nohup busybox httpd -f -p 8080 &
  EOT
}

# Call the module
module "internal_alb" {
  source     = "../modules/gcp-internal-alb"
  project_id = var.project_id
  region     = var.region
  network    = var.network
  subnetwork = var.subnetwork
  name       = "my-internal-alb"

  enable_https = false

  health_check = {
    protocol     = "HTTP"
    port         = 8080
    request_path = "/"
  }

  backends = [
    {
      group           = google_compute_region_instance_group_manager.app.instance_group
      balancing_mode  = "UTILIZATION"
      max_utilization = 0.8
      capacity_scaler = 1.0
    }
  ]
}

output "ilb_ip" {
  value = module.internal_alb.address
}

output "forwarding_rule" {
description = "Forwarding rule resource"
value = google_compute_forwarding_rule.this
}


output "address" {
description = "Internal IP address used by the ILB"
value = coalesce(try(google_compute_address.ilb_ip[0].address, null), google_compute_forwarding_rule.this.ip_address)
}


output "backend_service" {
description = "Regional backend service self_link"
value = google_compute_region_backend_service.this.self_link
}


output "url_map" {
description = "Regional URL map self_link"
value = google_compute_region_url_map.this.self_link
}

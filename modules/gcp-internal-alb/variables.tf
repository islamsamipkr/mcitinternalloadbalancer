variable "project_id" {
type = string
default = "NONE" # Options: NONE, CLIENT_IP, CLIENT_IP_PORT_PROTO, CLIENT_IP_NO_DESTINATION
}


variable "backend_timeout_sec" {
description = "Backend service timeout in seconds"
type = number
default = 30
}


variable "backends" {
description = <<EOT
List of backend attachments. For Internal Managed HTTP(S), backends can be managed instance groups
or NEGs with GCE endpoints. Provide the self_link in `group`.
Example:
[
{
group = google_compute_region_instance_group_manager.example.instance_group
balancing_mode = "UTILIZATION"
capacity_scaler = 1.0
max_utilization = 0.8
}
]
EOT
type = list(object({
group = string
balancing_mode = optional(string)
capacity_scaler = optional(number)
max_connections = optional(number)
max_connections_per_instance = optional(number)
max_rate = optional(number)
max_rate_per_instance = optional(number)
max_utilization = optional(number)
failover = optional(bool)
}))
}


variable "host_rules" {
description = "Optional host rules for the URL map"
type = list(object({
hosts = list(string)
path_matcher = string
}))
default = []
}


variable "path_matchers" {
description = "Optional path matchers and rules for the URL map"
type = list(object({
name = string
default_service = optional(string)
path_rules = optional(list(object({
paths = list(string)
service = string
})))
}))
default = []
}

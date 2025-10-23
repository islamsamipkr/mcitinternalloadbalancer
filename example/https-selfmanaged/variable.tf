variable "project_id" { type = string }
variable "region" { type = string }
variable "network" { type = string }
variable "subnetwork" { type = string }
variable "cert_path" { type = string }
variable "key_path" { type = string }
variable "fixed_ip" { type = string, default = null }

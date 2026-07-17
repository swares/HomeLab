variable "pihole_url" {
  description = "Pi-hole admin URL (e.g. http://192.168.1.116)"
  type        = string
  default     = "http://192.168.1.116"
}

variable "pihole_password" {
  description = "Pi-hole admin password. Set via TF_VAR_pihole_password env var — do not commit."
  type        = string
  sensitive   = true
}

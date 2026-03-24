variable "kubeconfig_path" {
  default = "~/.kube/config"
}

variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "Droplet size"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 1
}

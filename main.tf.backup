# -----------------------------
# VERSIONS
# -----------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = ">= 2.29.0"
    }
  }
}

# - output 
output "droplet_ips" {
  description = "Public IPv4 addresses of all droplets"
  value       = [for d in digitalocean_droplet.k8s_nodes : d.ipv4_address]
}

# -----------------------------
# PROVIDERS
# -----------------------------
provider "digitalocean" {
  token = var.do_token
}

# -----------------------------
# SSH KEY
# -----------------------------
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "id_rsa_k8s_do"
  file_permission = "0600"
}

resource "digitalocean_ssh_key" "k8s_ssh" {
  name       = "k8s-terraform-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# -----------------------------
# DROPLETS
# -----------------------------
resource "digitalocean_droplet" "k8s_nodes" {
  count              = 4
  name               = "k8s-${count.index == 0 ? "cp" : "w${count.index}"}"
  region             = var.region
  size               = var.droplet_size
  image              = "ubuntu-24-04-x64"
  ssh_keys           = [digitalocean_ssh_key.k8s_ssh.id]
  user_data          = file("cloud-init/setup-k8s-node.sh")
}

# -----------------------------
# PROJECT
# -----------------------------
resource "digitalocean_project" "k8s_project" {
  name        = "k8s-lab-${data.external.current_user.result["user"]}"
  description = "Self-managed Kubernetes cluster with Calico"
  purpose     = "Web Application"
  environment = "Development"
}

resource "digitalocean_project_resources" "project_binding" {
  project   = digitalocean_project.k8s_project.id
  resources = [for d in digitalocean_droplet.k8s_nodes : d.urn]
}

# -----------------------------
# Check for: 
# - ssh running
# - cloud-init boot completed
# -----------------------------

resource "null_resource" "wait_for_control_plane_ssh" {
  depends_on = [digitalocean_droplet.k8s_nodes]

  connection {
    type        = "ssh"
    user        = "root"
    host        = digitalocean_droplet.k8s_nodes[0].ipv4_address
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'SSH is up on control-plane: ${digitalocean_droplet.k8s_nodes[0].ipv4_address}'",
      "echo 'Waiting for cloud-init to finish...'",
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 5; done",
      "echo 'cloud-init done.'"
    ]
  }
}

# -----------------------------
# LOCAL EXEC JOIN SCRIPT
# -----------------------------
resource "null_resource" "run_join_script" {

  depends_on = [null_resource.wait_for_control_plane_ssh]
  provisioner "local-exec" {
    command = <<EOT
chmod +x ./scripts/join-workers.sh && ./scripts/join-workers.sh "${self.triggers.worker_ips}" "${join(",", [for droplet in digitalocean_droplet.k8s_nodes : droplet.ipv4_address_private])}"
EOT
  }
  # Trigger auf IPs – sobald die sich ändern, wird neu ausgeführt
  triggers = {
    worker_ips = join(",", [for droplet in digitalocean_droplet.k8s_nodes : droplet.ipv4_address])
  }

}

# -----------------------------
# DNS ENTRY (Wildcard pro Benutzer)
# Nutzt eine Datenquelle, um die IP des Ingress-Service aus dem Cluster abzurufen,
# nachdem dieser via Helm erstellt wurde. Damit wird die externe IP zuverlässig abgefragt.
# -----------------------------

#resource "digitalocean_record" "ingress_dns_wildcard_user" {
#  domain = "do.t3isp.de"
#  type   = "A"
#  name   = "*.${local.current_user}"
#  value  = data.kubernetes_service.ingress_svc.status.load_balancer.ingress[0].ip
#}



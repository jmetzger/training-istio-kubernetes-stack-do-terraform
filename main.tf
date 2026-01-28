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
# PRE-DESTROY CLEANUP HOOKS
# -----------------------------

# Layer 2: Helm Cleanup Hook (Kubernetes-Ebene)
resource "null_resource" "pre_destroy_helm_cleanup" {
  triggers = {
    control_plane_ip = digitalocean_droplet.k8s_nodes[0].ipv4_address
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
      echo "[1/3] Cleaning up Helm releases..."
      helm uninstall traefik -n ingress --wait --timeout 5m || true
      helm uninstall calico -n calico-system --wait --timeout 5m || true
      sleep 30
      echo "[1/3] Helm cleanup done."
    EOT

    on_failure = continue
  }
}

# Layer 3: LoadBalancer Cleanup Hook (Cloud-Ebene)
resource "null_resource" "pre_destroy_lb_cleanup" {
  depends_on = [null_resource.pre_destroy_helm_cleanup]

  triggers = {
    project_id = digitalocean_project.k8s_project.id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
      echo "[2/3] Cleaning up orphaned LoadBalancers..."

      # LoadBalancers mit Namen traefik/ingress löschen
      doctl compute load-balancer list --format ID,Name --no-header | \
        grep -E "(traefik|ingress)" | \
        awk '{print $1}' | \
        xargs -I {} sh -c 'echo "Deleting LB: {}" && doctl compute load-balancer delete {} --force' || true

      sleep 30
      echo "[2/3] LoadBalancer cleanup done."
    EOT

    on_failure = continue
  }
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

  # TIMEOUT CONFIGURATION - Layer 1
  timeouts {
    delete = "20m"  # Erhöht von Standard 10m auf 20m
  }

  # Dependencies: Warte auf Cleanup-Hooks vor Droplet-Löschung
  depends_on = [
    null_resource.pre_destroy_helm_cleanup,
    null_resource.pre_destroy_lb_cleanup
  ]
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

  # Project Resources werden VOR Droplets gelöscht
  lifecycle {
    create_before_destroy = false
  }
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



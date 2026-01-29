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
    command = <<-EOT
      export KUBECONFIG=/home/jmetzger/.kube/config

      echo "[Layer 2] Starting Helm Cleanup..."

      # Helm Releases auflisten und löschen
      if helm list -A -q 2>/dev/null | grep -q .; then
        echo "Found Helm releases, removing..."
        helm list -A -q | xargs -r -I {} sh -c 'NS=$(helm list -A | grep {} | awk "{print \$2}"); echo "Uninstalling {} from namespace $NS"; helm uninstall {} -n $NS --wait --timeout 5m' || true
      else
        echo "No Helm releases found"
      fi

      # Layer 4: Control Plane Stabilization Wait (90 Sekunden)
      echo "[Layer 4] Waiting 90 seconds for Control Plane stabilization..."
      sleep 90
      echo "[Layer 2 + 4] Helm cleanup and stabilization complete."
    EOT

    on_failure = continue
  }
}

# Layer 3: LoadBalancer Cleanup Hook (Cloud-Ebene)
resource "null_resource" "pre_destroy_lb_cleanup" {
  depends_on = [null_resource.pre_destroy_helm_cleanup]

  triggers = {
    do_token = var.do_token
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "[Layer 3] Starting LoadBalancer Cleanup..."

      # doctl installieren (falls nicht vorhanden)
      if ! command -v doctl &> /dev/null; then
        echo "Installing doctl..."
        cd /tmp
        wget -q https://github.com/digitalocean/doctl/releases/download/v1.115.0/doctl-1.115.0-linux-amd64.tar.gz
        tar xf doctl-*.tar.gz
        sudo mv doctl /usr/local/bin/
      fi

      # Authenticate
      doctl auth init --access-token ${self.triggers.do_token}

      # LoadBalancer prüfen und warten
      MAX_WAIT=120
      ELAPSED=0
      while [ $ELAPSED -lt $MAX_WAIT ]; do
        LB_COUNT=$(doctl compute load-balancer list --format ID --no-header 2>/dev/null | wc -l)
        if [ "$LB_COUNT" -eq 0 ]; then
          echo "All LoadBalancers deleted successfully"
          break
        fi
        echo "Waiting for $LB_COUNT LoadBalancer(s) to be deleted... ($ELAPSED/$MAX_WAIT seconds)"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
      done

      echo "[Layer 3] LoadBalancer cleanup complete."
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

  # Layer 1: TIMEOUT CONFIGURATION
  timeouts {
    delete = "20m"  # Erhöht von Standard 10m auf 20m
  }

  # WICHTIG: KEIN depends_on hier!
  # Die Abhängigkeit wird durch trigger in pre_destroy_helm_cleanup erzeugt
  # (trigger auf k8s_nodes[0].ipv4_address)
  # Ein depends_on hier würde Cycle Error verursachen
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

  # Layer 5: Project Resources Lifecycle
  lifecycle {
    prevent_destroy = false  # Erlaubt Terraform, Project Resources zu löschen
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



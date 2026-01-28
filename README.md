# DigitalOcean Kubernetes Setup mit Terraform & Calico Operator

Dieses Repository automatisiert den Aufbau eines selbstverwalteten Kubernetes-Clusters auf DigitalOcean mit:

- Terraform-Infrastruktur (VPC, Droplets, SSH Key, Helm, DNS)
- Kubernetes-Installation via Cloud-init + kubeadm
- Calico CNI via Tigera Operator
- MetalLB LoadBalancer mit L2 Propagation
- Traefik Ingress Controller
- Automatischer `kubeadm join` per SSH + kubeconfig Übergabe

---

## 🧰 Voraussetzungen

- DigitalOcean-Account + API Token (über Umgebungsvariable setzen mit `export TF_VAR_do_token="<your_token>"`)
- Domain wie `do.t3isp.de` in DigitalOcean DNS verwaltet
- `terraform`, `jq`, `ssh`, `scp` lokal installiert
- `helmfile` (optional, für cert-manager Deployment)
- SSH-Zugriff auf erzeugte Droplets (automatisch eingerichtet)

---

## 🚀 Schnellstart

> Alternativ kannst du dein API-Token auch in einer `.env`-Datei speichern und mit `source .env` laden:
>
> ```env
> export TF_VAR_do_token="<your_token>"
> ```

```bash
# DigitalOcean API Token als Umgebungsvariable setzen
export TF_VAR_do_token="<your_token>"
# Terraform initialisieren und Infrastruktur provisionieren
terraform init
terraform apply -auto-approve
```

Nach erfolgreicher Initialisierung wird die Kubernetes-Konfiguration (`admin.conf`) automatisch vom Control-Plane-Node kopiert und gespeichert als:

```bash
~/.kube/config
```

Falls das Verzeichnis `~/.kube` noch nicht existiert, wird es automatisch erstellt.

---

## 📁 Struktur

```
├── main.tf                 # Hauptlogik
├── variables.tf            # Eingabeparameter
├── outputs.tf              # Ausgaben
├── cloud-init/
│   └── setup-k8s-node.sh   # Cloud-init für Droplets
├── scripts/
│   └── join-workers.sh     # Initialisiert Cluster, joined Worker & kopiert kubeconfig
└── README.md
```

---

## ⚙️ Komponenten & Versionen

- Terraform: >= 1.4.0
- Kubernetes: `1.33.0-00` (Fallback: `1.32.3-00`)
- Calico: Tigera Operator (CRD-basiert)
- MetalLB: Helm Chart `0.13.12`
- Traefik: Helm Chart `38.0.2` (ohne CRDs)

---

## 📡 DNS Setup

Nach der Ingress-Installation werden automatisch A-Records erstellt:

> Hinweis: Der zweite Eintrag verwendet dynamisch den aktuell eingeloggten Benutzer (z. B. `tln1`) durch Auslesen von `$USER` oder `$USERNAME`.

- `*.tln1.do.t3isp.de → LoadBalancer IP` (wird automatisch anhand des angemeldeten Benutzers generiert)

---

## 🧪 Validierung

```bash
kubectl get nodes
kubectl get pods -A
kubectl get ipaddresspool -n metallb-system

# Traefik Ingress Controller prüfen
kubectl -n ingress get pods
kubectl -n ingress get svc
```

---

## 📦 Helmfile Deployment (cert-manager)

Nach dem erfolgreichen Terraform-Setup kann zusätzlich cert-manager über helmfile installiert werden.

### Was macht helmfile sync?

`helmfile sync` deployed alle in der `helmfile.yaml` definierten Helm Releases:
- **cert-manager** (Jetstack): Automatisiertes TLS-Zertifikatmanagement
- **cert-manager-config**: ClusterIssuer für Let's Encrypt (HTTP-01 Challenge)

### Wann sollte helmfile sync verwendet werden?

- **Initial**: Nach `terraform apply`, sobald der Cluster läuft
- **Updates**: Nach Änderungen an `helmfile.yaml` oder `charts/`
- **Reparatur**: Wenn cert-manager-Ressourcen fehlen oder inkonsistent sind

### Anwendung

```bash
# Voraussetzung: helmfile installiert (https://helmfile.readthedocs.io/)
# Deploye alle Releases
helmfile sync

# Nur bestimmtes Release deployen
helmfile -l name=cert-manager sync

# Dry-run (zeigt was passieren würde)
helmfile diff
```

### Was wird deployed?

```bash
# Nach helmfile sync prüfen
kubectl get pods -n cert-manager
kubectl get clusterissuer

# Erwartete Ausgabe:
# - cert-manager, cert-manager-webhook, cert-manager-cainjector Pods
# - ClusterIssuer: letsencrypt-prod
```

---

## ❗ Sicherheitshinweis

Der generierte private SSH-Key `id_rsa_k8s_do` wird lokal gespeichert. Bitte sicher verwahren und nicht ins Git einchecken:

```bash
.gitignore:
  id_rsa_k8s_do
  .terraform/
  terraform.tfstate*
```

---

## 🧼 Destroying the Infrastructure

### Prerequisites
- `TF_VAR_do_token` environment variable set (same as for `terraform apply`)
- `helm` and `kubectl` configured (for Helm cleanup)
- `doctl` will be auto-installed if not present

### Destroy Command
```bash
terraform destroy -auto-approve
```

### What Happens During Destroy

The destroy process uses a **5-layer cleanup solution** to prevent timeout errors:

#### Layer 1: Extended Timeout (20 minutes)
- Droplets have 20-minute delete timeout (increased from 10m default)
- Provides sufficient time for all cleanup operations

#### Layer 2: Helm Cleanup Hook (Pre-Destroy)
- Automatically detects and removes ALL Helm releases
- Dynamically determines namespaces for each release
- Executes BEFORE droplet deletion starts
- **Duration:** 1-3 minutes

#### Layer 3: LoadBalancer Cleanup Hook (Pre-Destroy)
- Auto-installs `doctl` if not present
- Authenticates with DigitalOcean API using `TF_VAR_do_token`
- Actively waits (up to 120s) until all LoadBalancers are deleted
- Prevents "Droplet already has a pending event" errors
- **Duration:** 1-2 minutes

#### Layer 4: Control Plane Stabilization Wait
- 90-second wait after Helm cleanup
- Gives Kubernetes time to process finalizers and propagate deletions
- Ensures LoadBalancers are fully deprovisioned on DigitalOcean

#### Layer 5: Project Resources Lifecycle
- Project resources automatically unbound before droplet deletion
- Clean dependency graph prevents errors

**Expected Total Duration:** 8-15 minutes (depending on number of resources)

### Destroy Sequence

```
terraform destroy
    ↓
Layer 2: Helm Cleanup (finds all releases, uninstalls)
    ↓
Layer 4: Wait 90s (Control Plane stabilization)
    ↓
Layer 3: LoadBalancer Cleanup (waits until all LBs deleted)
    ↓
Layer 1: Droplets deleted (with 20m timeout)
    ↓
Layer 5: Project resources cleaned up
    ↓
Complete ✅
```

### Troubleshooting Destroy

#### If destroy fails with timeout

1. **Check remaining resources:**
```bash
doctl compute droplet list | grep k8s-
doctl compute load-balancer list
```

2. **Manual cleanup:**
```bash
# Delete remaining LoadBalancers
doctl compute load-balancer delete <LB_ID> --force

# Delete remaining Droplets
doctl compute droplet delete <DROPLET_ID> --force
```

3. **Retry destroy:**
```bash
terraform destroy -auto-approve
```

#### If doctl is not found (should not happen - auto-installs)

```bash
# Arch Linux / Manjaro
sudo pacman -S doctl

# Ubuntu / Debian
snap install doctl

# macOS
brew install doctl

# Manual download (auto-install uses this)
cd /tmp
wget https://github.com/digitalocean/doctl/releases/download/v1.115.0/doctl-1.115.0-linux-amd64.tar.gz
tar xf doctl-*.tar.gz
sudo mv doctl /usr/local/bin/
```

#### Understanding the cleanup logs

During `terraform destroy`, you will see:
```
[Layer 2] Starting Helm Cleanup...
Found Helm releases, removing...
Uninstalling traefik from namespace ingress
Uninstalling cert-manager from namespace cert-manager
[Layer 4] Waiting 90 seconds for Control Plane stabilization...
[Layer 2 + 4] Helm cleanup and stabilization complete.

[Layer 3] Starting LoadBalancer Cleanup...
Waiting for 1 LoadBalancer(s) to be deleted... (0/120 seconds)
Waiting for 1 LoadBalancer(s) to be deleted... (10/120 seconds)
All LoadBalancers deleted successfully
[Layer 3] LoadBalancer cleanup complete.

digitalocean_droplet.k8s_nodes[0]: Destroying... [id=123456789]
...
```

### Manual Cleanup (Fallback)
```bash
# Remove local files
rm -f id_rsa_k8s_do id_rsa_k8s_do.pub
rm -f terraform.tfstate terraform.tfstate.backup

# Remove kubeconfig
rm -f ~/.kube/config
```

### Why This Solution?

Previous destroy attempts failed with:
```
Error: Error destroying droplet: DELETE https://api.digitalocean.com/v2/droplets/123456:
422 Droplet already has a pending event.
```

**Root Cause:**
- Kubernetes LoadBalancer Services (Traefik) block droplet deletion
- DigitalOcean API prevents droplet deletion while LoadBalancers exist
- Standard timeout (10m) was insufficient for full cleanup

**Solution:**
- Multi-layer approach ensures all dependencies are cleaned up sequentially
- Extended timeout provides buffer for slow operations
- Active waiting (Layer 3) ensures LoadBalancers are truly gone before droplet deletion

For full technical details, see `PRD.md`.


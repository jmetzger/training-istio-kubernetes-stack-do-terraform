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
- `doctl` CLI installed and authenticated
- `helm` and `kubectl` configured

### Destroy Command
```bash
terraform destroy -auto-approve
```

### What Happens During Destroy

1. **Helm Cleanup** (30-60s)
   - Traefik release uninstalled
   - Calico release uninstalled
   - LoadBalancer automatically deleted by Kubernetes

2. **LoadBalancer Cleanup** (30s)
   - Orphaned LoadBalancers removed via doctl
   - Safety net for Helm cleanup failures

3. **Droplet Deletion** (5-10m)
   - All 4 droplets deleted
   - SSH keys removed
   - Project resources unbound

4. **Project Cleanup** (10s)
   - DigitalOcean project deleted

**Expected Duration:** 8-12 minutes

### Troubleshooting Destroy

If destroy fails with timeout:
```bash
# Check remaining resources
doctl compute droplet list | grep k8s-
doctl compute load-balancer list

# Manual cleanup
doctl compute load-balancer delete <LB_ID> --force
doctl compute droplet delete <DROPLET_ID> --force

# Retry destroy
terraform destroy
```

### doctl Installation

```bash
# Arch Linux / Manjaro
sudo pacman -S doctl

# Ubuntu / Debian
snap install doctl

# macOS
brew install doctl

# Authentifizierung
doctl auth init
# Token eingeben: $TF_VAR_do_token
```

### Manual Cleanup (Fallback)
```bash
# Alle Ressourcen manuell entfernen
rm -f id_rsa_k8s_do id_rsa_k8s_do.pub
rm -f terraform.tfstate terraform.tfstate.backup
```


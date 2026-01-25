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

## ❗ Sicherheitshinweis

Der generierte private SSH-Key `id_rsa_k8s_do` wird lokal gespeichert. Bitte sicher verwahren und nicht ins Git einchecken:

```bash
.gitignore:
  id_rsa_k8s_do
  .terraform/
  terraform.tfstate*
```

---

## 🧼 Bereinigen

```bash
terraform destroy -auto-approve
rm -f id_rsa_k8s_do id_rsa_k8s_do.pub


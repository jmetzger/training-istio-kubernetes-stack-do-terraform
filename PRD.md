# Project Requirements Document: NFS CSI Storage Integration

## Projektstatus

**ABGESCHLOSSEN** - Alle Tasks implementiert und erfolgreich getestet (2026-02-18).

## Projektziel

Integration von NFS CSI Driver in den Kubernetes Cluster als Standard-StorageClass für persistenten Storage.

## Budget

DigitalOcean Budget: **EUR 100,-** (Freigabe erteilt)

## Test-Ausführung

Die Tests (Task 3) werden **automatisiert von Claude** durchgeführt. Das Budget für die dazu notwendige Infrastruktur (DigitalOcean Cluster) ist vom Nutzer freigegeben.

Claude hat direkten Zugriff auf den Cluster (verifizierbar mit `kubectl cluster-info`):

```
Kubernetes control plane is running at https://165.232.70.223:6443
CoreDNS is running at https://165.232.70.223:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

## Voraussetzungen / Kontext

- Kubernetes Cluster auf DigitalOcean via Terraform (existiert), Version: **1.35**
- NFS Server vorhanden: **Private IP 10.135.0.7**
- NFS Share: `/var/nfs`
- kubeconfig für Testcluster ist eingerichtet
- Bestehende Helmfile-Infrastruktur (helmfile.yaml) als Vorlage

---

## Offene Aufgaben

### Task 4: Kubernetes Version auf 1.35 anheben ⬜

**Ziel:** Alle Quellen im Repository auf Kubernetes **1.35** aktualisieren.

**Betroffene Dateien:**

| Datei | Aktueller Wert | Zielwert |
|-------|---------------|----------|
| `cloud-init/setup-k8s-node.sh` | `K8S_VERSION="v1.32"` | `K8S_VERSION="v1.35"` |
| `scripts/join-workers.sh` | `kubernetesVersion: "v1.32.0"` | `kubernetesVersion: "v1.35.0"` |
| `README.md` | `1.33.0-00` (Fallback: `1.32.3-00`) | `1.35.0-00` |

**Schritte:**
```bash
# 1. Dateien anpassen (siehe Tabelle oben)

# 2. Cluster neu aufbauen und verifizieren
terraform apply -auto-approve
kubectl version --short
```

**Erwartetes Ergebnis:**
- `kubectl version` zeigt Server-Version `v1.35.x`
- Alle Cloud-Init / Join-Skripte verwenden `v1.35`
- README gibt korrekte Installationsversion an

---

## Abgeschlossene Aufgaben (NFS CSI Integration)

### Task 1: helmfile-csi-nfs.yaml erstellen ✅ (2026-02-18)

**Ziel:** Separates Helmfile das den NFS CSI Driver und die StorageClass installiert.

**Inhalt:**
- Repository: `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts`
- Chart: `csi-driver-nfs/csi-driver-nfs`
- Version: neueste stabile Version (aktuell ca. v4.9.x, vor Implementierung prüfen)
- Namespace: `kube-system`
- Danach: Custom Chart `nfs-csi-storageclass` (aus `./charts/nfs-csi-storageclass`)

**Aufruf:**
```bash
helmfile -f helmfile-csi-nfs.yaml sync
```

**Abhängigkeit:** StorageClass-Release muss nach dem CSI Driver Release installiert werden (`needs:` Konfiguration).

---

### Task 2: Custom Helm Chart `charts/nfs-csi-storageclass` erstellen ✅ (2026-02-18)

**Ziel:** Chart installiert nur eine `StorageClass` die NFS CSI als **Default-StorageClass** setzt.

**Chart-Struktur:**
```
charts/nfs-csi-storageclass/
├── Chart.yaml
├── values.yaml
└── templates/
    └── storageclass.yaml
```

**StorageClass Vorlage:**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.135.0.7   # <-- konfigurierbar via values
  share: /var/nfs       # <-- konfigurierbar via values
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

**values.yaml (konfigurierbare Parameter):**
```yaml
nfs:
  server: "10.135.0.7"
  share: "/var/nfs"
```

---

### Task 3: Test auf Testcluster ✅ (2026-02-18)

**Ziel:** Verifizieren dass Installation funktioniert.

**Test-Schritte:**
```bash
# 1. Helmfile installieren
helmfile -f helmfile-csi-nfs.yaml sync

# 2. CSI Driver Pods prüfen
kubectl get pods -n kube-system | grep csi-nfs

# 3. StorageClass prüfen (nfs-csi sollte als default markiert sein)
kubectl get storageclass

# 4. Optional: Test PVC erstellen und prüfen ob Binding funktioniert
```

**Erwartetes Ergebnis:**
- CSI Driver Pods laufen in `kube-system`
- StorageClass `nfs-csi` ist vorhanden und als default markiert (`(default)`)
- PVC-Binding gegen NFS Server 10.135.0.7 funktioniert

---

## Abgeschlossene Aufgaben (Vorprojekt)

### Terraform Droplet Deletion Timeout - GELÖST (2026-02-15)

**Problem:** `terraform destroy` schlug mit hartem 1-Minuten-Timeout fehl (Provider-Bug in DigitalOcean Provider v2.74.0).

**Lösung:** Wrapper-Script `scripts/safe-destroy.sh` - führt destroy aus, ignoriert Timeout-Fehler, verifiziert Löschung in DigitalOcean, räumt Terraform State auf.

**Status:** ✅ Implementiert, getestet, produktiv

```bash
# Cluster erstellen
terraform apply -auto-approve

# Cluster sicher löschen
./scripts/safe-destroy.sh
```

---

## Entscheidungen / Constraints

| Thema | Entscheidung | Begründung |
|-------|-------------|------------|
| Separates Helmfile | `helmfile-csi-nfs.yaml` statt Erweiterung von `helmfile.yaml` | Klare Trennung von Concerns, unabhängig deploybar |
| StorageClass als eigenes Chart | `charts/nfs-csi-storageclass` | NFS Server IP muss konfigurierbar sein via values |
| Default StorageClass | `nfs-csi` wird default | Einfachere PVC-Nutzung ohne explizite StorageClass-Angabe |
| reclaimPolicy | `Retain` | Sicher für Training - Daten bleiben bei PVC-Löschung erhalten |
| NFS Server IP | Über `values.yaml` konfigurierbar | Flexibel für verschiedene Umgebungen |

# Product Requirements Document (PRD)
## Migration von NGINX Ingress Controller zu Traefik

**Version:** 1.0
**Datum:** 2026-01-25
**Status:** Draft

---

## 1. Übersicht

### 1.1 Projektziel
Ersetzung des bestehenden NGINX Ingress Controllers durch Traefik als Ingress-Lösung für den Kubernetes-Cluster auf DigitalOcean.

### 1.2 Hintergrund
Das aktuelle Setup verwendet `ingress-nginx` (Helm Chart Version 4.10.0) als Ingress Controller. Traefik bietet moderne Features, native Kubernetes-Integration und eine bessere Performance für moderne Cloud-Native Workloads.

### 1.3 Infrastruktur-Kontext
Das Kubernetes-Cluster wird über Terraform auf DigitalOcean ausgerollt. Die vollständige Infrastruktur inklusive Cluster-Provisionierung, MetalLB, DNS-Konfiguration und Ingress-Controller wird automatisiert bereitgestellt.

**Voraussetzungen:**
- **DigitalOcean Token:** Ein gültiger API-Token für DigitalOcean ist als Umgebungsvariable `DIGITALOCEAN_ACCESS_TOKEN` vorhanden
- **Terraform:** Version >= 1.0 für das Cluster-Rollout
- **kubectl:** Für die Validierung und das Management des Clusters
- **Test-User:** `tln1` für DNS und Validierungstests

---

## 2. Anforderungen

### 2.1 Funktionale Anforderungen

#### 2.1.1 Traefik Installation
- **Version:** `38.0.2` (Traefik Helm Chart)
- **Deployment Methode:** Helm Chart über `helm upgrade --install`
- **Namespace:** `ingress`
- **Repository:** https://traefik.github.io/charts
- **Chart Name:** `traefik/traefik`

#### 2.1.2 CRD Konfiguration
- **CRDs deaktiviert:** Die Installation von Custom Resource Definitions (CRDs) durch das Helm Chart muss explizit deaktiviert werden
- **Helm Parameter:** `--skip-crds`
- **Zusätzlich:** `--reset-values` zur Vermeidung von Konflikten mit vorherigen Werten
- **Begründung:** Vereinfachtes Management, Vermeidung von CRD-Versionskonflikten

#### 2.1.3 LoadBalancer Integration
- Traefik Service muss als `type: LoadBalancer` konfiguriert werden
- Integration mit bestehendem MetalLB Setup (Version 0.13.12)
- Automatische IP-Zuweisung durch MetalLB aus dem konfigurierten IP-Pool
- Wartelogik bis LoadBalancer IP zugewiesen ist (analog zu nginx Implementierung)

#### 2.1.4 DNS Konfiguration
- Beibehaltung der bestehenden Wildcard-DNS-Einträge
- A-Record `*.{user}.do.t3isp.de` → Traefik LoadBalancer IP
- Automatische Aktualisierung nach Traefik-Deployment

### 2.2 Technische Anforderungen

#### 2.2.1 Terraform Integration
- Anpassung der Datei `scripts/helm-charts/deploy.sh`
- Entfernung des nginx Helm Deployments
- Hinzufügen des Traefik Helm Deployments
- Aktualisierung der Variablen:
  - `INGRESS_NAMESPACE` → `ingress`
  - `INGRESS_SERVICE_NAME` → `traefik` (Standard Service Name)

#### 2.2.2 Helm Chart Konfiguration
Traefik Helm Chart mit folgenden Einstellungen:
```bash
helm repo add traefik https://traefik.github.io/charts
helm upgrade -n ingress --install traefik traefik/traefik \
  --version 38.0.2 \
  --create-namespace \
  --skip-crds \
  --reset-values
```

#### 2.2.3 Outputs und Monitoring
- Anpassung der Output-Logik zur Erfassung der Traefik LoadBalancer IP
- Weiterführung der `ingress_ip.txt` Datei (JSON Format)
- Logging und Status-Checks während der Installation

### 2.3 Nicht-funktionale Anforderungen

#### 2.3.1 Kompatibilität
- Kubernetes Version: 1.33.0 (aktuell im Projekt)
- Helm Version: >= 3.x
- Kompatibilität mit bestehendem MetalLB Setup

#### 2.3.2 Dokumentation
- Aktualisierung der `README.md` mit Traefik-spezifischen Informationen
- Versionsangaben in README aktualisieren
- Validierungsbefehle anpassen

---

## 3. Implementierungsplanung

### 3.1 Branch-Strategie
**WICHTIG:** Alle Änderungen werden in einem neuen Feature-Branch durchgeführt.

- **Branch Name:** `feature/migrate-nginx-to-traefik`
- **Basis Branch:** `master`
- **Merge Strategie:** Pull Request nach Testing und Validierung

### 3.2 Betroffene Dateien
1. `scripts/helm-charts/deploy.sh` - Haupt-Deployment-Script
2. `README.md` - Dokumentation aktualisieren
3. `helm-charts.tf` - Eventuell Namespace-Anpassungen
4. `dns.tf` - Prüfen ob Anpassungen nötig
5. `outputs.tf` - Prüfen ob Outputs angepasst werden müssen

### 3.3 Implementierungsschritte
1. Feature-Branch erstellen
2. Traefik Helm Chart in `deploy.sh` integrieren
3. nginx Ingress Deployment entfernen
4. Namespace und Service-Namen aktualisieren
5. CRD-Installation deaktivieren (`--skip-crds`)
6. IP-Wartelogik auf neuen Service-Namen anpassen
7. README.md aktualisieren
8. **Terraform Rollout testen** (mit User `tln1`)
   - `terraform init`
   - `terraform plan` (Änderungen prüfen)
   - `terraform apply` (Cluster ausrollen)
   - Erfolgreiches Deployment kontrollieren
9. Testing und Validierung
10. Pull Request erstellen

---

## 4. Validierung & Testing

### 4.1 Terraform Rollout-Validierung
```bash
# Token prüfen
echo $DIGITALOCEAN_ACCESS_TOKEN

# Terraform initialisieren
terraform init

# Änderungen planen und prüfen
terraform plan

# Cluster ausrollen
terraform apply -auto-approve

# Terraform State prüfen
terraform state list
terraform output
```

### 4.2 Deployment-Validierung
```bash
# Cluster-Verbindung testen
kubectl cluster-info

# Traefik Pods prüfen
kubectl -n ingress get pods

# Service und LoadBalancer IP prüfen
kubectl -n ingress get svc

# Logs prüfen
kubectl logs -n ingress -l app.kubernetes.io/name=traefik
```

### 4.3 Ingress-Funktionalität
```bash
# DNS-Auflösung testen (mit User tln1)
dig +short app.tln1.do.t3isp.de

# Test-Ingress Resource erstellen
kubectl apply -f <test-ingress.yaml>

# HTTP Routing validieren
curl -H "Host: app.tln1.do.t3isp.de" http://<TRAEFIK_IP>
```

### 4.4 MetalLB Integration
```bash
# IP-Pool Status prüfen
kubectl get ipaddresspool -n metallb-system

# L2Advertisement prüfen
kubectl get l2advertisement -n metallb-system
```

---

## 5. Risiken & Mitigationen

| Risiko | Wahrscheinlichkeit | Impact | Mitigation |
|--------|-------------------|--------|------------|
| Inkompatibilität mit MetalLB | Niedrig | Hoch | Traefik ist vollständig kompatibel mit MetalLB |
| Fehlende CRDs bei Bedarf | Mittel | Mittel | Bei Bedarf können CRDs manuell nachinstalliert werden |
| DNS-Propagation Verzögerung | Niedrig | Niedrig | Wartelogik wie bei nginx beibehalten |
| Breaking Changes bei Migration | Mittel | Hoch | Feature-Branch Testing vor Merge |

---

## 6. Rollback-Plan

Falls nach der Migration Probleme auftreten:
1. Checkout des `master` Branch
2. Terraform Destroy des Clusters (optional)
3. Terraform Apply mit ursprünglicher nginx Konfiguration
4. Oder: Manuelles Rollback via Helm:
   ```bash
   helm uninstall traefik -n ingress
   helm install ingress-nginx ingress-nginx/ingress-nginx --version 4.10.0 -n ingress-nginx --create-namespace
   ```

---

## 7. Erfolgs-Kriterien

- ✅ **Terraform Rollout erfolgreich** (`terraform apply` ohne Fehler)
- ✅ **Cluster erreichbar** (kubectl Zugriff funktioniert)
- ✅ Traefik Helm Chart erfolgreich installiert
- ✅ CRDs nicht installiert (verifiziert via `kubectl get crd | grep traefik`)
- ✅ LoadBalancer IP erfolgreich von MetalLB zugewiesen
- ✅ DNS A-Record zeigt auf Traefik LoadBalancer IP (`*.tln1.do.t3isp.de`)
- ✅ Test-Ingress erfolgreich erreichbar
- ✅ Keine nginx Komponenten mehr im Cluster
- ✅ README.md aktualisiert mit Traefik-Informationen

---

## 8. Zeitplan

| Phase | Aktivität | Dauer |
|-------|-----------|-------|
| 1 | Branch erstellen und Code-Änderungen | - |
| 2 | Traefik Integration implementieren | - |
| 3 | **Terraform Rollout testen (User: tln1)** | - |
| 4 | Deployment-Kontrolle und Validierung | - |
| 5 | Dokumentation aktualisieren | - |
| 6 | Code Review und Merge | - |

---

## 9. Referenzen

- **Traefik Helm Chart:** https://github.com/traefik/traefik-helm-chart
- **Traefik Dokumentation:** https://doc.traefik.io/traefik/
- **Aktuelles Setup:** README.md im Repository
- **MetalLB Dokumentation:** https://metallb.universe.tf/

---

## 10. Offene Fragen

- [ ] Sollen zusätzliche Traefik Features aktiviert werden? (z.B. Dashboard, Metrics)
- [ ] Benötigen wir Custom Values für Traefik? (z.B. Resource Limits, Replicas)
- [ ] Soll HTTP → HTTPS Redirect global aktiviert werden?
- [ ] Welche Traefik Log-Level sollen verwendet werden?

---

**Erstellt von:** Claude Code
**Genehmigung erforderlich von:** Projektverantwortlicher
**Status:** Bereit für Review

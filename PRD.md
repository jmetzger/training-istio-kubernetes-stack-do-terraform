# Product Requirements Document (PRD)
## Terraform Rollout und Testing

**Version:** 2.0
**Datum:** 2026-01-25
**Status:** Testing Phase

---

## 1. Übersicht

### 1.1 Ziel
Vollständiges Terraform Rollout des Kubernetes-Clusters auf DigitalOcean mit Traefik Ingress Controller und umfassende Validierung aller Komponenten.

### 1.2 Infrastruktur-Kontext
Das Kubernetes-Cluster wird über Terraform auf DigitalOcean ausgerollt. Die vollständige Infrastruktur inklusive Cluster-Provisionierung, MetalLB, DNS-Konfiguration und Traefik Ingress-Controller wird automatisiert bereitgestellt.

**Voraussetzungen:**
- **DigitalOcean Token:** Ein gültiger API-Token für DigitalOcean ist als Umgebungsvariable `DIGITALOCEAN_ACCESS_TOKEN` vorhanden
- **Terraform:** Version >= 1.0 für das Cluster-Rollout
- **kubectl:** Für die Validierung und das Management des Clusters
- **Test-User:** `tln1` für DNS und Validierungstests

---

## 2. Terraform Rollout-Schritte

### 2.1 Vorbereitung
```bash
# Token prüfen
echo $DIGITALOCEAN_ACCESS_TOKEN

# Arbeitsverzeichnis sicherstellen
pwd
# Expected: /home/jmetzger/ki-projects/training-istio-kubernetes-stack-do-terraform
```

### 2.2 Terraform Initialisierung
```bash
# Terraform initialisieren
terraform init

# Provider und Module prüfen
terraform version
```

### 2.3 Cluster Planung
```bash
# Änderungen planen und prüfen
terraform plan

# Erwartete Änderungen:
# - Kubernetes Cluster (DigitalOcean)
# - MetalLB Namespace und Deployment
# - Traefik Ingress Controller im ingress Namespace
# - DNS A-Records für *.tln1.do.t3isp.de
```

### 2.4 Cluster Deployment
```bash
# Cluster ausrollen
terraform apply -auto-approve

# Erwartete Ausgabe:
# - Cluster erstellt
# - MetalLB deployed
# - Traefik deployed
# - DNS konfiguriert
# - LoadBalancer IP zugewiesen
```

### 2.5 State-Validierung
```bash
# Terraform State prüfen
terraform state list

# Outputs anzeigen
terraform output

# ingress_ip.txt prüfen
cat ingress_ip.txt
```

---

## 3. Deployment-Validierung

### 3.1 Cluster-Konnektivität
```bash
# Cluster-Verbindung testen
kubectl cluster-info

# Nodes prüfen
kubectl get nodes

# Namespaces prüfen
kubectl get namespaces
```

### 3.2 MetalLB Validierung
```bash
# MetalLB Namespace prüfen
kubectl get ns metallb-system

# MetalLB Pods prüfen
kubectl -n metallb-system get pods

# IP-Pool Status prüfen
kubectl get ipaddresspool -n metallb-system

# L2Advertisement prüfen
kubectl get l2advertisement -n metallb-system

# IPAddressPool Details
kubectl get ipaddresspool -n metallb-system -o yaml
```

### 3.3 Traefik Validierung
```bash
# Traefik Namespace prüfen
kubectl get ns ingress

# Traefik Pods prüfen
kubectl -n ingress get pods

# Pod Status Details
kubectl -n ingress get pods -o wide

# Service und LoadBalancer IP prüfen
kubectl -n ingress get svc

# LoadBalancer IP muss sichtbar sein (nicht <pending>)

# Logs prüfen
kubectl logs -n ingress -l app.kubernetes.io/name=traefik

# Traefik Deployment prüfen
kubectl -n ingress get deployment
```

### 3.4 CRD-Validierung
```bash
# Verifizieren dass KEINE Traefik CRDs installiert sind
kubectl get crd | grep traefik

# Erwartete Ausgabe: Leer (keine CRDs)
```

---

## 4. DNS und Netzwerk-Tests

### 4.1 DNS-Auflösung
```bash
# DNS-Auflösung testen (mit User tln1)
dig +short app.tln1.do.t3isp.de

# Erwartete Ausgabe: Traefik LoadBalancer IP

# Alternative: nslookup
nslookup app.tln1.do.t3isp.de

# Wildcard DNS testen
dig +short test.tln1.do.t3isp.de
dig +short demo.tln1.do.t3isp.de
```

### 4.2 LoadBalancer IP-Zuweisung
```bash
# LoadBalancer IP aus Service extrahieren
TRAEFIK_IP=$(kubectl -n ingress get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Traefik IP: $TRAEFIK_IP"

# IP muss gesetzt sein (nicht leer)
```

---

## 5. Funktionale Tests

### 5.1 Test-Deployment erstellen
```bash
# Einfaches nginx Test-Deployment
kubectl create deployment test-nginx --image=nginx:latest

# Service erstellen
kubectl expose deployment test-nginx --port=80 --type=ClusterIP
```

### 5.2 Test-Ingress Resource
Erstelle eine Datei `test-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: default
spec:
  rules:
  - host: app.tln1.do.t3isp.de
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: test-nginx
            port:
              number: 80
```

```bash
# Ingress erstellen
kubectl apply -f test-ingress.yaml

# Ingress Status prüfen
kubectl get ingress

# Ingress Details
kubectl describe ingress test-ingress
```

### 5.3 HTTP Routing validieren
```bash
# HTTP Request mit Host-Header
curl -v -H "Host: app.tln1.do.t3isp.de" http://$TRAEFIK_IP

# Erwartete Ausgabe: nginx Welcome-Seite

# Direkter Test via DNS (falls propagiert)
curl -v http://app.tln1.do.t3isp.de

# HTTP Status sollte 200 sein
```

---

## 6. Aufräumen (Clean-Up)

### 6.1 Test-Ressourcen entfernen
```bash
# Test-Ingress löschen
kubectl delete -f test-ingress.yaml

# Test-Service und Deployment löschen
kubectl delete service test-nginx
kubectl delete deployment test-nginx
```

### 6.2 Komplettes Cluster-Teardown (optional)
```bash
# NUR wenn Cluster komplett gelöscht werden soll
terraform destroy -auto-approve

# Achtung: Löscht das gesamte Cluster und alle Ressourcen!
```

---

## 7. Erfolgs-Kriterien

### 7.1 Terraform Rollout
- ✅ `terraform init` erfolgreich (ohne Fehler)
- ✅ `terraform plan` zeigt erwartete Ressourcen
- ✅ `terraform apply` ohne Fehler durchgelaufen
- ✅ `terraform state list` zeigt alle Ressourcen
- ✅ `terraform output` zeigt korrekte Werte

### 7.2 Cluster-Status
- ✅ Cluster erreichbar (kubectl Zugriff funktioniert)
- ✅ Alle Nodes im Status "Ready"
- ✅ Alle System-Pods laufen

### 7.3 MetalLB
- ✅ MetalLB Namespace existiert (`metallb-system`)
- ✅ MetalLB Pods im Status "Running"
- ✅ IP-Pool konfiguriert und aktiv
- ✅ L2Advertisement aktiv

### 7.4 Traefik
- ✅ Traefik Namespace existiert (`ingress`)
- ✅ Traefik Pods im Status "Running"
- ✅ Traefik Service existiert
- ✅ LoadBalancer IP erfolgreich von MetalLB zugewiesen
- ✅ LoadBalancer IP ist nicht `<pending>` sondern eine echte IP
- ✅ CRDs nicht installiert (verifiziert via `kubectl get crd | grep traefik`)
- ✅ Traefik Logs zeigen keine Fehler

### 7.5 DNS
- ✅ DNS A-Record zeigt auf Traefik LoadBalancer IP (`*.tln1.do.t3isp.de`)
- ✅ `dig +short app.tln1.do.t3isp.de` liefert korrekte IP
- ✅ Wildcard DNS funktioniert für alle Subdomains

### 7.6 Funktionalität
- ✅ Test-Ingress erfolgreich erstellt
- ✅ HTTP Request über Ingress erfolgreich (Status 200)
- ✅ Routing funktioniert korrekt
- ✅ nginx Welcome-Seite erreichbar über `app.tln1.do.t3isp.de`

### 7.7 Cleanup (Legacy)
- ✅ Keine nginx Komponenten mehr im Cluster
- ✅ Kein `ingress-nginx` Namespace vorhanden

---

## 8. Troubleshooting

### 8.1 LoadBalancer IP bleibt pending
```bash
# MetalLB Logs prüfen
kubectl logs -n metallb-system -l app=metallb

# IP-Pool Konfiguration prüfen
kubectl get ipaddresspool -n metallb-system -o yaml

# Events prüfen
kubectl -n ingress get events --sort-by='.lastTimestamp'
```

### 8.2 DNS funktioniert nicht
```bash
# DNS Terraform Output prüfen
terraform output

# DigitalOcean DNS Records manuell prüfen (via Web-Interface)

# Warten auf DNS-Propagation (kann bis zu 5 Minuten dauern)
```

### 8.3 Traefik Pods starten nicht
```bash
# Pod Status Details
kubectl -n ingress describe pod <pod-name>

# Logs mit Fehlersuche
kubectl logs -n ingress <pod-name> --previous

# Events im Namespace
kubectl -n ingress get events
```

### 8.4 Terraform Apply schlägt fehl
```bash
# Terraform Logs mit Debug-Level
TF_LOG=DEBUG terraform apply

# State-Datei prüfen
terraform show

# Bei State-Problemen: Backend neu initialisieren
terraform init -reconfigure
```

---

## 9. Checkliste

### Pre-Flight Check
- [ ] DigitalOcean Token gesetzt (`echo $DIGITALOCEAN_ACCESS_TOKEN`)
- [ ] Terraform installiert (`terraform version`)
- [ ] kubectl installiert (`kubectl version --client`)
- [ ] Korrektes Arbeitsverzeichnis

### Terraform Rollout
- [ ] `terraform init` erfolgreich
- [ ] `terraform plan` geprüft
- [ ] `terraform apply` erfolgreich
- [ ] `terraform output` zeigt Werte
- [ ] `ingress_ip.txt` existiert und enthält IP

### Deployment Checks
- [ ] kubectl Zugriff funktioniert
- [ ] Alle Nodes "Ready"
- [ ] MetalLB Pods "Running"
- [ ] Traefik Pods "Running"
- [ ] LoadBalancer IP zugewiesen (nicht pending)
- [ ] Keine CRDs installiert

### Netzwerk Checks
- [ ] DNS-Auflösung funktioniert
- [ ] LoadBalancer IP korrekt
- [ ] Test-Ingress erstellt
- [ ] HTTP Request erfolgreich (Status 200)

### Cleanup
- [ ] Test-Ressourcen entfernt
- [ ] Cluster läuft stabil (oder destroyed falls gewünscht)

---

**Status:** Ready for Testing
**Test-User:** tln1
**Erstellt von:** Claude Code

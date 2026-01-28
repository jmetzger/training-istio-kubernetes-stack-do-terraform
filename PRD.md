# Product Requirements Document (PRD)
## cert-manager Deployment mit helmfile (HTTP-01)

**Version:** 1.0
**Datum:** 2026-01-28
**Status:** Implementation
**Branch:** feature/cert-manager-http01

---

## 1. Übersicht

### 1.1 Ziel
Deployment von cert-manager via helmfile mit HTTP-01 Challenge über Traefik Ingress Controller. Automatische Ausstellung von Let's Encrypt TLS-Zertifikaten für Kubernetes Ingress-Ressourcen.

### 1.2 Kontext
Das Kubernetes-Cluster ist bereits via Terraform ausgerollt und läuft mit Traefik als Ingress Controller. cert-manager wird nach dem Terraform-Rollout manuell über helmfile installiert, um TLS-Zertifikate automatisch zu verwalten.

**Voraussetzungen:**
- **Kubernetes Cluster:** Bereits deployed via Terraform
- **Traefik:** Ingress Controller läuft im Namespace `ingress`
- **.kube/config:** Automatisch konfiguriert durch `terraform apply`
- **helmfile:** Installiert für Helm-Deployments
- **DNS:** Wildcard `*.do.t3isp.de` zeigt auf Traefik LoadBalancer IP
- **Email:** `info@t3company.de` (hardcoded)

---

## 2. Branch-Strategie

### 2.1 Feature-Branch
Alle Arbeiten werden in einem separaten Feature-Branch durchgeführt:

```bash
# Feature-Branch erstellen
git checkout -b feature/cert-manager-http01

# Nach Abschluss: Pull Request erstellen
# Ziel-Branch: master
```

### 2.2 Branch-Schutz
- Alle Änderungen via Pull Request
- Review vor Merge
- Tests erfolgreich

---

## 3. Terraform Rollout (Voraussetzung)

### 3.0 Umgebungsvariablen

Die DigitalOcean API-Authentifizierung erfolgt über eine Umgebungsvariable:

```bash
# TF_VAR_do_token setzen
export TF_VAR_do_token="your-digitalocean-api-token"

# WICHTIG: Diese Variable wird von Terraform UND dem DigitalOcean Provider verwendet
# TF_VAR_do_token = DIGITALOCEAN_ACCESS_TOKEN
# Beide Namen referenzieren den gleichen API-Token
```

**Hinweis:**
- `TF_VAR_do_token` ist die Terraform-Variable (definiert in `variables.tf`)
- Diese wird intern als `DIGITALOCEAN_ACCESS_TOKEN` vom DigitalOcean Provider verwendet
- Es ist EINE Variable mit zwei Namen/Verwendungszwecken

### 3.1 Cluster bereitstellen
```bash
# Cluster mit Traefik ausrollen
terraform apply -auto-approve

# Erwartete Ausgabe:
# - Kubernetes Cluster erstellt
# - Traefik Ingress Controller deployed
# - .kube/config automatisch konfiguriert
# - DNS Records erstellt
```

### 3.2 Cluster-Validierung
```bash
# Cluster-Verbindung testen
kubectl cluster-info

# Traefik prüfen
kubectl -n ingress get pods
kubectl -n ingress get svc

# LoadBalancer IP muss gesetzt sein
kubectl -n ingress get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

---

## 4. helmfile Installation

### 4.1 Vorbereitung
```bash
# Arbeitsverzeichnis
cd /home/jmetzger/ki-projects/training-istio-kubernetes-stack-do-terraform

# helmfile Version prüfen
helmfile --version
```

### 4.2 cert-manager Deployment
```bash
# cert-manager mit helmfile installieren
helmfile sync

# Erwartete Ausgabe:
# - Repository jetstack added
# - Release cert-manager installing
# - Release cert-manager-config installing
# - Hooks: cert-manager Pods ready
# - Status: deployed
```

### 4.3 Installation verifizieren
```bash
# Namespace prüfen
kubectl get ns cert-manager

# Pods prüfen (sollten alle Running sein)
kubectl get pods -n cert-manager

# Erwartete Pods:
# - cert-manager-xxxxx (Running)
# - cert-manager-webhook-xxxxx (Running)
# - cert-manager-cainjector-xxxxx (Running)
```

---

## 5. Validierung

### 5.1 Step 1: cert-manager Pod Status

```bash
# Pods im cert-manager Namespace
kubectl get pods -n cert-manager

# Pod Details
kubectl get pods -n cert-manager -o wide

# Logs prüfen (darf keine Fehler zeigen)
kubectl logs -n cert-manager deployment/cert-manager

# Erwartete Ausgabe: "controller: Finished processing work item"
```

**Erfolgs-Kriterium:**
- ✅ Alle 3 Pods im Status "Running"
- ✅ Keine Error-Logs
- ✅ Ready: 1/1 für alle Pods

### 5.2 Step 2: ClusterIssuer Ready Status

```bash
# ClusterIssuer auflisten
kubectl get clusterissuer

# Erwartete Ausgabe:
# NAME                   READY   AGE
# letsencrypt-http01     True    1m

# Details prüfen
kubectl describe clusterissuer letsencrypt-http01

# ACME Server muss erreichbar sein
# Status.Conditions.Type=Ready, Status=True
```

**Erfolgs-Kriterium:**
- ✅ ClusterIssuer existiert: `letsencrypt-http01`
- ✅ READY Status: `True`
- ✅ ACME Server: `https://acme-v02.api.letsencrypt.org/directory`
- ✅ Email: `info@t3company.de`
- ✅ Solver: `http01` mit `ingressClassName: traefik`

### 5.3 Step 3: Test-Certificate erstellen

Erstelle eine Datei `test-certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-tls
  issuerRef:
    name: letsencrypt-http01
    kind: ClusterIssuer
  dnsNames:
    - app.$USER.do.t3isp.de
```

```bash
# USER Variable setzen (aktueller eingeloggter User)
export USER=$(whoami)
echo "Test Domain: app.$USER.do.t3isp.de"

# Certificate erstellen (Datei anpassen mit echtem User)
kubectl apply -f test-certificate.yaml

# Certificate Status beobachten
kubectl get certificate -w

# Erwartete Status-Progression:
# test-cert   False   Issuing       10s
# test-cert   True    Ready         45s

# Details prüfen
kubectl describe certificate test-cert

# Challenge prüfen (sollte nach ~30-90 Sekunden verschwinden)
kubectl get challenge
```

**Erfolgs-Kriterium:**
- ✅ Certificate wechselt zu Status `Ready: True`
- ✅ Secret `test-tls` wurde erstellt
- ✅ Challenge wurde erfolgreich durchgeführt (HTTP-01)
- ✅ Keine Fehler in Events

**Troubleshooting:**
```bash
# Wenn Certificate auf False bleibt:
kubectl get certificaterequest
kubectl describe certificaterequest <name>

kubectl get challenge
kubectl describe challenge <name>

# cert-manager Logs
kubectl logs -n cert-manager deployment/cert-manager | grep -i error
```

### 5.4 Step 4: Test-Ingress mit TLS

Erstelle zuerst ein Test-Deployment:

```bash
# nginx Test-Deployment
kubectl create deployment test-nginx --image=nginx:latest

# Service erstellen
kubectl expose deployment test-nginx --port=80 --type=ClusterIP
```

Erstelle eine Datei `test-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-http01"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app.$USER.do.t3isp.de
      secretName: test-tls
  rules:
    - host: app.$USER.do.t3isp.de
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
# Ingress erstellen (Datei anpassen mit echtem User)
kubectl apply -f test-ingress.yaml

# Ingress Status prüfen
kubectl get ingress test-ingress

# Details anzeigen
kubectl describe ingress test-ingress

# Certificate sollte automatisch erstellt werden (falls nicht schon vorhanden)
kubectl get certificate

# HTTPS Test (nach 30-90 Sekunden)
curl -v https://app.$USER.do.t3isp.de

# Erwartete Ausgabe:
# * SSL certificate verify ok
# * Server certificate:
# *  subject: CN=app.$USER.do.t3isp.de
# *  issuer: C=US; O=Let's Encrypt; CN=R10
# < HTTP/1.1 200 OK
# <!DOCTYPE html>
# <html>
# <head>
# <title>Welcome to nginx!</title>
```

**Zertifikat-Details prüfen:**
```bash
# Zertifikat anzeigen
echo | openssl s_client -servername app.$USER.do.t3isp.de -connect $(kubectl -n ingress get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):443 2>/dev/null | openssl x509 -noout -text

# Issuer sollte "Let's Encrypt" sein
# Subject sollte "CN=app.$USER.do.t3isp.de" sein
# Validity: 90 Tage
```

**Erfolgs-Kriterium:**
- ✅ Ingress erstellt
- ✅ Certificate automatisch provisioniert
- ✅ HTTPS-Zugriff funktioniert
- ✅ Browser zeigt gültiges Let's Encrypt Zertifikat
- ✅ Keine SSL/TLS Fehler
- ✅ nginx Welcome-Seite sichtbar

---

## 6. Cleanup

### 6.1 Test-Ressourcen entfernen
```bash
# Test-Ingress löschen
kubectl delete -f test-ingress.yaml

# Test-Service und Deployment löschen
kubectl delete service test-nginx
kubectl delete deployment test-nginx

# Test-Certificate löschen
kubectl delete certificate test-cert

# Secret wird automatisch von cert-manager entfernt
```

### 6.2 cert-manager entfernen (nur bei Bedarf)
```bash
# ACHTUNG: Löscht cert-manager komplett!
helmfile destroy

# Namespace manuell löschen (falls nötig)
kubectl delete namespace cert-manager
```

---

## 7. Troubleshooting

### 7.1 Certificate bleibt auf "Issuing"

**Symptom:** Certificate Status bleibt auf `Ready: False`, Reason: `Issuing`

**Diagnose:**
```bash
# CertificateRequest prüfen
kubectl get certificaterequest
kubectl describe certificaterequest <name>

# Challenge prüfen
kubectl get challenge
kubectl describe challenge <name>

# Erwartete Challenge Type: HTTP-01
# Solver sollte Ingress mit Traefik erstellen
```

**Häufige Ursachen:**
- DNS zeigt nicht auf Traefik LoadBalancer IP
- Port 80 ist nicht erreichbar
- Traefik IngressClass fehlt oder falsch konfiguriert
- Let's Encrypt kann Domain nicht validieren

**Lösung:**
```bash
# DNS prüfen
dig +short app.$USER.do.t3isp.de

# Sollte Traefik LoadBalancer IP zeigen
EXPECTED_IP=$(kubectl -n ingress get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Expected IP: $EXPECTED_IP"

# Port 80 Test
curl -v http://app.$USER.do.t3isp.de/.well-known/acme-challenge/test

# IngressClass prüfen
kubectl get ingressclass
```

### 7.2 HTTP-01 Challenge schlägt fehl

**Symptom:** Challenge wird nicht gelöst, bleibt pending oder schlägt fehl

**Diagnose:**
```bash
# Challenge Events
kubectl describe challenge <name>

# Traefik Routing prüfen
kubectl -n ingress logs -l app.kubernetes.io/name=traefik

# Challenge Ingress prüfen (temporär von cert-manager erstellt)
kubectl get ingress -A | grep acme
```

**Häufige Ursachen:**
- Traefik kann Challenge-Ingress nicht routen
- DNS Propagation noch nicht abgeschlossen
- Firewall blockiert Port 80
- Let's Encrypt Server kann Domain nicht erreichen

**Lösung:**
```bash
# Manueller Test der Challenge-Route
# cert-manager erstellt temporär einen Ingress wie:
# /.well-known/acme-challenge/<token>

# Warten auf DNS Propagation (1-5 Minuten)
watch dig +short app.$USER.do.t3isp.de

# Challenge neu triggern (Certificate löschen und neu erstellen)
kubectl delete certificate test-cert
kubectl apply -f test-certificate.yaml
```

### 7.3 Let's Encrypt Rate Limits

**Symptom:** Error: "too many certificates already issued"

**Ursache:** Let's Encrypt Production Limits:
- **5 Zertifikate pro Domain pro Woche**
- **50 Zertifikate pro registrierter Domain pro Woche**

**Lösung:**
```bash
# Auf Staging-Umgebung wechseln für Tests
# In helmfile.yaml:
values:
  - email: "info@t3company.de"
    server: "staging"  # Statt "prod"
    enableHttp01: true

# Neu deployen
helmfile sync

# Staging ClusterIssuer wird erstellt
# Zertifikate von Staging werden von Browsern NICHT vertraut
# Aber keine Rate Limits
```

### 7.4 cert-manager Pods crashen

**Symptom:** Pods im Status `CrashLoopBackOff` oder `Error`

**Diagnose:**
```bash
# Pod Status
kubectl get pods -n cert-manager

# Logs prüfen
kubectl logs -n cert-manager deployment/cert-manager
kubectl logs -n cert-manager deployment/cert-manager-webhook
kubectl logs -n cert-manager deployment/cert-manager-cainjector

# Events
kubectl get events -n cert-manager --sort-by='.lastTimestamp'
```

**Häufige Ursachen:**
- CRDs nicht installiert
- Webhook nicht erreichbar
- Permissions fehlen

**Lösung:**
```bash
# CRDs prüfen
kubectl get crd | grep cert-manager

# Sollte mindestens diese CRDs zeigen:
# - certificates.cert-manager.io
# - certificaterequests.cert-manager.io
# - issuers.cert-manager.io
# - clusterissuers.cert-manager.io

# Falls CRDs fehlen: helmfile neu deployen
helmfile destroy
helmfile sync
```

---

## 8. Konfiguration

### 8.1 helmfile.yaml

**Wichtige Einstellungen:**

```yaml
releases:
  - name: cert-manager-config
    namespace: cert-manager
    chart: ./charts/cert-manager-config
    needs:
      - cert-manager/cert-manager
    wait: true
    values:
      - email: "info@t3company.de"
        server: "prod"
        enableDns01: false
        enableHttp01: true
```

**Konfigurationsoptionen:**
- `email`: Let's Encrypt Benachrichtigungs-Email (hardcoded)
- `server`: `"prod"` oder `"staging"`
- `enableDns01`: `false` (DNS-01 Challenge deaktiviert)
- `enableHttp01`: `true` (HTTP-01 Challenge aktiviert)

### 8.2 ClusterIssuer Konfiguration

Der ClusterIssuer `letsencrypt-http01` wird automatisch erstellt:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: info@t3company.de
    privateKeySecretRef:
      name: letsencrypt-http01-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
```

**Wichtig:**
- `ingressClassName: traefik` - muss mit dem Ingress Controller übereinstimmen
- `privateKeySecretRef` - Speichert den ACME Account Key persistent

---

## 9. Erfolgs-Kriterien

### 9.1 helmfile Deployment
- ✅ `helmfile sync` ohne Fehler durchgelaufen
- ✅ cert-manager Namespace erstellt
- ✅ Alle Releases deployed (cert-manager + cert-manager-config)

### 9.2 cert-manager Status
- ✅ Alle Pods im Status "Running" (cert-manager, webhook, cainjector)
- ✅ Keine Error-Logs in Pods
- ✅ CRDs installiert (`kubectl get crd | grep cert-manager`)

### 9.3 ClusterIssuer
- ✅ ClusterIssuer `letsencrypt-http01` existiert
- ✅ Status: `READY = True`
- ✅ ACME Server korrekt konfiguriert
- ✅ Email: `info@t3company.de`
- ✅ Solver: HTTP-01 mit Traefik IngressClass

### 9.4 Test-Certificate
- ✅ Test-Certificate erfolgreich ausgestellt
- ✅ Status wechselt zu `Ready: True`
- ✅ Secret `test-tls` erstellt
- ✅ Challenge erfolgreich durchgeführt (HTTP-01)
- ✅ Keine Fehler in Events

### 9.5 Test-Ingress mit TLS
- ✅ Test-Ingress erstellt
- ✅ Zertifikat automatisch provisioniert
- ✅ HTTPS-Zugriff funktioniert (`curl https://app.$USER.do.t3isp.de`)
- ✅ Browser zeigt gültiges Let's Encrypt Zertifikat
- ✅ Keine SSL/TLS Warnungen
- ✅ nginx Welcome-Seite erreichbar

### 9.6 Cleanup
- ✅ Test-Ressourcen erfolgreich entfernt
- ✅ cert-manager läuft stabil
- ✅ Bereit für produktive Nutzung

---

## 10. Checkliste

### Pre-Flight Check
- [ ] **TF_VAR_do_token** Umgebungsvariable gesetzt (= DIGITALOCEAN_ACCESS_TOKEN)
- [ ] Kubernetes Cluster deployed (`terraform apply` erfolgreich)
- [ ] Traefik Ingress Controller läuft
- [ ] .kube/config konfiguriert (`kubectl cluster-info` funktioniert)
- [ ] helmfile installiert (`helmfile --version`)
- [ ] DNS Wildcard zeigt auf Traefik LoadBalancer IP
- [ ] Port 80 erreichbar

### Branch und PRD
- [ ] Branch erstellt: `feature/cert-manager-http01`
- [ ] Alte PRD gesichert: `PRD.backup.20260128.0750.md`
- [ ] Neue PRD.md erstellt

### Konfiguration
- [ ] helmfile.yaml angepasst (Email hardcoded, DIGITALOCEAN_TOKEN entfernt)
- [ ] values.yaml konfiguriert (`enableHttp01: true`, `enableDns01: false`)

### Deployment
- [ ] `helmfile sync` erfolgreich
- [ ] cert-manager Pods Running
- [ ] ClusterIssuer Ready

### Validierung (4 Steps)
- [ ] **Step 1:** cert-manager Pod Status geprüft
- [ ] **Step 2:** ClusterIssuer Ready Status verifiziert
- [ ] **Step 3:** Test-Certificate erfolgreich ausgestellt
- [ ] **Step 4:** Test-Ingress mit HTTPS funktioniert

### Abschluss
- [ ] Test-Ressourcen entfernt (Cleanup durchgeführt)
- [ ] Commit erstellt
- [ ] Pull Request erstellt nach `master`

---

## 11. Wichtige Hinweise

### Warum HTTP-01 statt DNS-01?

**Vorteile HTTP-01:**
- ✅ **Einfacher:** Kein API-Token oder DNS-Provider nötig
- ✅ **Schneller:** Keine DNS-Propagation Wartezeit
- ✅ **Ausreichend:** Traefik läuft, Port 80 ist offen
- ✅ **Standard:** Funktioniert mit jedem Ingress Controller

**Nachteile HTTP-01:**
- ❌ **Keine Wildcard-Zertifikate:** Jede Subdomain braucht eigenes Cert
- ❌ **Port 80 nötig:** Challenge läuft über HTTP (nicht HTTPS)
- ❌ **Öffentlich erreichbar:** Domain muss von Let's Encrypt erreichbar sein

**Wann DNS-01 verwenden:**
- Wildcard-Zertifikate benötigt (`*.domain.com`)
- Port 80 ist blockiert oder nicht verfügbar
- Domain ist nicht öffentlich erreichbar (internal/private)

### Let's Encrypt Umgebungen

**Production:**
- URL: `https://acme-v02.api.letsencrypt.org/directory`
- Rate Limits: 5 Certs/Domain/Woche, 50 Certs/Registered Domain/Woche
- Zertifikate werden von allen Browsern vertraut
- **Verwendung:** Produktiv-Einsatz

**Staging:**
- URL: `https://acme-staging-v02.api.letsencrypt.org/directory`
- Rate Limits: Sehr hoch (für Tests)
- Zertifikate werden NICHT von Browsern vertraut
- **Verwendung:** Tests und Entwicklung

### Test-User

Der Test-User wird dynamisch ermittelt:
```bash
export USER=$(whoami)
echo "Test Domain: app.$USER.do.t3isp.de"
```

Für manuelle Tests mit spezifischem User:
```bash
export USER="tln1"
# Dann test-certificate.yaml und test-ingress.yaml anpassen
```

---

**Status:** Ready for Implementation
**Erstellt von:** Claude Code (basierend auf Interview)
**Branch:** feature/cert-manager-http01
**Merge-Ziel:** master

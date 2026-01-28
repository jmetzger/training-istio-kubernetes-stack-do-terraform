# cert-manager Installation mit helmfile

Diese Konfiguration installiert cert-manager mit DNS-01 Challenge über DigitalOcean DNS.

## Warum DNS-01 statt HTTP-01?

Für dein Setup (DigitalOcean + VMs + MetalLB + Traefik):

### HTTP-01 würde funktionieren:
- ✅ DigitalOcean VMs haben öffentliche IPs
- ✅ MetalLB vergibt Worker-IPs an Traefik LoadBalancer
- ✅ DNS Wildcard zeigt auf Ingress IP
- ✅ Port 80 ist offen

### DNS-01 ist besser:
- ✅ **Robuster** - kein eingehender HTTP-Traffic nötig
- ✅ **Wildcard-Zertifikate** möglich (`*.user.do.t3isp.de`)
- ✅ **Firewall-unabhängig** - funktioniert auch hinter NAT/Firewall
- ✅ **DigitalOcean API** bereits vorhanden
- ✅ **Ideal für Workshops** - weniger Fehlerquellen

## Voraussetzungen

1. **helmfile** installieren:
```bash
# macOS
brew install helmfile

# Linux
wget https://github.com/helmfile/helmfile/releases/download/v0.163.1/helmfile_0.163.1_linux_amd64.tar.gz
tar -xzf helmfile_0.163.1_linux_amd64.tar.gz
sudo mv helmfile /usr/local/bin/
```

2. **Umgebungsvariablen** setzen:
```bash
export CERT_MANAGER_EMAIL="deine-email@example.com"
export DIGITALOCEAN_TOKEN="dein-do-token"  # Gleicher Token wie für Terraform
```

Oder in `.env` Datei:
```bash
cat > .env <<EOF
CERT_MANAGER_EMAIL=deine-email@example.com
DIGITALOCEAN_TOKEN=dein-do-token
EOF
source .env
```

## Installation

### 1. helmfile installieren
```bash
helmfile sync
```

### 2. ClusterIssuer prüfen
```bash
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-dns01
```

Der ClusterIssuer sollte `Ready=True` zeigen.

## Verwendung in Ingress-Ressourcen

### Einfaches Beispiel mit automatischem TLS-Zertifikat:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-dns01"
spec:
  ingressClassName: traefik  # Wichtig: traefik als IngressClass
  tls:
    - hosts:
        - myapp.username.do.t3isp.de
      secretName: myapp-tls  # cert-manager erstellt dieses Secret automatisch
  rules:
    - host: myapp.username.do.t3isp.de
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 80
```

### Wildcard-Zertifikat (nur mit DNS-01 möglich!):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-cert
  namespace: default
spec:
  secretName: wildcard-tls
  issuerRef:
    name: letsencrypt-dns01
    kind: ClusterIssuer
  commonName: "*.username.do.t3isp.de"
  dnsNames:
    - "*.username.do.t3isp.de"
    - "username.do.t3isp.de"
```

## Troubleshooting

### Zertifikat wird nicht ausgestellt:

```bash
# Certificate Status prüfen
kubectl get certificate
kubectl describe certificate myapp-tls

# CertificateRequest prüfen
kubectl get certificaterequest
kubectl describe certificaterequest <name>

# Challenge prüfen (sollte DNS-01 zeigen)
kubectl get challenge
kubectl describe challenge <name>

# cert-manager Logs
kubectl logs -n cert-manager deployment/cert-manager
```

### DNS-01 Challenge schlägt fehl:

```bash
# Secret prüfen
kubectl get secret -n cert-manager digitalocean-dns -o yaml

# ClusterIssuer prüfen
kubectl describe clusterissuer letsencrypt-dns01
```

Häufige Fehler:
- `invalid token` - DIGITALOCEAN_TOKEN falsch oder abgelaufen
- `DNS propagation timeout` - DNS-Änderung noch nicht propagiert (normal, dauert 1-2 Min)
- `rate limit exceeded` - Zu viele Requests an Let's Encrypt (nutze staging für Tests)

### Staging-Umgebung für Tests:

In `charts/cert-manager-config/values.yaml`:
```yaml
server: "staging"  # statt "prod"
issuerName: "letsencrypt-staging"
```

Staging-Zertifikate werden von Browsern nicht vertraut, aber du kannst unbegrenzt testen ohne Rate Limits.

## Integration in Terraform (Optional)

Du kannst helmfile in dein Terraform `deploy.sh` integrieren:

```bash
# Am Ende von scripts/helm-charts/deploy.sh
source .env 2>/dev/null || true
helmfile sync
```

## Deinstallation

```bash
helmfile destroy
```

**Achtung:** Dies löscht auch alle ausgestellten Zertifikate!

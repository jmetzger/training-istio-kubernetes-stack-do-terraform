# Product Requirements Document (PRD)
## Terraform Kubernetes Deployment - Cloud-Init Worker Node Fix

### Problem Statement

Beim Terraform Deploy funktionieren die lokalen Skripte nicht zuverlässig, weil `kubeadm` auf den Worker Nodes noch nicht verfügbar ist. Dies liegt daran, dass cloud-init auf den Worker Nodes noch nicht abgeschlossen ist, wenn das join-workers.sh Skript ausgeführt wird.

### Current State Analysis

#### Control Plane ✅
**Datei:** `main.tf:81-100`

Die Control Plane hat eine explizite Überprüfung, ob cloud-init abgeschlossen ist:

```terraform
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
```

**Mechanismus:**
- Wartet auf SSH-Verfügbarkeit
- Prüft auf Vorhandensein der Datei `/var/lib/cloud/instance/boot-finished`
- Blockiert bis cloud-init komplett abgeschlossen ist

#### Worker Nodes ❌
**Datei:** `main.tf:105-118`

Die Worker Nodes haben **KEINE** entsprechende Überprüfung:

```terraform
resource "null_resource" "run_join_script" {
  depends_on = [null_resource.wait_for_control_plane_ssh]  # <-- Nur CP, nicht Worker!

  provisioner "local-exec" {
    command = <<EOT
chmod +x ./scripts/join-workers.sh && ./scripts/join-workers.sh "${self.triggers.worker_ips}" "${join(",", [for droplet in digitalocean_droplet.k8s_nodes : droplet.ipv4_address_private])}"
EOT
  }

  triggers = {
    worker_ips = join(",", [for droplet in digitalocean_droplet.k8s_nodes : droplet.ipv4_address])
  }
}
```

**Problem:**
- Das Skript `join-workers.sh` wird ausgeführt, sobald nur die Control Plane bereit ist
- Es wird **nicht** gewartet, bis die Worker Nodes cloud-init abgeschlossen haben
- Das führt zu Fehlern bei der Ausführung von `kubeadm join` (Zeile 86 in join-workers.sh), weil kubeadm noch nicht installiert ist

#### Join Workers Script
**Datei:** `scripts/join-workers.sh:70-88`

Das Skript versucht direkt `kubeadm join` auf den Worker Nodes auszuführen:

```bash
for i in "${!WORKERS[@]}"; do
  IP="${WORKERS[$i]}"
  IP_PRIVATE="${WORKERS_PRIVATE[$i]}"
  echo "[INFO] Joining worker $IP..."

  ssh -o StrictHostKeyChecking=no -i $KEY root@$IP <<EOF
cat <<JOIN > tmp_join_config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
# ... config ...
JOIN

kubeadm join --config tmp_join_config.yaml  # <-- Schlägt fehl wenn kubeadm nicht installiert
EOF
done
```

### Root Cause

Das `null_resource.run_join_script` hängt nur von `wait_for_control_plane_ssh` ab, **nicht aber von einer entsprechenden Überprüfung der Worker Nodes**. Dies führt zu einem Race Condition:

1. Control Plane startet und cloud-init läuft
2. Worker Nodes starten und cloud-init läuft (parallel)
3. Control Plane cloud-init fertig → `wait_for_control_plane_ssh` completed
4. `run_join_script` wird sofort getriggert
5. **Problem:** Worker cloud-init läuft möglicherweise noch
6. `kubeadm join` schlägt fehl, weil kubeadm noch nicht installiert ist

### Requirements

#### Functional Requirements

1. **FR-1:** Worker Nodes müssen auf vollständigen Abschluss von cloud-init warten
   - Ähnlich wie Control Plane
   - Prüfung der Datei `/var/lib/cloud/instance/boot-finished`

2. **FR-2:** Das `run_join_script` darf erst starten, wenn **alle** Worker Nodes bereit sind
   - Abhängigkeit zu allen Worker cloud-init Checks
   - Nicht nur zur Control Plane

3. **FR-3:** Fehlerbehandlung und Logging
   - Klare Log-Ausgaben für jeden Worker Node
   - Timeout-Handling (max. 5 Minuten wie bei Control Plane)

#### Non-Functional Requirements

1. **NFR-1:** Parallele Ausführung wo möglich
   - Worker cloud-init Checks sollten parallel laufen
   - Nicht sequenziell, um Zeit zu sparen

2. **NFR-2:** Konsistenz mit bestehendem Pattern
   - Gleicher Mechanismus wie bei Control Plane
   - Verwendung von `null_resource` mit `remote-exec`

### Proposed Solution

#### Implementation Plan

1. **Erstelle wait_for_worker_ssh Ressourcen**
   - Eine `null_resource` für jeden Worker Node (Index 1-3)
   - Analog zu `wait_for_control_plane_ssh`
   - Prüfung auf `/var/lib/cloud/instance/boot-finished`

2. **Aktualisiere run_join_script Dependencies**
   - `depends_on` muss alle Worker wait Ressourcen enthalten
   - Plus die Control Plane wait Ressource

3. **Teste das Deployment**
   - Vollständiger destroy/apply Zyklus
   - Verifikation, dass join-workers.sh erst läuft, wenn alle Nodes bereit sind

### Testing Requirements

#### Automated Testing Authorization

**Budget Approval:** EUR 100,00 auf DigitalOcean

**Testing Mandate:**
- Automatische Tests sind **verpflichtend** durchzuführen
- Keine manuelle Bestätigung erforderlich für Test-Deployments
- Budget-Rahmen: Bis zu EUR 100,00 für vollständige Testzyklen

#### Test Scope

1. **Initial Implementation Test**
   - `terraform destroy -auto-approve` (falls vorhanden)
   - `terraform apply -auto-approve`
   - Verifikation: Alle Nodes zeigen "cloud-init done" in Logs
   - Verifikation: `kubeadm join` läuft erfolgreich auf allen Workern
   - Verifikation: `kubectl get nodes` zeigt alle 4 Nodes als Ready

2. **Reliability Test**
   - Mindestens 2 vollständige destroy/apply Zyklen
   - Konsistenz-Check: Beide Durchläufe müssen erfolgreich sein
   - Timing-Messung: Dokumentation wie lange cloud-init pro Node dauert

3. **Rollback Test**
   - Nach erfolgreichen Tests: `terraform destroy -auto-approve`
   - Cleanup aller Ressourcen
   - Kostenoptimierung: Keine laufenden Droplets nach Tests

#### Test Execution Protocol

```bash
# Test Zyklus 1
terraform destroy -auto-approve
terraform apply -auto-approve
kubectl get nodes -o wide
# Dokumentiere Ergebnisse

# Test Zyklus 2 (Reliability)
terraform destroy -auto-approve
terraform apply -auto-approve
kubectl get nodes -o wide
# Dokumentiere Ergebnisse

# Cleanup
terraform destroy -auto-approve
```

#### Test Success Criteria

- [ ] Alle Tests laufen durch ohne Fehler
- [ ] Keine manuellen Eingriffe während des Deployments nötig
- [ ] Cloud-init Logs zeigen korrektes Warten auf allen Nodes
- [ ] Join-workers.sh startet erst nach allen cloud-init Abschlüssen
- [ ] Gesamtkosten bleiben unter EUR 100,00

### Success Criteria

- [ ] Worker Nodes warten auf cloud-init Abschluss vor join
- [ ] Keine Fehler beim Ausführen von `kubeadm join`
- [ ] Deployment läuft zuverlässig durch ohne manuelle Intervention
- [ ] Logs zeigen klare Fortschritts-Meldungen für jeden Node

### Files to Modify

- `main.tf` - Hinzufügen der Worker wait Ressourcen und Anpassung der Dependencies

### Related Files

- `cloud-init/setup-k8s-node.sh` - Cloud-init Script (keine Änderung nötig)
- `scripts/join-workers.sh` - Join Script (keine Änderung nötig)

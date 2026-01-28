
# -----------------------------
# DNS ENTRY (Wildcard pro Benutzer)
# Nutzt eine Datenquelle, um die IP des Ingress-Service aus dem Cluster abzurufen,
# nachdem dieser via Helm erstellt wurde. Damit wird die externe IP zuverlässig abgefragt.
# -----------------------------


resource "null_resource" "make_get_ingress_ip_executable" {
  provisioner "local-exec" {
    command = "chmod +x scripts/tools/get_ingress_ip.sh"
  }

  triggers = {
    script_modified = filemd5("scripts/tools/get_ingress_ip.sh")
  }
}


data "external" "ingress_data" {
  depends_on = [null_resource.run_helm_install, null_resource.make_get_ingress_ip_executable]
  program = ["scripts/tools/get_ingress_ip.sh"]
}


resource "digitalocean_record" "ingress_dns_wildcard_user" {
  domain = "do.t3isp.de"
  type   = "A"
  name   = "*.${data.external.current_user.result["user"]}"
  value  = data.external.ingress_data.result["ingress_ip"]
}



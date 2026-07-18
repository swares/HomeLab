# Pi-hole local DNS records — lab.home.arpa zone
#
# These records are the load-bearing DNS entries for the k3s cluster.
# Changing them incorrectly will break all ingress access.
#
# Architecture:
#   api.lab.home.arpa     → 192.168.1.200  (kube-vip VIP — k8s API server)
#   *.apps.lab.home.arpa  → 192.168.1.160  (Traefik ingress — all workload ingresses)
#
# Pi-hole wildcard DNS: the pihole provider supports individual CNAME records.
# The *.apps wildcard is handled by Pi-hole's "Local DNS → CNAME Records" using
# a CNAME target pointing to apps.lab.home.arpa, which is itself an A record.
# Each explicit hostname below overrides the wildcard where needed.

# ── Cluster infrastructure ────────────────────────────────────────────────

resource "pihole_dns_record" "kube_api" {
  domain = "api.lab.home.arpa"
  ip     = "192.168.1.200"
}

# Wildcard anchor — *.apps.lab.home.arpa CNAMEs point here
resource "pihole_dns_record" "traefik_ingress" {
  domain = "apps.lab.home.arpa"
  ip     = "192.168.1.160"
}

# ── Node addresses ─────────────────────────────────────────────────────────

resource "pihole_dns_record" "odroid_h4" {
  domain = "odroid-nas.lab.home.arpa"
  ip     = "192.168.1.160"
}

resource "pihole_dns_record" "opi5pro_1" {
  domain = "opi5pro-1.lab.home.arpa"
  ip     = "192.168.1.168"
}

resource "pihole_dns_record" "opi5pro_2" {
  domain = "opi5pro-2.lab.home.arpa"
  ip     = "192.168.1.172"
}

resource "pihole_dns_record" "rpi5" {
  domain = "vault.lab.home.arpa"
  ip     = "192.168.1.128"
}

resource "pihole_dns_record" "rpi4b" {
  domain = "pihole.lab.home.arpa"
  ip     = "192.168.1.116"   # RPi 4B — Pi-hole secondary DNS
}

# ── CNAME records for workload ingresses ──────────────────────────────────
# Each of these resolves via the wildcard but is explicit here so the
# DNS intent is documented and Renovate/audit can track FQDNs.

resource "pihole_cname_record" "argocd" {
  domain = "argocd.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "grafana" {
  domain = "grafana.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "immich" {
  domain = "immich.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "auth" {
  domain = "auth.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "minio_api" {
  domain = "minio.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "minio_console" {
  domain = "minio-console.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "semaphore" {
  domain = "semaphore.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "registry" {
  domain = "registry.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

resource "pihole_cname_record" "whisper" {
  domain = "whisper.apps.lab.home.arpa"
  target = "apps.lab.home.arpa"
}

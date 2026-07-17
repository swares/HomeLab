output "dns_records" {
  description = "All managed DNS A records"
  value = {
    kube_api       = pihole_dns_record.kube_api.domain
    traefik        = pihole_dns_record.traefik_ingress.domain
    odroid_h4      = pihole_dns_record.odroid_h4.domain
    opi5pro_1      = pihole_dns_record.opi5pro_1.domain
    opi5pro_2      = pihole_dns_record.opi5pro_2.domain
    rpi5_vault     = pihole_dns_record.rpi5.domain
    rpi4b_pihole   = pihole_dns_record.rpi4b.domain
  }
}

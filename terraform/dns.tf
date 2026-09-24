# scout-tools.de is used for testing this new setup — its Azure DNS zone is
# owned and managed by the OLD repo's Terraform state (azure/domain.tf in
# azure-infrastructure), so this is a read-only reference plus the records
# below, which this repo's state owns. "auth" and "wiki" are both commented
# out over there (not created), so there's no collision — if either is ever
# un-commented in the old repo, remove the matching resource below first to
# avoid two states fighting over the same record.
data "azurerm_dns_zone" "scout_tools" {
  name                = "scout-tools.de"
  resource_group_name = var.OLD_REPO_RESOURCE_GROUP
}

resource "azurerm_dns_a_record" "auth" {
  name                = "auth"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "auth" {
  name                = "auth"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

resource "azurerm_dns_a_record" "wiki" {
  name                = "wiki"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "wiki" {
  name                = "wiki"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

# Test names for the Nextcloud copy (Phase 3). These two records predate this
# repo: they were created by azure-infrastructure (pointing at the AKS ingress)
# and handed over on 24.09.2026 via `terraform state rm` there — they are NOT
# created here, they have to be imported once before the first apply that
# contains them (see MIGRATION.md, Phase 3, and the commands below):
#
#   # Built by hand, not from `az network dns zone show`: that returns "dnszones"
#   # and "infra" in lower case, which the provider rejects.
#   Z="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/Infra/providers/Microsoft.Network/dnsZones/scout-tools.de"
#   terraform import azurerm_dns_a_record.cloud     "$Z/A/cloud"
#   terraform import azurerm_dns_aaaa_record.cloud  "$Z/AAAA/cloud"
#   terraform import azurerm_dns_a_record.office    "$Z/A/office"
#   terraform import azurerm_dns_aaaa_record.office "$Z/AAAA/office"
#
# (Import blocks would do this declaratively, but Terraform 1.5 only accepts a
# literal id there, which would put the subscription id into this public repo.)
resource "azurerm_dns_a_record" "cloud" {
  name                = "cloud"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "cloud" {
  name                = "cloud"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

resource "azurerm_dns_a_record" "office" {
  name                = "office"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "office" {
  name                = "office"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

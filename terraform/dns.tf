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

resource "azurerm_dns_a_record" "wiki" {
  name                = "wiki"
  zone_name           = data.azurerm_dns_zone.scout_tools.name
  resource_group_name = data.azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

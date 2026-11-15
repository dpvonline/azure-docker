# scout-tools.de is used for testing this new setup. Its Azure DNS zone is
# owned by this repo's state (the old azure-infrastructure repo no longer has
# one), in the same resource group as everything else. Goes away together with
# the test domain once the production cutover is done (see MIGRATION.md).
resource "azurerm_dns_zone" "scout_tools" {
  name                = "scout-tools.de"
  resource_group_name = azurerm_resource_group.core.name
  tags                = var.TAGS
}

resource "azurerm_dns_a_record" "auth" {
  name                = "auth"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "auth" {
  name                = "auth"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

resource "azurerm_dns_a_record" "wiki" {
  name                = "wiki"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "wiki" {
  name                = "wiki"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

# Test names for the Nextcloud copy (Phase 3).
resource "azurerm_dns_a_record" "cloud" {
  name                = "cloud"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "cloud" {
  name                = "cloud"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

resource "azurerm_dns_a_record" "office" {
  name                = "office"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm.id
}

resource "azurerm_dns_aaaa_record" "office" {
  name                = "office"
  zone_name           = azurerm_dns_zone.scout_tools.name
  resource_group_name = azurerm_dns_zone.scout_tools.resource_group_name
  ttl                 = 60
  target_resource_id  = azurerm_public_ip.vm_v6.id
}

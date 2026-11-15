# scout-tools.de: kept for later use, currently without records of its own. The test
# names auth/wiki/cloud/office lived here until the cutovers moved the services to
# dpvonline.de (whose DNS is at IONOS, not in Azure).
#
# The zone was created by the old repo (azure-infrastructure) in resource group
# "Infra" and moved here with `az resource move` when AKS was torn down (see
# MIGRATION.md, "Zwischenschritt — AKS abreißen"). Moved, not recreated: the name
# servers belong to the zone object, and they're what the registrar delegates to. A
# new zone with the same name gets a different set, and the domain stops resolving
# until the delegation is changed. That's also why it can't be destroyed from here.
#
# Imported once after the move:
#
#   # Built by hand, not from `az network dns zone show`: that returns "dnszones"
#   # in lower case, which the provider rejects.
#   terraform import azurerm_dns_zone.scout_tools \
#     "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-dpv-core/providers/Microsoft.Network/dnsZones/scout-tools.de"
#
# (Import blocks would do this declaratively, but Terraform 1.5 only accepts a
# literal id there, which would put the subscription id into this public repo.)
resource "azurerm_dns_zone" "scout_tools" {
  name                = "scout-tools.de"
  resource_group_name = azurerm_resource_group.core.name
  tags                = var.TAGS

  lifecycle {
    prevent_destroy = true
  }
}

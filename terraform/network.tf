resource "azurerm_resource_group" "core" {
  name     = "rg-dpv-core"
  location = var.REGION
  tags     = var.TAGS
}

resource "azurerm_virtual_network" "core" {
  name                = "vnet-dpv-core"
  resource_group_name = azurerm_resource_group.core.name
  location            = azurerm_resource_group.core.location
  # IPv6: a unique local /48 (fd00::/8), Azure hands out one /64 per subnet from it.
  # The public IPv6 address sits on its own public IP resource below.
  address_space = ["10.20.0.0/16", "fdc7:3b1e:9a20::/48"]
  tags          = var.TAGS
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.core.name
  virtual_network_name = azurerm_virtual_network.core.name
  address_prefixes     = ["10.20.1.0/24", "fdc7:3b1e:9a20:1::/64"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  tags                = var.TAGS

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSSH"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.ADMIN_IP_CIDRS
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_public_ip" "vm" {
  name                = "pip-dpv-core"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1"]
  tags                = var.TAGS
}

# IPv6 counterpart of pip-dpv-core. Needed because the production records for
# auth. and wiki.dpvonline.de carry AAAA records; without an IPv6 address on the
# VM those would have to be deleted at the cutover, and browsers that prefer
# IPv6 would otherwise keep going to the old address.
resource "azurerm_public_ip" "vm_v6" {
  name                = "pip-dpv-core-v6"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = "IPv6"
  zones               = ["1"]
  tags                = var.TAGS
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-dpv-core"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  tags                = var.TAGS

  ip_configuration {
    name                          = "internal"
    primary                       = true
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }

  # The guest picks this up via DHCPv6. cloud-init only writes `dhcp6: true`
  # into netplan if the address exists when it renders the network config,
  # which on Azure happens on every boot — so on a VM that predates this
  # block, a reboot is needed once (see README).
  ip_configuration {
    name                          = "internal-v6"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_version    = "IPv6"
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_v6.id
  }
}

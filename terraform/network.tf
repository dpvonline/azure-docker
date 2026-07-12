resource "azurerm_resource_group" "core" {
  name     = "rg-dpv-core"
  location = var.REGION
  tags     = var.TAGS
}

resource "azurerm_virtual_network" "core" {
  name                = "vnet-dpv-core"
  resource_group_name = azurerm_resource_group.core.name
  location            = azurerm_resource_group.core.location
  address_space       = ["10.20.0.0/16"]
  tags                = var.TAGS
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.core.name
  virtual_network_name = azurerm_virtual_network.core.name
  address_prefixes     = ["10.20.1.0/24"]
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

resource "azurerm_network_interface" "vm" {
  name                = "nic-dpv-core"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  tags                = var.TAGS

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

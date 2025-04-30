terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0.0"
    }
  }
  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-secure-funcapp01"
  location = "East US"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-funcapp"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet_pe" {
  name                 = "subnet-private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "subnet_vnet_integration" {
  name                 = "subnet-vnet-integration"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_service_plan" "asp" {
  name                         = "asp-funcapp-ep1"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  os_type                      = "Windows"
  sku_name                     = "EP1"
  maximum_elastic_worker_count = 20
  worker_count                 = 1
}

resource "azurerm_storage_account" "storage" {
  name                            = "funcstorage${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
}

resource "azurerm_storage_share" "share" {
  name               = "fileshares"
  storage_account_id = azurerm_storage_account.storage.id
  quota              = 5120
}

resource "azurerm_windows_function_app" "func" {
  depends_on = [
    azurerm_storage_account.storage,
    azurerm_storage_share.share,
     azurerm_private_endpoint.blob_pe,
     azurerm_private_dns_zone.blob_dns,
     azurerm_private_dns_zone.file_dns,
     azurerm_private_dns_zone_virtual_network_link.blob_link,
     azurerm_private_dns_zone_virtual_network_link.file_link,
     azurerm_private_dns_zone_virtual_network_link.func_link ]
  name                        = "funcappdemo-${random_string.suffix.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  service_plan_id             = azurerm_service_plan.asp.id
  storage_account_name        = azurerm_storage_account.storage.name
  storage_account_access_key  = azurerm_storage_account.storage.primary_access_key
  functions_extension_version = "~4"
  virtual_network_subnet_id   = azurerm_subnet.subnet_vnet_integration.id
  public_network_access_enabled = false

  site_config {
    always_on = true
  }

  app_settings = {
      AzureWebJobsStorage   = azurerm_storage_account.storage.primary_access_key
      WEBSITE_RUN_FROM_PACKAGE = "1"
      FUNCTIONS_WORKER_RUNTIME                 = "dotnet-isolated"
      WEBSITE_CONTENTAZUREFILECONNECTIONSTRING = azurerm_storage_account.storage.primary_connection_string
      WEBSITE_CONTENTSHARE                     = azurerm_storage_share.share.name
      vnetrouteallenabled                      = true
      WEBSITE_VNET_ROUTE_ALL                   = "1"
      WEBSITE_DNS_SERVER                       = "168.63.129.16"
      WEBSITE_CONTENTOVERVNET                  = "1"
      
  }

  identity {
    type = "SystemAssigned"
  }
}

### DNS Zones
resource "azurerm_private_dns_zone" "func_dns" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "blob_dns" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "file_dns" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

### DNS Zone Links
resource "azurerm_private_dns_zone_virtual_network_link" "func_link" {
  name                  = "func-link"
  private_dns_zone_name = azurerm_private_dns_zone.func_dns.name
  resource_group_name   = azurerm_resource_group.rg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_link" {
  name                  = "blob-link"
  private_dns_zone_name = azurerm_private_dns_zone.blob_dns.name
  resource_group_name   = azurerm_resource_group.rg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "file_link" {
  name                  = "file-link"
  private_dns_zone_name = azurerm_private_dns_zone.file_dns.name
  resource_group_name   = azurerm_resource_group.rg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

### Private Endpoints

# Function App PE
resource "azurerm_private_endpoint" "func_pe" {
  name                = "pe-funcapp"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-funcapp"
    private_connection_resource_id = azurerm_windows_function_app.func.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-func"
    private_dns_zone_ids = [azurerm_private_dns_zone.func_dns.id]
  }
}

# Storage Blob PE
resource "azurerm_private_endpoint" "blob_pe" {
  name                = "pe-blob"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob_dns.id]
  }
}

# Storage File PE
resource "azurerm_private_endpoint" "file_pe" {
  name                = "pe-file"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-file"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-file"
    private_dns_zone_ids = [azurerm_private_dns_zone.file_dns.id]
  }
}

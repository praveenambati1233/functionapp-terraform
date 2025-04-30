resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-secure-funcapp"
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
  service_endpoints    = ["Microsoft.Storage"]
}

resource "azurerm_storage_account" "storage" {
  name                            = "funcstorage${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  network_rules {
    default_action             = "Deny"
    virtual_network_subnet_ids = [azurerm_subnet.subnet_pe.id]
    bypass                     = ["AzureServices"]
  }

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
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
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
  zone_balancing_enabled       = false
}

resource "azurerm_storage_share" "share" {
  name               = "fileshares"
  storage_account_id = azurerm_storage_account.storage.id
  quota              = 5120
  depends_on         = [azurerm_private_endpoint.storage_file]
}
resource "azurerm_private_endpoint" "storage_file" {
  name                = "pep-storage-file"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-file"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }
}

resource "azurerm_windows_function_app" "func" {
  
  name                        = "funcapp-${random_string.suffix.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  service_plan_id             = azurerm_service_plan.asp.id
  storage_account_name        = azurerm_storage_account.storage.name
  storage_account_access_key  = azurerm_storage_account.storage.primary_access_key
  functions_extension_version = "~4"
  virtual_network_subnet_id  = azurerm_subnet.subnet_vnet_integration.id

  site_config {
    always_on                   = true
    vnet_route_all_enabled      = true
    scm_use_main_ip_restriction = true
  }
  app_settings = {
      AzureWebJobsStorage   = azurerm_storage_account.storage.shared_access_key_enabled
      WEBSITE_RUN_FROM_PACKAGE = "1"
      FUNCTIONS_WORKER_RUNTIME                 = "dotnet-isolated"
      WEBSITE_CONTENTAZUREFILECONNECTIONSTRING = azurerm_storage_account.storage.primary_connection_string
      WEBSITE_CONTENTSHARE                     = azurerm_storage_share.share.name
      WEBSITE_VNET_ROUTE_ALL                   = "1"
      WEBSITE_DNS_SERVER                       = "168.63.129.16"
      WEBSITE_CONTENTOVERVNET                  = "1"
      vnetrouteallenabled                      = true
    }
  
  identity {
    type = "SystemAssigned"
  }

}

resource "azurerm_private_endpoint" "func_pe" {
  name                = "pe-funcapp-1"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-funcapp-1"
    private_connection_resource_id = azurerm_windows_function_app.func.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "privatedns" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dnslink" {
  name                  = "dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.privatedns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_a_record" "dnsrecord" {
  name                = azurerm_windows_function_app.func.name
  zone_name           = azurerm_private_dns_zone.privatedns.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.func_pe.private_service_connection[0].private_ip_address]
}

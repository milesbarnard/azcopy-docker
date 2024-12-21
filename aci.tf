data "azurerm_client_config" "current" {}

# create key vault with rbac
resource "azurerm_key_vault" "aci" {
  name                      = "acikv"
  location                  = azurerm_resource_group.aci.location
  resource_group_name       = azurerm_resource_group.aci.name
  sku_name                  = "standard"
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  enable_rbac_authorization = true

  tags = {
    environment = "prod"
    project     = "aci"
  }

  lifecycle {
    ignore_changes = [
      tenant_id # Prevents replacement triggers by use of data from azurerm_client_config
    ]
  }
}

resource "azurerm_role_assignment" "aci" {
  scope                = azurerm_key_vault.aci.id
  role_definition_name = "Key Vault Secrets Reader"
  principal_id         = data.azurerm_client_config.current.object_id
}

# get SAS token from key vault
data "azurerm_key_vault_secret" "source_sas token" {
  name         = "source-sas-token"
  key_vault_id = azurerm_key_vault.aci.id
}

# get destination SAS token from key vault
data "azurerm_key_vault_secret" "destination_sas_token" {
  name         = "destination-sas-token"
  key_vault_id = azurerm_key_vault.aci.id
}

# If using custom image or cache
data "azurerm_container_registry" "aci" {
  name                = "aciacr"
  resource_group_name = azurerm_resource_group.aci.name
}

# user assigned identity
resource "azurerm_user_assigned_identity" "aci" {
  name                = "aci"
  location            = azurerm_resource_group.aci.location
  resource_group_name = azurerm_resource_group.aci.name
}

# role assignment for container group to pull image from acr
resource "azurerm_role_assignment" "aci_acr" {
  scope                = data.azurerm_container_registry.aci.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aci.principal_id
}

# create aci
resource "azurerm_container_group" "aci" {
  name                = "aci"
  location            = azurerm_resource_group.aci.location
  resource_group_name = azurerm_resource_group.aci.name
  ip_address_type     = "Private"
  os_type             = "Linux"
  restart_policy      = "Never"

  container {
    name   = "azcopy"
    image  = "peterdavehello/azcopy:10"
    cpu    = "4"
    memory = "16"
    commands = ["azcopy", "copy", "https://mydata.file.core.windows.net/myfolder${data.azurerm_key_vault_secret.source_sas_token.value}", "https://mydata.blob.core.windows.net/myfolder${data.azurerm_key_vault_secret.destination_sas_token.value}",
    "--recursive", "--from-to", "FileBlob", "--quiet"]
    ports {
      port     = 9998
      protocol = "UDP"
    }

  }

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.aci.id
    ]
  }

  image_registry_credential {
    user_assigned_identity_id = azurerm_role_assignment.aci_acr.principal_id
    server                    = "aciacr.azurecr.io"
  }

  tags = {
    environment = "prod"
    project     = "aci"
  }
}

variable "SUBSCRIPTION_ID" {
  type      = string
  sensitive = true
}

variable "REGION" {
  type    = string
  default = "germanywestcentral"
}

variable "STATE_STORAGE_ACCOUNT_NAME" {
  type        = string
  description = "Globally unique across all of Azure, 3-24 lowercase letters/digits only, e.g. dpvtfstate01"
}

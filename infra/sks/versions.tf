terraform {
  required_version = ">= 1.6"

  required_providers {
    exoscale = {
      source = "exoscale/exoscale"
    }
  }
}

provider "exoscale" {}

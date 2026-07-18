terraform {
  required_version = ">= 1.6"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      # renovate: datasource=github-releases depName=dmacvicar/terraform-provider-libvirt
      version = "~> 0.8"
    }
  }

  # Minio S3 backend — same bucket as dns module, separate key.
  # Init: tofu init -backend-config=../../backend.hcl
  backend "s3" {
    bucket = "tofu-state"
    key    = "vms/terraform.tfstate"
    region = "us-east-1"

    endpoints = {
      s3 = "http://minio-api.minio.svc:9000"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

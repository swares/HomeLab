terraform {
  required_version = ">= 1.6"

  required_providers {
    pihole = {
      # Community provider — supports Pi-hole v5 API.
      # Pi-hole v6 changed the API; if you upgrade Pi-hole, check:
      # https://registry.terraform.io/providers/ryanwholey/pihole/latest
      source  = "ryanwholey/pihole"
      # renovate: datasource=github-releases depName=ryanwholey/terraform-provider-pihole
      version = "~> 0.2"
    }
  }

  # Minio S3 backend — state stored in the in-cluster Minio instance.
  # Run `tofu init` with these env vars set:
  #   AWS_ACCESS_KEY_ID     = Minio root-user (from Vault: secret/lab/minio root-user)
  #   AWS_SECRET_ACCESS_KEY = Minio root-password (from Vault: secret/lab/minio root-password)
  #
  # From inside the cluster (GitLab runner): endpoint = http://minio-api.minio.svc:9000
  # From outside the cluster (laptop):       endpoint = https://minio.apps.lab.home.arpa
  backend "s3" {
    bucket = "tofu-state"
    key    = "dns/terraform.tfstate"
    region = "us-east-1"   # required field; ignored by Minio

    # Override endpoint via TF_BACKEND_S3_ENDPOINT env var or -backend-config flag:
    #   tofu init -backend-config="endpoints={s3=http://minio-api.minio.svc:9000}"
    endpoints = {
      s3 = "http://minio-api.minio.svc:9000"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}

provider "pihole" {
  url      = var.pihole_url
  password = var.pihole_password
}

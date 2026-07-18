terraform {
  required_version = ">= 1.6"

  required_providers {
    pihole = {
      # ryanwholey/pihole v0.2 supports Pi-hole v5 API only.
      # Pi-hole v6 changed the auth mechanism (session → Bearer token);
      # this provider fails with "session ID not found in response".
      # BLOCKED: no v6-compatible provider confirmed available as of 2026-07-18.
      # DNS is managed via ansible/playbooks/dns.yml in the interim.
      # Re-evaluate when a Pi-hole v6 provider is available.
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

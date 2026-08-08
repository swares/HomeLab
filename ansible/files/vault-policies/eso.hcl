path "secret/data/lab/*" {
  capabilities = ["read"]
}
path "secret/metadata/lab/*" {
  capabilities = ["read", "list"]
}

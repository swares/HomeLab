# Allow an entity to inspect its own registration information
path "agent-registry/registration/entity_id/{{identity.entity.id}}" {
  capabilities = ["read"]
}

# Allow an entity to read the default policies
path "policy/default" {
  capabilities = ["read"]
}
path "policy/default-ceiling" {
  capabilities = ["read"]
}

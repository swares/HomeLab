# SSO — Authelia OIDC Status

Authelia v4.39 is the OIDC provider for the lab, backed by LLDAP for the user directory.
All clients use `authorization_code` flow with `client_secret_post` auth method.

The Authelia configmap (`gitops/workloads/authelia/configmap.yaml`) holds all client
registrations. Client secrets are argon2id hashes; plaintext secrets live in Vault under
`secret/lab/<service>` → `oidc-client-secret`.

---

## Completed

| Service | URL | Notes |
|---------|-----|-------|
| Grafana | `grafana.apps.lab.home.arpa` | Generic OAuth via `auth.generic_oauth`; calls userinfo endpoint |
| ArgoCD | `argocd.apps.lab.home.arpa` | Native OIDC in `argocd-cm`; rootCA required for lab CA trust; groups claim → RBAC |
| Immich | `immich.apps.lab.home.arpa` | openid-client v6 / oauth4webapi; calls userinfo endpoint |
| MinIO Console | `minio-console.apps.lab.home.arpa` | Env var config; calls userinfo endpoint |
| Semaphore | `semaphore.apps.lab.home.arpa` | Config via ESO-rendered `config.json` Secret; `claims_policy: include_profile_in_id_token` required — go-oidc reads ID token only |
| LiteLLM | `ai.apps.lab.home.arpa` | Traefik ForwardAuth (`authelia-forwardauth@kubernetescrd`). UI (`/`) requires one_factor login. `/v1/` and `/health/` bypass auth so API callers are unaffected. |

---

## Not Done / Blocked

| Service | URL | Reason |
|---------|-----|--------|
| Zot | `registry.apps.lab.home.arpa` | Zot v2.1.x only accepts `github`/`google`/`gitlab` as provider names. Generic OIDC (`authelia`, `dex`, etc.) crashes with *unsupported openid/oauth2 provider*. Also deprecated `clientid`/`clientsecret` inline — new `credentialsfile` approach not yet tested. Revisit on Zot upgrade. |
| Home Assistant | `ha.apps.lab.home.arpa` | No native OIDC support. Would require a custom integration or Traefik ForwardAuth (which only gates the ingress, not HA's own auth layer). Not worth the complexity. |
| LiteLLM | `ai.apps.lab.home.arpa` | ForwardAuth at ingress level (see Completed above). Native OIDC via `GENERIC_CLIENT_ID` would require a database — not worth it for a single-user lab. |
| Vault | No public ingress | Vault has a native OIDC auth method. Useful for ditching Vault tokens for day-to-day admin. Not yet implemented. |
| LLDAP | `lldap.apps.lab.home.arpa` | LLDAP is the identity provider — SSO into it would be circular. Skip. |
| Whisper/STT | `stt.apps.lab.home.arpa` | API only, no interactive web UI. |

---

## Architecture Notes

### Claims policy
Authelia v4.38+ moved profile claims (`email`, `name`, `preferred_username`) out of the
ID token and into the userinfo endpoint only. Clients that read claims from the ID token
directly (go-oidc without userinfo call — e.g. Semaphore) get an empty email claim.

Fix: add a `claims_policy` to the Authelia OIDC config and reference it on the client:

```yaml
identity_providers:
  oidc:
    claims_policies:
      include_profile_in_id_token:
        id_token:
          - email
          - email_verified
          - name
          - preferred_username
```

Apply to clients that need it with `claims_policy: include_profile_in_id_token`.
Clients that call the userinfo endpoint (Grafana, ArgoCD, Immich, MinIO) do not need it.

### Hairpin NAT / in-cluster DNS
Pods can't reach the kube-vip VIP (`192.168.1.160`) from inside the cluster. Any
service that does server-side OIDC token exchange (all of the above) must resolve
`authelia.apps.lab.home.arpa` to the Traefik ClusterIP instead.

Fix: CoreDNS custom config (`gitops/workloads/coredns-custom/configmap.yaml`) has a
more-specific zone for `authelia.apps.lab.home.arpa` → `10.43.10.71` (Traefik ClusterIP).
Verify Traefik ClusterIP with `kubectl get svc -n kube-system traefik`.

### Lab CA trust
Authelia uses a cert signed by the lab root CA. Clients that do TLS verification for
server-side OIDC calls need to trust this CA.

| Client | How CA is trusted |
|--------|------------------|
| ArgoCD | `rootCA:` field in `oidc.config` in `argocd-cm` |
| Semaphore | `lab-ca-bundle` ConfigMap mounted; `SSL_CERT_FILE=/etc/ssl/lab/ca.crt` env var |
| Zot | Same pattern as Semaphore (prepared but reverted with OIDC) |

### Reloader annotation
Authelia Deployment has `reloader.stakater.com/auto: "true"` so configmap changes
(new clients, secret rotation) trigger automatic pod restarts without manual
`kubectl rollout restart`.

### ESO pattern for secrets in config files
Some services (Semaphore, Zot) embed the OIDC client secret directly in their config
file rather than reading it from an env var. For these, an ExternalSecret with an ESO
`target.template` renders the full config file as a Secret with the secret injected:

```yaml
target:
  name: semaphore-oidc-config
  creationPolicy: Owner
  template:
    data:
      config.json: |
        { ..., "clientsecret": "{{ .oidcClientSecret }}" }
data:
  - secretKey: oidcClientSecret
    remoteRef:
      key: secret/lab/semaphore
      property: oidc-client-secret
```

The Deployment mounts this Secret instead of the ConfigMap.

---

## Adding a New Client

1. Generate plaintext secret on H4:
   ```bash
   SECRET=$(openssl rand -hex 32)
   vault kv patch secret/lab/<service> oidc-client-secret=$SECRET
   echo $SECRET
   ```

2. Generate argon2id hash:
   ```bash
   kubectl run argon2 --rm -i --restart=Never \
     --image=ghcr.io/authelia/authelia:4.39 \
     -- authelia crypto hash generate argon2 --password "$SECRET"
   ```

3. Add client to `gitops/workloads/authelia/configmap.yaml` with the hash.

4. Wire the plaintext into the target service (env var or ESO template).

5. Open PR. After merge, Reloader restarts Authelia automatically.

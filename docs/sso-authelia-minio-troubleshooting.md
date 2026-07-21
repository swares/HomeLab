# Authelia + MinIO OIDC SSO — Implementation & Troubleshooting Log

This document captures every issue encountered wiring MinIO Console to Authelia as an OIDC provider, in the order they appeared. Useful as a reference for subsequent OIDC integrations (Grafana, ArgoCD) and for anyone hitting the same wall.

## Architecture

- **IDP:** Authelia v4.39 (2 replicas on opi5pro-1/opi5pro-2, Postgres backend, LLDAP user directory)
- **Client:** MinIO Console (native OIDC via `MINIO_IDENTITY_OPENID_*` env vars)
- **Ingress:** Traefik (k3s default), TLS terminated with lab CA (ECDSA P-256)
- **Session storage:** fasthttp/session → Postgres (no Redis)
- **DNS:** `*.apps.lab.home.arpa` → 192.168.1.160 (kube-vip VIP, Traefik)

---

## Issue 1: `consoleAdmin` policy not defined on MinIO startup

**Symptom:**
```
The policies "[consoleAdmin]" mapped to role ARN ... are not defined
```
MinIO logged a critical error on startup and the OIDC role policy was rejected.

**How it was found:** MinIO pod logs on startup:
```bash
kubectl logs -n minio deploy/minio --tail=50
```

**Cause:** MinIO's role validator checks IAM storage only, not built-in policies. Even though `consoleAdmin` is a built-in MinIO policy, it must exist in IAM storage before it can be referenced via `MINIO_IDENTITY_OPENID_ROLE_POLICY`.

**Resolution:** Create the policy explicitly via the `mc` client inside the MinIO pod:
```bash
# Exec into the pod and set up mc alias, then create the policy
kubectl exec -n minio deploy/minio -- sh -c "
  mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD
  mc admin policy create local consoleAdmin /dev/stdin << 'POLICY'
{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"admin:*\"]}]}
POLICY"

# Verify
kubectl exec -n minio deploy/minio -- mc admin policy list local
```

---

## Issue 2: `token_endpoint_auth_method: client_secret_basic` rejected

**Symptom:** Authelia accepted the authorization request and redirected MinIO to the callback URL, but MinIO's token exchange request to `/api/oidc/token` was rejected with an auth error. No token was issued.

**How it was found:** Authelia debug logs (enabled via configmap `log.level: debug`) showed the token endpoint rejecting the request. MinIO logs showed `"invalid session"` on the callback. Browser DevTools showed `GET /api/v1/session → 403` from MinIO after the OAuth redirect.

```bash
# Tail Authelia logs during a login attempt
kubectl logs -n authelia -l app=authelia -f | grep -v "408\|ntp"
```

**Cause:** Go's `golang.org/x/oauth2` library (used by MinIO) sends client credentials in the POST body (`client_secret_post`), not in the `Authorization` header (`client_secret_basic`). Authelia's default is `client_secret_basic`, so it couldn't find the credentials.

**Resolution:** In Authelia's configmap, set per-client:
```yaml
token_endpoint_auth_method: client_secret_post
```

---

## Issue 3: Hairpin NAT — MinIO pod cannot reach Authelia via external VIP

**Symptom:** MinIO's startup config fetch from `https://authelia.apps.lab.home.arpa/.well-known/openid-configuration` silently failed. `curl -sv` from inside the MinIO pod showed the TLS handshake never started — TCP connection failed before any TLS output.

**How it was found:**
```bash
# Test connectivity from inside the MinIO pod
kubectl exec -n minio deploy/minio -- curl -sv \
  https://authelia.apps.lab.home.arpa/.well-known/openid-configuration 2>&1 | head -30
# Output stopped before any TLS lines — connection never established

# Confirm DNS resolution inside the pod
kubectl exec -n minio deploy/minio -- getent hosts authelia.apps.lab.home.arpa
# Returns 192.168.1.160 (the kube-vip VIP, not a ClusterIP)

# Get Traefik's ClusterIP for the fix
kubectl get svc -n kube-system traefik -o jsonpath='{.spec.clusterIP}'
# 10.43.10.71
```

**Cause:** In-cluster pods resolving `*.apps.lab.home.arpa` get the kube-vip VIP (192.168.1.160). Traffic from a pod to that VIP routes out to the physical NIC and back in through kube-proxy/iptables. On this cluster, that path does not hairpin correctly — the packet is dropped or never returned.

**Resolution:** Add `hostAliases` to the MinIO deployment to override DNS resolution inside the pod, pointing directly to Traefik's ClusterIP:
```yaml
spec:
  template:
    spec:
      hostAliases:
        - ip: "10.43.10.71"   # kubectl get svc -n kube-system traefik -o jsonpath='{.spec.clusterIP}'
          hostnames:
            - authelia.apps.lab.home.arpa
            - minio-console.apps.lab.home.arpa
```

This applies to any pod that needs to reach Authelia server-side (MinIO, Grafana, ArgoCD).

---

## Issue 4: Lab CA not trusted — TLS handshake fails with "unknown CA (560)"

**Symptom:** Even after fixing hairpin routing, TLS to `authelia.apps.lab.home.arpa` failed. `curl -sv` from inside the MinIO pod showed alert 560 (unknown CA). The lab CA cert was mounted at `/etc/ssl/certs/lab-ca.crt` but not trusted.

**How it was found:**
```bash
# After adding hostAliases, re-test TLS from inside the pod
kubectl exec -n minio deploy/minio -- curl -sv \
  https://authelia.apps.lab.home.arpa/.well-known/openid-configuration 2>&1 | grep -E "CAfile|alert|SSL|TLS|certificate"
# Output:
#   CAfile: /etc/ssl/certs/ca-certificates.crt
#   SSL alert number 560   ← unknown CA
#   TLS handshake failure

# Confirm the cert is mounted
kubectl exec -n minio deploy/minio -- ls -la /etc/ssl/certs/lab-ca.crt
```

**Cause:** Go's `crypto/x509` builds the system cert pool by reading the bundle file (`/etc/ssl/certs/ca-certificates.crt`) **and** scanning `/etc/ssl/certs/` for individual files. However, this scan behavior depends on the distro and Go version. On the MinIO image (Debian-based), individual files in `/etc/ssl/certs/` are scanned — but only if they're DER or PEM files ending in `.crt` and present at image build time, not dynamically added ones. In practice, a volume mount at `/etc/ssl/certs/lab-ca.crt` was not reliably picked up.

**Resolution:** Use an init container to prepend the lab CA to the system bundle before MinIO starts:
```yaml
initContainers:
  - name: ca-inject
    image: minio/minio:RELEASE.2025-04-22T22-12-26Z
    command: [sh, -c, "cat /etc/ssl/certs/ca-certificates.crt /tmp/lab-ca.crt > /injected/ca-certificates.crt"]
    volumeMounts:
      - name: lab-ca
        mountPath: /tmp/lab-ca.crt
        subPath: lab-ca.crt
      - name: injected-certs
        mountPath: /injected
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {cpu: 100m, memory: 64Mi}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: [ALL]}
volumes:
  - name: lab-ca
    configMap:
      name: lab-ca-cert
  - name: injected-certs
    emptyDir: {}
```

Mount the injected bundle over the system bundle in the main container:
```yaml
volumeMounts:
  - name: injected-certs
    mountPath: /etc/ssl/certs/ca-certificates.crt
    subPath: ca-certificates.crt
```

The same pattern applies to any in-cluster pod (Grafana, ArgoCD) that needs to make TLS connections to lab services.

---

## Issue 5: ArgoCD selfHeal reverted imperative `kubectl set env` debug change

**Symptom:** Added `LOG_LEVEL=debug` to the MinIO deployment via `kubectl set env` to get more verbose output. Within seconds, ArgoCD detected drift and reverted the change. The OIDC flow was mid-attempt when the pod rolled, resetting state.

**How it was found:**
```bash
# Attempted
kubectl set env -n minio deploy/minio LOG_LEVEL=debug
# Pod rolled within ~30 seconds — ArgoCD self-healed
kubectl get events -n minio --sort-by='.lastTimestamp' | tail -10
# Showed ArgoCD sync replacing the deployment
```

**Cause:** ArgoCD `selfHeal: true` continuously reconciles live state to git state. Any imperative change to a managed resource is reverted almost immediately.

**Resolution:** Enable debug logging via a ConfigMap change committed to git and pushed through a PR. Never use `kubectl set env` or `kubectl patch` on ArgoCD-managed resources for debugging — always go through git.

For Authelia specifically, debug was enabled by adding `log.level: debug` to the Authelia ConfigMap, which ArgoCD then applied on the next sync.

---

## Issue 6: Authelia consent page stuck loading — `user_preferences` row missing

**Symptom:** After 1FA login, Authelia redirected to the consent page which displayed "Loading..." indefinitely. Browser DevTools showed `GET /api/user/info → 403` (later confirmed as a 404 on the actual path `/api/user/info`).

**How it was found:**
```bash
# Check Authelia Postgres tables for the affected user
POSTGRES_POD=$(kubectl get pod -n authelia -l app=authelia-postgres -o name | cut -d/ -f2)

kubectl exec -n authelia $POSTGRES_POD -- psql -U authelia -d authelia -c \
  "SELECT * FROM user_preferences WHERE username='swares';"
# 0 rows returned — missing row

kubectl exec -n authelia $POSTGRES_POD -- psql -U authelia -d authelia -c \
  "\d user_preferences"
# Showed: second_factor_method VARCHAR NOT NULL — the missing row caused the 403
```

**Cause:** Authelia's consent page UI calls `/api/user/info` to render the page. This endpoint returned an error because the `user_preferences` table had no row for the `swares` user (the table enforces `NOT NULL` on `second_factor_method` and the UI checks preferences before rendering).

**Resolution:** Insert the missing row directly:
```bash
kubectl exec -n authelia $POSTGRES_POD -- psql -U authelia -d authelia -c \
  "INSERT INTO user_preferences (username, second_factor_method) VALUES ('swares', '');"
```

The longer-term fix was switching to `consent_mode: implicit` (see Issue 7), which bypasses the consent page entirely.

---

## Issue 7: Authelia consent page required explicit user interaction

**Symptom:** Even after fixing the user_preferences row, the consent page rendered correctly but Authelia waited for the user to explicitly grant consent before issuing the auth code. For a trusted homelab client this is unnecessary friction.

**Resolution:** Add `consent_mode: implicit` to each OIDC client in Authelia's configmap:
```yaml
clients:
  - client_id: minio
    # ...
    consent_mode: implicit
```

This skips the consent page entirely for trusted clients and immediately issues the auth code after 1FA.

---

## Issue 8: Authorization request silently hangs — no auth code issued, no error logged

**Symptom:** After all previous fixes, the OIDC flow reached the point where Authelia logged:
```
Authorization Request with id '...' on client with id 'minio' is being processed
```
Then nothing. No auth code issued, no redirect to MinIO, no error in either pod's logs. The browser remained at `authelia.apps.lab.home.arpa` indefinitely. After 8–9 minutes the pod received SIGTERM (ArgoCD rolling the deployment) and shut down cleanly.

**Diagnosis process:**

**Step 1 — Check LLDAP logs for post-login LDAP activity:**
```bash
kubectl logs -n lldap -l app=lldap --tail=50
```
LDAP sessions for 1FA completed normally. No new LDAP sessions appeared after login, confirming the post-login authorization handler was not querying LLDAP (user info came from the session cache).

**Step 2 — Check Postgres for active/blocked queries:**
```bash
POSTGRES_POD=$(kubectl get pod -n authelia -l app=authelia-postgres -o name | cut -d/ -f2)
kubectl exec -n authelia $POSTGRES_POD -- psql -U authelia -d authelia -c "
  SELECT pid, now()-query_start AS duration, state, wait_event_type, wait_event, left(query,100) AS query
  FROM pg_stat_activity WHERE datname='authelia' ORDER BY duration DESC NULLS LAST;"
```
Found: SELECT and INSERT into `oauth2_consent_session` had completed (state=idle). No active queries. Then confirmed the auth code table was always empty:
```bash
kubectl exec -n authelia $POSTGRES_POD -- psql -U authelia -d authelia -c \
  "SELECT COUNT(*) FROM oauth2_authorization_code_session;"
# count: 0 — no auth codes ever issued
```

**Step 3 — Goroutine dump to find the blocked goroutine:**
```bash
# Send SIGQUIT — Go runtime dumps all goroutines then exits
kubectl exec -n authelia authelia-6d47f99b79-hdc5f -- kill -SIGQUIT 1
sleep 3
kubectl logs -n authelia authelia-6d47f99b79-hdc5f --previous 2>&1 | tail -300
```
The dump showed **no active HTTP handler goroutine** — the fasthttp worker pool was idle. This meant the handler had already *completed* without writing an auth code, not that it was stuck mid-execution.

**Step 4 — Check consent session state:**
```bash
kubectl exec -n authelia $POSTGRES_POD -- psql -U authelia -d authelia -c \
  "SELECT challenge_id, client_id, subject, authorized, granted FROM oauth2_consent_session ORDER BY requested_at DESC LIMIT 5;"
```
Output:
```
 challenge_id | client_id | subject | authorized | granted
--------------+-----------+---------+------------+---------
 377beed7-... | minio     |         | f          | f
 3d452adf-... | minio     |         | f          | f
 639f2317-... | minio     |         | f          | f
```
All rows had `subject=''`, `authorized=false`, `granted=false`. The consent was never being marked as granted — every attempt created a new pending session. The handler was returning normally, just not as the authenticated user.

**Root cause:** Authelia was running **2 replicas with no Redis** (sessions stored in-memory via `fasthttp/session` per-pod). The OIDC flow split across pods:

- Pod A handled the initial `/api/oidc/authorization` request → stored the user's session in **Pod A's in-memory session store** → redirected to login
- User completed 1FA on Pod A
- The POST-login `/api/oidc/authorization` request was load-balanced to **Pod B**
- Pod B had no knowledge of the session created on Pod A → treated user as unauthenticated → created a new pending consent session (`authorized=false`, `subject=''`) → redirected to login page
- The Authelia SPA loaded and rendered "loading" because the API state was inconsistent
- This loop repeated silently with no error log

The `fasthttp/session` GC goroutine visible in the dump confirmed in-memory session storage was in use (no Redis).

**Resolution:** Scale Authelia to 1 replica and add Traefik sticky-session annotation as belt-and-suspenders:

In `deployment.yaml`:
```yaml
spec:
  replicas: 1
```

In `ingress.yaml`:
```yaml
annotations:
  traefik.ingress.kubernetes.io/service.sticky.cookie: "true"
  traefik.ingress.kubernetes.io/service.sticky.cookie.name: "_authelia_pod"
  traefik.ingress.kubernetes.io/service.sticky.cookie.httponly: "true"
  traefik.ingress.kubernetes.io/service.sticky.cookie.secure: "true"
  traefik.ingress.kubernetes.io/service.sticky.cookie.samesite: "strict"
```

**Note:** The proper HA fix is adding a Redis deployment and configuring Authelia's `session.redis` backend. With Redis, sessions are shared across pods and multiple replicas work correctly. For this homelab, single-replica is acceptable.

---

## Post-fix cleanup

After MinIO SSO began working, 47 orphaned consent sessions (all with `subject=''`, `authorized=false`) were left in Postgres from the debug attempts:
```sql
DELETE FROM oauth2_consent_session WHERE authorized = false AND granted = false;
-- DELETE 47
```

---

## Patterns that apply to all subsequent OIDC clients

| Problem | Fix |
|---|---|
| In-cluster pod can't reach `*.apps.lab.home.arpa` | `hostAliases` → Traefik ClusterIP (`10.43.10.71`) |
| Lab CA not trusted by pod | Init container appends CA to `/etc/ssl/certs/ca-certificates.crt` via emptyDir |
| Authelia rejects token exchange | `token_endpoint_auth_method: client_secret_post` per client |
| Consent page required | `consent_mode: implicit` per client |
| Multi-replica Authelia without Redis | Single replica until Redis is added |

## Client secret management

Client secrets are stored in Vault and injected at runtime — never hardcoded in configmaps.

| Client | Vault path | Property |
|---|---|---|
| minio | `secret/lab/minio` | `oidc-client-secret` |
| grafana | `secret/lab/grafana` | `oidc-client-secret` |

Authelia configmap stores the **argon2id hash** of the secret (generated via `kubectl exec -n authelia deploy/authelia -- authelia crypto hash generate argon2 --password <secret>`). The plaintext is only in Vault and in the client application's secret.

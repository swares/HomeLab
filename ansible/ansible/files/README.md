# Vaulted / secret files (NOT committed)

Place these here locally. They are excluded by `.gitignore`.

- `pull-secret.json` — free Red Hat pull secret from
  https://console.redhat.com/openshift/install/pull-secret
  Copied to `/etc/crio/openshift-pull-secret` before MicroShift's first start.

Secrets that are NOT files (restic password, vault password) live at:
- `/etc/restic/password` on the host (mode 0700)
- `ansible/.vault_pass` locally (gitignored)

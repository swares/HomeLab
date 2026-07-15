# Vaulted / secret files (NOT committed)

Place these here locally. They are excluded by `.gitignore`.

- `pull-secret.json` — legacy Red Hat pull secret from the MicroShift era. The platform is now k3s; this file is kept for reference but is no longer used at install time.

Secrets that are NOT files (restic password, vault password) live at:
- `/etc/restic/password` on the host (mode 0700)
- `ansible/.vault_pass` locally (gitignored)

# Immich (self-hosted photos) on the H4

GitOps-managed photo/video library, synced by Argo (`gitops/apps/immich.yaml`). Runs on the H4
MicroShift node so it sits next to its storage.

## Stack & tier placement
| Component | Image | Where it lands |
|-----------|-------|----------------|
| `immich-server` | `immich-server:release` | library on the **8 TB mirror** (md1, `/mnt/cold-8t`) |
| `immich-ml` | `immich-machine-learning:release` (**CPU default**) | accel optional — see below |
| `immich-postgres` | `postgres:…-vectorchord…` (vector ext **mandatory**) | **NVMe hot tier** (`topolvm-provisioner`) |
| `immich-redis` | `redis:6.2-alpine` | ephemeral cache |

- **DB + model cache → NVMe** (low-latency); **photo library → 8 TB mirror** (`/mnt/cold-8t/immich`,
  via the static `immich-library` PV); **restic** already backs up `/mnt/cold-8t`, so the library
  and the nightly DB dump are covered.

## Before first sync
1. **Create the DB secret** (kept out of git so `selfHeal` can't clobber it; or use External Secrets):
   ```bash
   oc -n immich create secret generic immich-secrets --from-literal=DB_PASSWORD='<strong-pass>'
   ```
2. **Make the library dir** on the H4: `mkdir -p /mnt/cold-8t/immich/backups`.
3. **Pin images** — replace `:release` with a specific `vX.Y.Z`, and confirm the **postgres
   vectorchord tag** against the current Immich docs (the extension version moves).

## Machine-learning acceleration (optional)

ML accelerates **Smart Search (CLIP)** + **Facial Recognition** only (not transcoding). There is
**no admin toggle** — the backend is chosen by the image tag + device access. The default here is
**CPU**, which always works; the iGPU's real payoff is getting through the *initial library import*
without pegging the CPU. Two optional upgrades:

**A) H4 iGPU via OpenVINO.** Switch the image to `…-openvino`, and add device access:
```yaml
        securityContext: { privileged: true }   # or the Intel GPU device plugin + a non-privileged SCC
        volumeMounts:
          - { name: dri, mountPath: /dev/dri }
          - { name: usb, mountPath: /dev/bus/usb }
      volumes:
        - { name: dri, hostPath: { path: /dev/dri } }
        - { name: usb, hostPath: { path: /dev/bus/usb } }
```
⚠ **Caveat:** Immich's docs target OpenVINO at *discrete* Intel GPUs (Iris Xe/Arc) and say to
"expect issues" on **integrated** graphics — the N305's UHD is exactly that case, and there's a
recent OpenVINO/Intel ML breakage bug. It's best-effort and **silently falls back to CPU** if the
provider fails to init. Pin a known-good Immich version.

**B) OPi 5 Pro NPU via `rknn` (remote ML) — the more robust path.** RK3588 is a first-class Immich
ML backend. Run a `…-rknn` ML container on an OPi 5 Pro (needs RKNPU driver ≥ V0.9.8; set
`MACHINE_LEARNING_RKNN_THREADS=2` or `3`), then in Immich **Admin → Machine Learning** add that
container's URL — and **also list this in-cluster CPU container as a fallback URL** so jobs still
run if the OPi is down. Tradeoff: shares the NPU with RKLLama + adds a network hop.

**Verify it's actually engaging** (either path): check the `immich-ml` pod logs for the
OpenVINO/RKNN provider loading, and watch `intel_gpu_top` (iGPU) during a forced Smart Search job.
If the CPU pegs at 100% and the accelerator is idle, it fell back to CPU.

## Alternative## Alternative
Immich's first-class deploy is **docker-compose** (and there's a community Helm chart). This repo
uses raw-manifest GitOps for consistency with the other workloads; compose is a lighter path for a
first stand-up if you'd rather get photos flowing and convert later.

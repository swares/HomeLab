# HostMon Build & Flash

[HostMon](https://github.com/swares/HostMon) — firmware for the Waveshare ESP32-S3-Touch-LCD-4.3
host-monitoring appliance. This document covers the current build pipeline and evaluated
options for deeper homelab integration.

---

## Current pipeline

**Trigger:** push to `main` or a `v*` tag on GitHub.

**Runner:** GitHub-hosted `ubuntu-latest` (no homelab infrastructure involved).

**Workflow file:** `.github/workflows/build.yml` in the HostMon repo.

**What it does:**

1. Installs `arduino-cli` and the ESP32 core (3.3.8).
2. Installs pinned libraries: `lvgl 8.4.0`, `ESP32_Display_Panel 1.0.4`,
   `ESP32_IO_Expander 1.1.1`, `esp-lib-utils 0.3.0`, `ESP32_IDF5_HTTPS_Server 1.1.1`,
   `ArduinoJson 7.4.0`.
3. Places `lv_conf.h` and `esp_panel_board_supported_conf.h` at the Arduino libraries
   root (required by the LVGL and display-panel libraries; not inside the sketch).
4. Regenerates `web_assets.h` from `data/` via `regen_web_assets.py`.
5. Compiles with FQBN:
   `esp32:esp32:esp32s3:PSRAM=opi,FlashSize=8M,PartitionScheme=custom,CDCOnBoot=cdc`
6. Uploads `.bin` + `.elf` as a GitHub Actions artifact (30-day retention) on every run.
7. On a tag push: creates a GitHub Release and attaches the `.bin`.

**Flash (manual):** Download the `.bin` from GitHub Releases or Actions artifacts, then
run `flash.bat COM<x>` from the HostMonitor repo root. This calls `esptool write_flash
0x10000` (app partition only), preserving NVS settings.

> OTA is not viable on this device — the firmware + LVGL + mbedTLS leaves insufficient
> flash for a dual-partition OTA layout. USB flashing is the only update path.

---

## Homelab integration options

### Option 1 — XU3 as a GitHub Actions self-hosted runner (recommended path)

The XU3 registers with GitHub as a runner. Builds still trigger from GitHub (push/tag)
but execute on the XU3. With the Waveshare device USB-connected to the XU3, the same
runner job can flash after a successful compile.

**To enable:** install the GitHub Actions runner on the XU3, register it against the
HostMon repo, and change `runs-on: ubuntu-latest` → `runs-on: self-hosted` in the
workflow. Add an `esptool write_flash 0x10000` step after the compile step.

| Pros | Cons |
|---|---|
| Workflow file barely changes | Runner process must stay running (systemd service) |
| Persistent build cache on disk — no re-downloading the 400 MB ESP32 core | Fork PRs can execute code on the runner if not protected (fine for a private repo) |
| GitHub UI shows build status, artifacts, and release history | Tight coupling to GitHub — re-registration needed if repo moves |
| Flash step is a natural extension of the existing job | |

---

### Option 2 — GitLab CI with a GitHub mirror

Mirror the HostMon repo to `gitlab-1` (192.168.1.50). GitLab CI runs the build on a
runner (XU3 or a k3s job). GitLab can pull-mirror from GitHub automatically on a
schedule or via webhook.

| Pros | Cons |
|---|---|
| Fully self-hosted — no outbound GitHub CI dependency | Mirror sync adds delay and complexity |
| GitLab runner is flexible (Docker / shell executor) | Two copies of the repo to reason about |
| gitlab-1 already exists in the lab | CI config must be rewritten (GitLab CI ≠ GitHub Actions syntax) |
| | GitHub Release creation requires extra scripting or accepting GitLab Releases instead |

---

### Option 3 — Webhook listener + script on the XU3

A small webhook receiver (Python or the `webhook` binary) listens for GitHub `push` /
`create` (tag) events. On trigger: pull the repo, run `arduino-cli compile`, optionally
call `esptool` to flash the USB-connected device. No CI framework.

| Pros | Cons |
|---|---|
| Simplest infrastructure — one script + one systemd unit | No build history, artifact storage, or status checks on GitHub PRs |
| No runner registration or daemon framework | GitHub Release creation must be added manually (e.g. `gh release create`) |
| Easiest path to automated flash — script has direct USB access | No parallelism or queue — one build at a time |
| Full control over build environment | |

---

## Build speed considerations

The ESP32/LVGL/mbedTLS sketch is large — full clean compiles are slow regardless of
hardware. arduino-cli caches object files between runs, so incremental builds (only
changed files recompile) are significantly faster than a full rebuild.

| | Dell 5580 (local) | GitHub hosted (cached) | XU3 self-hosted |
|---|---|---|---|
| First build | slow | slow | very slow |
| Incremental | depends on IDE cache | fast (object cache hits) | slow |
| Architecture | x86_64 | x86_64 | ARM (Cortex-A15) |
| Developer time cost | blocking | background | blocking + longer |

The XU3 (Exynos 5422, Cortex-A15 ARM) is considerably slower than x86 for C++
compilation and would be slower than the Dell 5580, not faster. This rules out the XU3
as a full self-hosted build runner for this project.

If automated USB flashing becomes a priority (Option 1), the right split is:
**build on GitHub-hosted runners** (x86, cached, background) →
**flash on XU3** (triggered by a workflow webhook after a successful build).
That avoids running the slow compile on ARM while still automating the physical flash step.

---

## Decision

Staying with **GitHub-hosted runners + manual USB flash** for now. If automated flashing
is needed later, decouple: GitHub runner builds, XU3 flashes via webhook trigger.

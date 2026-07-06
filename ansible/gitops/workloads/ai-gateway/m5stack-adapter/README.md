# m5stack-adapter (deployment only)

This directory holds **only the Kubernetes manifests** for the OpenAI-compatible M5Stack adapter.

The **adapter code now lives in the M5Stack Core Framework repo** (`scripts/openai_adapter/`),
next to `orchestrator.py`, where it shares one canonical device-protocol client
(`scripts/protocol.py`). Code is coupled to the firmware *protocol* → it belongs with the
firmware. Deployment is coupled to *this cluster* → it stays here in GitOps.

## What's here
- `deployment.yaml` — pins the image built from the framework repo
  (`registry.lab.home.arpa/m5stack-adapter:<ver>`)
- `service.yaml` — ClusterIP `m5stack-adapter:8080` (LiteLLM points here)
- `configmap.yaml` — `M5_*` env (device host, model map, timeouts, TLS)

## Build + release flow
1. Change code in the **framework repo** (`scripts/openai_adapter/` or `scripts/protocol.py`).
2. Build + push from the framework repo's `scripts/` dir:
   `docker build -f openai_adapter/Dockerfile -t registry.lab.home.arpa/m5stack-adapter:<ver> .`
3. Bump the tag in `deployment.yaml` here → Argo syncs it.

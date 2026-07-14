# AI Routing & Escalation

How the lab's heterogeneous AI silicon is unified behind a single endpoint, and how
per-turn escalation decisions work.

---

## Three escalation tiers (M5Stack router)

Every prompt enters the router (`NetDevice_Router` on-device, or `orchestrator.py` on the
Pi) and gets classified once:

**Tier 1 — Local NPU** (`route_taken: "local"`). Trivial chat answered on the M5Stack's
AX630C (Module LLM, ~0.5B). Zero latency, zero cloud. If the keyword prefilter is
ambiguous, the router runs one short yes/no classification ("does this need an agent?
YES/NO") on the local model as a tiebreaker before deciding whether to stay or escalate.

**Tier 2 — Claude API** (`route_taken: "direct_api"`). Smart text turns (explain,
summarise, draft, translate) that the 0.5B would botch but don't need tools go to the
Anthropic Messages API via `NetDevice_ClaudeAPI`. Model: `claude-haiku-4-5` by default.
Stateless by default; swap in `NetDevice_ClaudeAPI_History` for a rolling conversation
(bounded at 8 turns / 4000 chars, reset with `?clear=1`). The Pi orchestrator holds the
API key so the Core doesn't.

**Tier 3 — Claude Code agent** (`route_taken: "escalated"`). Hard/coding/multi-file turns
go to `orchestrator.py --serve` on the Pi, which spawns `claude -p <brief>
--output-format stream-json` with shell + filesystem + git access in a scoped workdir.
Chain: device → Pi → Claude Code. Fail-closed: won't start without IP allowlist or bearer
token.

---

## OpenVINO (Intel iGPU tier)

Runs on the H4 (N305) and the three N150 nodes. These have **no NPU** — it's all iGPU
(24–32 EU). Not for LLM chat; for everything the NPUs are bad at:

| Model | Via LiteLLM as |
|---|---|
| `bge-small` | `embeddings` |
| Whisper (STT) | not yet wired |
| OCR / vision classification | not yet wired |

OVMS exposes an OpenAI-compatible API at `http://openvino:8000/v3`. Currently only the
embeddings endpoint is wired into LiteLLM.

---

## LiteLLM gateway — what's routable today

| Model name | Backend | What it's for |
|---|---|---|
| `chat` | RKLLama on opi5pro-1 + opi5pro-2 (load-balanced) | Fast chat via DeepSeek-R1-Distill-1.5B on RK3588S NPU |
| `embeddings` | Ollama / nomic-embed-text (ARM CPU) | RAG, semantic search |
| `stt` | `https://stt.apps.lab.home.arpa/v1/audio/transcriptions` (direct, not via gateway) | Speech-to-text — LiteLLM doesn't proxy multipart audio to custom backends |
| `m5` | m5stack-adapter → `/api/route` | Full 3-tier escalation router |
| `m5-llm` | m5stack-adapter → `/api/llm` | Direct Module LLM only |
| `m5-claude` | m5stack-adapter → `/api/claude` | Direct Claude API client on device |

`chat-cpu` (Ollama in-cluster) is commented out as a fallback if the NPU path degrades.
Cloud overflow (`anthropic/claude-sonnet-4-6`) is also commented out — uncomment and
supply a key via Secret if you want big-model fallback through the same endpoint.

---

## How they compose

The M5Stack router and the LiteLLM gateway are complementary, not competing. The router
makes per-turn brain decisions; the gateway is the shared endpoint everything else in the
cluster calls. The `m5stack-adapter` bridges them — `route_taken` flows back in
`system_fingerprint`, which means local-vs-cloud accounting can land in Grafana from MQTT
without any extra wiring.

```
device prompt
    │
    ▼
NetDevice_Router / orchestrator.py
    │
    ├─ local       → Module LLM (AX630C, on-device)
    ├─ direct_api  → Claude API (Haiku, via Pi orchestrator)
    └─ escalated   → Claude Code agent (Pi, scoped workdir)
         │
         └─ all three reachable externally via LiteLLM gateway
                │
                ├─ chat        → RKLLama (RK3588S NPU, OPi 5 Pro ×2)
                ├─ embeddings  → OpenVINO bge-small (Intel iGPU)
                ├─ m5          → m5stack-adapter (full router)
                ├─ m5-llm      → m5stack-adapter (Module LLM direct)
                └─ m5-claude   → m5stack-adapter (Claude API direct)
```

See `AI-INFERENCE.md` for hardware specs, conversion notes, and M5Stack module options.
See `gitops/workloads/ai-gateway/configmap.yaml` for the live routing config.

---

## Models by device

| Device | IP | Accelerator | Runtime | Model | Status | LiteLLM name |
|---|---|---|---|---|---|---|
| **OPi 5 Pro #1** | `192.168.1.168` | RK3588S NPU (6 TOPS) | RKLLama (runtime 1.3.0) | `DeepSeek-R1-Distill-Qwen-1.5B_w8a8_g128_rk3588` (2.1 GB) | ✅ serving | `chat` |
| **OPi 5 Pro #2** | `192.168.1.172` | RK3588S NPU (6 TOPS) | RKLLama (runtime 1.3.0) | `DeepSeek-R1-Distill-Qwen-1.5B_w8a8_g128_rk3588` (2.1 GB) | ✅ serving | `chat` |
| **M5Stack Module LLM** | `192.168.1.71` | AX630C NPU (~6 TOPS) | M5 framework | built-in ~0.5B (firmware) | ✅ via adapter | `m5`, `m5-llm`, `m5-claude` |
| **H4 Ultra** | `192.168.1.160` | Intel iGPU (N305, 32 EU) | OpenVINO | `bge-small` (embeddings) | ✅ wired | `embeddings` |
| **N150 #1** | `192.168.1.42` | Intel iGPU (N150, 24 EU) | OpenVINO | `bge-small` (embeddings) | ✅ capable | `embeddings` |
| **N150 #2** | `192.168.1.21` | Intel iGPU (N150, 24 EU) | OpenVINO | `bge-small` (embeddings) | ✅ capable | `embeddings` |
| **N150 #3 (HTPC)** | `192.168.1.176` | Intel iGPU (N150, 24 EU) | OpenVINO | — | not wired (HTPC role) | — |

### Notes

- Both OPis running RKLLM runtime 1.3.0, rknpu kernel driver 0.9.6 (kernel 6.1.43-rockchip-rk3588). Driver 0.9.6 cannot allocate the ~3GB NPU memory required by 3B models — only models needing <2GB load successfully. DeepSeek-1.5B is the working default. Llama-3.2-3B and Qwen3-4B are present on disk but fail to load. **Upgrade path:** update rknpu kernel module to 0.9.7 on both OPis to unlock 3B models.
- Whisper STT: `faster-whisper-server` on n150-1 (CPU, port 8001) — deploy with `whisper.yml`, then merge configmap PR. OVMS disabled on n150-1/n150-2 pending GPU runtime + model IR setup (separate task).
- OpenVINO vision/OCR: not yet wired — OVMS needs GPU runtime (intel-opencl-icd, level-zero) and model IR files before re-enabling.
- The M5Stack `m5-claude` route uses the `NetDevice_ClaudeAPI` plugin (Haiku by default); this costs cloud tokens unlike the other local routes.
- Cloud overflow (`claude-sonnet-4-6`) is commented out in the LiteLLM configmap — uncomment and add a key via Secret to enable big-model fallback.

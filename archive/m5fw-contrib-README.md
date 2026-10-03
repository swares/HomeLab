# Framework contribution — shared protocol client + OpenAI adapter

Drop these into **your M5Stack Core Framework repo** so the host-side Python that speaks the
device protocol lives next to `orchestrator.py` and shares one canonical client.

```
scripts/
  protocol.py            # NEW — the one device-protocol client (sync + async wrappers)
  orchestrator.py        # PATCHED — CoreClient now delegates to protocol.DeviceClient
  openai_adapter/        # NEW — OpenAI-compatible shim (imports protocol.AsyncDeviceClient)
    main.py  requirements.txt  Dockerfile  README.md  __init__.py
```

## Why this layout
`orchestrator.py` and the adapter are both *host-side Python coupled to the firmware protocol*.
Co-locating them (and sharing `protocol.py`) means a protocol change is **one commit across
firmware + both consumers** — no cross-repo drift. Deployment stays in the homelab GitOps repo.

## Apply
1. Copy `scripts/protocol.py` and `scripts/openai_adapter/` into your repo's `scripts/`.
2. For `orchestrator.py`: the only change is the `CoreClient` class (now ~6 lines delegating to
   `protocol.DeviceClient`) plus its lazy `from protocol import DeviceClient`. The provided
   `orchestrator.py` is patched **from the public repo clone** — `diff` it against your working
   copy before overwriting, in case you've customised it.
3. Build + push the image from `scripts/` (so `protocol.py` is in the build context):
   ```bash
   cd scripts
   docker build -f openai_adapter/Dockerfile -t <registry>/m5stack-adapter:<ver> .
   docker push <registry>/m5stack-adapter:<ver>
   ```
4. In the homelab repo, the slimmed `gitops/workloads/ai-gateway/m5stack-adapter/` just pins that
   image tag — no app code there anymore.

## Notes
- `protocol.py` imports `requests`/`httpx` **lazily**, so orchestrator needs only `requests` and
  the adapter only `httpx`.
- Behaviour parity: `DeviceClient.ask()` keeps the `[empty reply]` / `[core unreachable: …]`
  sentinels and the retry-on-initial-failure semantics. (The old distinct `[core went silent]`
  on idle now also reports as `[empty reply]` — simplified; adjust in `protocol.py` if you relied
  on the distinction.)
- Tested by compile + inspection here; run against a real Core before trusting in production.

# archive/

Superseded files kept for reference. **Nothing here is live.** No playbook, workflow,
or Argo Application reads from this folder.

Moved here on 2026-10-03 to clear the repo root. The files themselves are unedited.

| File | What it was | Why it's kept |
|---|---|---|
| `TODO-2026-07-14.md`, `TODO-2026-07-23.md`, `TODO-2026-08-03.md` | Dated session task lists, replaced by [`../BACKLOG.md`](../BACKLOG.md) on 2026-08-07 | `BACKLOG.md` cites them by `file:line` as evidence. Moving a file keeps its line numbers, so those citations still hold at the new path. **Do not edit these files**, or the citations break |
| `m5fw-contrib-README.md` | Build and apply procedure for contributing the adapter code to the M5Stack framework repo | Historical; the live adapter docs are `gitops/workloads/ai-gateway/m5stack-adapter/README.md` |
| `protocol.py` | An older copy of the M5Stack device-protocol client | The canonical client lives in the framework repo, and the deployed copy is `gitops/workloads/ai-gateway/m5stack-adapter/protocol.py` |
| `sample-speech-1m.wav` | A one-minute speech sample, apparently for Whisper STT testing | Kept in case a test still expects it (5 MB) |
| `ansible-stale-ci/` | `ansible/.github/`, `ansible/.gitlab-ci.yml`, `ansible/.claude/` | Drifted duplicates of the root copies. Neither GitHub nor GitLab ever read them from that location (`BACKLOG.md` §7.1) |

The empty, accidentally committed `FETCH_HEAD` was deleted rather than archived. It was
a git internal file, not content.

# Documentation consolidation plan

**Status: proposal. Nothing in this plan has been executed.** No existing file was
modified to produce it. Adopt, amend, or reject section by section.

Compiled 2026-08-15 against the working tree, then fact-checked against the repo in a
second pass. Where the first draft copied a citation from another document rather than
reading the file, the audit caught it — those are corrected here and noted in §11, because
a plan about documents that lie must not lie.

Companion to [`../BACKLOG.md`](../BACKLOG.md) §6 (*Documentation drift*) and §7 (*Repo
hygiene*). §6 lists twelve individual false statements; this plan addresses the structure
that keeps producing them.

> **Read §0 first.** The audit surfaced a live defect that outranks everything else here.

---

## 0. Live defect found while compiling this plan

**BACKLOG §6.1 is not closed. It was fixed in `CLAUDE.md` only.**

`CLAUDE.md:53-55` states that `*.apps.lab.home.arpa` must resolve to `192.168.1.201`, and
that finding `.160` on the wildcard "is the fault, not the fix." The source of truth
agrees — `ansible/inventory/hosts.yml:48` sets `ingress_vip: 192.168.1.201`.

**Eight documentation files still pair the wildcard with `192.168.1.160`:**

| File:line | Context | Severity |
|---|---|---|
| `README.md:108` | Bootstrap prerequisite — "create DNS records … → 192.168.1.160" | **Highest.** A fresh bring-up following the quickstart recreates the 2026-07-27 outage. |
| `docs/RUNBOOK.md:26` | DNS A-record table | **Highest.** Most-linked doc in the repo (11 inbound). |
| `docs/ARCHITECTURE.md:134` | States the DNS record value | High — the doc `CLAUDE.md` sends you to. |
| `docs/HARDWARE.md:88` | Ingress/DNS summary line | High |
| `README.md:82` | Ingress endpoint table | Medium |
| `docs/services.md:14` | CoreDNS custom zone row | Medium |
| `docs/OVERVIEW.md:26` | CoreDNS custom zone bullet | Medium |
| `docs/STANDUP.md:36`, `:72` | Bring-up steps + a `dig` expected-output comment | Medium (freeze candidate — fix before freezing) |
| `docs/GITOPS-STUDY-GUIDE.md:558`, `:624` | Learning material | Low (freeze candidate) |

Non-doc occurrences needing separate adjudication, **not** covered by this plan:
`gitops/workloads/coredns-custom/configmap.yaml:2` and `tofu/dns/main.tf:8`. The CoreDNS
in-cluster zone may legitimately differ from the LAN record — `ARCHITECTURE.md:146`
asserts it points at `.160` too. **Confirm the intended in-cluster value against a live
`kubectl get configmap -n kube-system coredns-custom` before changing either**, and note
that `docs/sso-authelia-minio-troubleshooting.md:85` documents a hairpin-NAT failure on
exactly this path.

Legitimate historical references — do not touch: `BACKLOG.md:569` (quoting the old text),
`docs/REVIEW-2026-07-24.md:148`, `TODO-2026-08-03.md:166`,
`gitops/workloads/kube-vip/traefik-vip-service.yaml:6` (explains why the design changed).

**This is the whole argument for the plan, demonstrated on itself.** One fact, typed into
eleven places, fixed in one. The remedy in §4 is not tidiness — it is that `ingress_vip`
should have exactly one home and every document should read from it.

**Action: fix these eight before any other step.** That is §9 step 0, and it is the only
item here that could cause an outage.

---

## 1. The finding in one paragraph

The repo holds **33 markdown files, ~8,850 lines**. The problem is not volume — it is that
the same fact is *typed* into many of them. `192.168.1.x` literals appear **184 times
across 25 files**; the fleet roster appears in **14 files**; `*.apps.lab.home.arpa` service
URLs appear **92 times across 16 files**. Every one is an independent copy that must be
found and edited when the underlying fact changes. §0 is what happens when one is missed —
except it was ten.

**Open work is already solved.** `BACKLOG.md` declared itself sole owner on 2026-08-07 and
the other lists collapsed to pointers. That pillar is done; this plan does not reopen it.
The unsolved layer is **reference documentation** — topology, endpoints, inventory,
procedures, and status.

## 2. Measured overlap

Counts are repo-wide across all `.md` files excluding `.git` and this file.

### 2.1 Host IPs — 184 literals across 25 files

Source of truth is `ansible/inventory/hosts.yml`.

| File | IP refs | Distinct hosts | Note |
|---|---:|---:|---|
| `docs/HARDWARE.md` | 43 | 24 | Legitimate — this is the hardware register |
| `README.md` | 26 | 16 | Full fleet table, duplicated |
| `docs/ARCHITECTURE.md` | 23 | 14 | Full fleet table, duplicated |
| `docs/TROUBLESHOOTING.md` | 13 | 5 | Inside command examples |
| `docs/OPS.md` / `docs/RUNBOOK.md` | 9 / 9 | 4 / 4 | Inside command examples |
| `docs/AI-ROUTING.md` | 7 | 7 | Inference fleet |
| `CLAUDE.md` | 6 | 5 | **Highest-risk file** — read during incidents |
| 17 further files | 1–6 each | | 48 refs total |

### 2.2 Fleet roster — restated in 14 files

`BACKLOG.md`, `CLAUDE.md`, `README.md`, `TODO-2026-07-23.md`, `TODO-2026-08-03.md`,
`docs/AI-ROUTING.md`, `docs/ARCHITECTURE.md`, `docs/HARDWARE.md`, `docs/OPS.md`,
`docs/OVERVIEW.md`, `docs/TROUBLESHOOTING.md`, `docs/UPDATES.md`, `docs/services.md`,
`docs/sso-authelia-minio-troubleshooting.md`.

### 2.3 Ingress URLs — 92 refs across 16 files

Concentrated in `README.md` (18), `docs/services.md` (15), `docs/SSO.md` (13),
`docs/OVERVIEW.md` (9), `docs/sso-authelia-minio-troubleshooting.md` (8),
`docs/HARDWARE.md` (7); 22 across ten further files. Source of truth is
`gitops/workloads/*/ingress.yaml`.

### 2.4 Workload / namespace catalogue — restated in 12 files

`README.md`, `docs/OVERVIEW.md`, `docs/services.md`, `docs/ARCHITECTURE.md`,
`docs/OPS.md`, `docs/AI-INFERENCE.md`, `docs/AI-ROUTING.md`,
`docs/GITOPS-STUDY-GUIDE.md`, `docs/REVIEW-2026-07-24.md`, and the three `TODO-*` files.
Source of truth is the directory listing of `gitops/workloads/`.

### 2.5 Procedures — five files, overlapping ground

| Topic | `RUNBOOK` | `OPS` | `WORKFLOWS` | `UPDATES` | `BACKUP-RESTORE` |
|---|:-:|:-:|:-:|:-:|:-:|
| Initial install / bring-up | ● | | | | |
| Verify healthy cluster | ● | ● | | | |
| Deploy / add a workload | ● | ● | ● `:33` | | |
| OS + k3s updates | | ● | ● `:7` | ● | |
| Secrets / Vault | ● | ● | ● `:73` | | |
| Rollback & recovery | ● | | ● `:149` | | ● |
| **Single-failure-domain risk** | | | **● `:229` — unique** | | (partial) |
| Storage tiers | ● | | | | ● |

`docs/WORKFLOWS.md` is the most duplicated file — but **not** empty of unique content. See
§5 and §7; the first draft of this plan proposed deleting it and was wrong.

## 3. Proposed ownership — one home per fact type

| Fact type | Single source of truth | How docs get it |
|---|---|---|
| Hosts, IPs, roles, groups | `ansible/inventory/hosts.yml` | **Generated** into marker blocks |
| VIPs (`ingress_vip`, `api`) | `ansible/inventory/hosts.yml:48,52` | **Generated** — see §0 |
| Ingress URLs | `gitops/workloads/*/ingress.yaml` | **Generated** |
| Deployed workloads + namespaces | `gitops/workloads/` directory | **Generated** |
| Version pins (k3s, images, rknpu) | `hosts.yml` + `gitops/` | **Generated** |
| Hardware detail, serials, specs | `docs/HARDWARE.md` | Hand-written, sole owner |
| Open work, gaps, deferred items | `BACKLOG.md` | Hand-written, sole owner *(already true)* |
| Runtime status ("is it working?") | `scripts/verify-lab.py` | **Generated** from last run |
| Procedures | one owner per topic — see §5 | Hand-written |
| Design intent (not as-built) | banner-marked design docs | Hand-written, frozen |
| History and evidence | frozen archive — see §6 | Never edited |

**The rule this encodes:** a fact that exists in machine-readable form is never typed into
prose. Prose links to it or generates from it.

## 4. Generation targets

Marker blocks, `terraform-docs` style. CI regenerates and fails on diff — hand edits
inside markers become unmergeable.

```markdown
<!-- BEGIN GENERATED: fleet (source: ansible/inventory/hosts.yml) -->
| Host | Ansible name | IP | Role |
|------|--------------|----|------|
...
<!-- END GENERATED: fleet -->
```

| Block | Source | Consumers |
|---|---|---|
| `vips` | `hosts.yml:48,52` | `CLAUDE.md`, `README.md` ×2, `docs/ARCHITECTURE.md`, `docs/RUNBOOK.md`, `docs/HARDWARE.md`, `docs/services.md` |
| `fleet` | `ansible/inventory/hosts.yml` | `README.md`, `docs/ARCHITECTURE.md`, `docs/HARDWARE.md` |
| `ingress` | `gitops/workloads/*/ingress.yaml` | `README.md`, `docs/services.md` |
| `workloads` | `gitops/workloads/` + `gitops/apps/` | `README.md`, `docs/services.md` |
| `host-services` | `hosts.yml` group vars | `README.md`, `docs/ARCHITECTURE.md` |

`vips` is listed first deliberately: it is the §0 defect, and its consumer list is six
files, not the two the first draft assumed.

**Out of scope for generation:** IPs inside command examples in `TROUBLESHOOTING.md`,
`OPS.md` and `RUNBOOK.md`. Those are illustrative. The §7 lint should allow them but
require the literal to exist somewhere in `hosts.yml` — an example naming a host that no
longer exists is still a defect.

## 5. Per-file disposition

**Dispositions:** `KEEP` = sole owner of its subject · `GENERATE` = keep, replace restated
tables with generated blocks · `MERGE` = content moves to a named owner, file deleted ·
`FREEZE` = read-only historical record with a banner · `FIX` = defect to correct in place.

### Root

| File | Lines | Disposition | Rationale |
|---|---:|---|---|
| `CLAUDE.md` | 74 | **GENERATE** | Operating rules stay. VIPs + fleet paragraph become generated. Highest-risk file for stale facts. |
| `README.md` | 189 | **GENERATE** + **FIX** | Four tables become generated. **§0: `:82` and `:108` carry the wrong wildcard IP.** Note `BACKLOG.md:347` cites `README.md:167` by line number — see §6.1. |
| `BACKLOG.md` | 743 | **KEEP** | Already sole owner of open work. |
| `TODO-2026-07-14.md` | 122 | **ARCHIVE per BACKLOG §7** | Corrected from FREEZE. Both BACKLOG references are bare filename mentions, no line numbers — and `BACKLOG.md:640` is an open item explicitly asking to archive it (25/26 done). Follow BACKLOG; do not overrule it. Fix its two wrong "done" claims (`REVIEW-2026-07-24.md:432`, lines 84 and 102) or note them, first. |
| `TODO-2026-07-23.md` | 178 | **FREEZE** | One bare mention at `BACKLOG.md:7`, no line citations — freezing is a courtesy, not a constraint. |
| `TODO-2026-08-03.md` | 1091 | **FREEZE — hard constraint** | 9 BACKLOG references, **8 with line numbers**, including three scheduled deadlines at `BACKLOG.md:555-557`. |
| `m5fw-contrib-README.md` | 41 | **MERGE** → `gitops/workloads/ai-gateway/m5stack-adapter/README.md` | Corrected target. It is a build/apply procedure for the M5Stack firmware, not routing design; the adapter's own README is the natural home. 0 inbound links, untouched since 2026-06-18. |

### `docs/` — reference (as-built)

| File | Lines | In | Disposition | Rationale |
|---|---:|---:|---|---|
| `ARCHITECTURE.md` | 220 | 6 | **GENERATE** + **FIX** ×2 | Correct entry point. Replace fleet + service-map tables (23 IP literals). **§0: `:134` is the wrong wildcard IP; `:146` needs the CoreDNS adjudication.** Also §6.6: `:176` "Bookworm flash pending" contradicts `:140`. |
| `HARDWARE.md` | 159 | 8 | **KEEP** + **FIX** | Sole owner of hardware detail; 43 IP refs legitimate here. **§0: `:88`.** |
| `services.md` | 125 | 6 | **GENERATE** + **FIX** | Catalogue becomes generated. **§0: `:14`.** Truncation is real but at **`:125`** (ends "…Real offsite"), *not* `:121` as BACKLOG §6.9 claims — correct BACKLOG too. |
| `OVERVIEW.md` | 77 | 2 | **MERGE → `README.md`, with conditions** | See §6.1 — it is line-cited by BACKLOG, and ~11 of its ~45 bullets exist nowhere in README. Not a free deletion. |
| `SECURITY.md` | 84 | 7 | **KEEP** + **FIX** | Sole owner of posture. §6.11: `:38-39` claims a scoped kubeconfig that does not exist; `:52-54` describes permission tiers absent from `.claude/settings.json`. |
| `SSO.md` | 130 | 3 | **GENERATE** | Sole owner of identity flow; 13 URLs generated. |
| `AI-INFERENCE.md` | 202 | 4 | **KEEP** | Sole owner of model/NPU detail. |
| `AI-ROUTING.md` | 111 | 0 | **KEEP** + **FIX** | Escalation tiers (`:8-32`) exist in detail nowhere else. Link from `ARCHITECTURE.md` and `README.md`. |
| `CAPABILITY.md` | 125 | 0 | **KEEP** + **FIX** | Unique compute/power/thermal analysis. Link it, or it gets re-derived by someone who never found it. |

### `docs/` — procedures

| File | Lines | In | Disposition | Rationale |
|---|---:|---:|---|---|
| `RUNBOOK.md` | 316 | 11 | **KEEP** + **FIX** | Most-linked doc in the repo. Owner of bring-up, verification, recovery. **§0: `:26`.** |
| `OPS.md` | 712 | 2 | **KEEP** | Owner of routine task recipes. Add scope note: "recurring tasks; one-time bring-up is in RUNBOOK". |
| `UPDATES.md` | 334 | 2 | **KEEP** + **FIX** | Owner of the patching story. §6.8 Authelia→PostgreSQL stale row is at **`:329`** (BACKLOG says `:325`, which is the section heading). |
| `BACKUP-RESTORE.md` | 387 | 3 | **KEEP** + **FIX** | Owner of backup/restore. §6.7 stale rows are at **`:369`** and **`:372`** (BACKLOG's `:360` is the heading). §6.3: `:100` documents the abolished Vault root token. |
| `TROUBLESHOOTING.md` | 474 | 1 | **KEEP** | Owner of symptom→fix. Under-linked; link from `RUNBOOK.md` and `README.md`. |
| `BREAK-GLASS.md` | 166 | 2 | **KEEP — special status** | See §8. Exempt from generation. |
| `WORKFLOWS.md` | 242 | 3 | **SPLIT, then delete — see §7** | Corrected from an unconditional delete. Five sections, not four, and it holds content that exists nowhere else in the repo. |

### `docs/` — design intent, not as-built

These describe a *plan*. Maintaining them as if they described the lab is how design drift
becomes documentation drift.

| File | Lines | In | Disposition | Rationale |
|---|---:|---:|---|---|
| `LAB-DESIGN.md` | 191 | 1 | **FREEZE** | Already carries the right banner at `:3` ("original design proposal… KVM/libvirt, not Proxmox"). Make that banner the standard. **FIX**: `## Node placement` duplicated at `:47` and `:49`. |
| `STANDUP.md` | 215 | 4 | **FIX, then FREEZE** | Bring-up narrative; Phase 5 is Proxmox, never built. **Two blockers before freezing:** §0 (`:36`, `:72`), and §6.12 — an "unresolved H4 CRC fault" at `:213-215` appearing nowhere else in the repo. Either it is real and belongs in `BACKLOG.md`, or it is closed and should say so. **Do not freeze an open thread.** |
| `GITOPS-STUDY-GUIDE.md` | 809 | 1 | **FIX, then FREEZE** | Learning material; largest doc in `docs/`. §0 at `:558`, `:624` — teaching the wrong value is worse than recording it. |
| `HOSTMON-BUILD.md` | 118 | 0 | **FREEZE** | Build notes for a one-off. |
| `sso-authelia-minio-troubleshooting.md` | 344 | 0 | **SPLIT → `TROUBLESHOOTING.md`** | 0 inbound links, lowercase name breaks convention, and it is a troubleshooting doc outside the troubleshooting doc. **Must preserve `:65-102`** — the hairpin-NAT fix (in-cluster pods resolving `*.apps.lab.home.arpa` to the VIP; fixed with `hostAliases` to Traefik's ClusterIP). Unique, durable, and entangled with the §0 CoreDNS question. `:161` duplicates `TROUBLESHOOTING.md:218` and can be dropped. Header `:11` also carries the §0 defect. |

### `docs/` — evidence

| File | Lines | In | Disposition |
|---|---:|---:|---|
| `REVIEW-2026-07-24.md` | 492 | 12 | **FREEZE — hard constraint.** 13 BACKLOG references, 9 with line numbers. Load-bearing as evidence; never edit. |

### Net effect

**33 files → 29.** Four removed: `OVERVIEW.md` (conditionally), `WORKFLOWS.md`,
`m5fw-contrib-README.md`, `sso-authelia-minio-troubleshooting.md`. `TODO-2026-07-14.md`
archives per BACKLOG §7, which may or may not mean deletion — that is BACKLOG's call.

The file count is the least interesting number here. The real one: **~290 hand-typed facts
become 5 generated blocks**, and the eleven-way split that caused §0 becomes one.

## 6. Freeze, do not delete — and check before you merge

The obvious move is "archive the dated TODOs, git remembers." **That is wrong here**, and
checking the repo is what showed it.

`BACKLOG.md` cites its evidence by file *and line number*:

- `docs/REVIEW-2026-07-24.md` — 13 references, 9 with line numbers
- `TODO-2026-08-03.md` — 9 references, 8 with line numbers, incl. three live deadlines
- `TODO-2026-07-14.md` — 2 references, **neither** with a line number
- `docs/OVERVIEW.md` — 1 reference **with** a line number (`BACKLOG.md:347` → `:72`)
- `README.md` — 1 reference with a line number (`BACKLOG.md:347` → `:167`)

Deleting or renumbering a line-cited file strips `BACKLOG.md` of the evidence that makes it
trustworthy — the property its own preamble rests on ("Items marked **verified** were
checked against the code"). Moving files into `docs/archive/` breaks every path. Editing
them invalidates every line number.

**Therefore:** frozen files stay at their current paths with their current line numbering.
They get a banner and nothing else, ever:

```markdown
> **FROZEN 2026-08-15 — historical record.** Do not edit; `BACKLOG.md` cites this file by
> line number. Statements here were true when written and may be false now. For current
> state see [`../BACKLOG.md`](../BACKLOG.md) and [`ARCHITECTURE.md`](ARCHITECTURE.md).
```

A frozen file is exempt from the §7 lint by definition — being out of date is its job. That
exemption is what makes freezing cheap: it leaves the repo but leaves the maintenance
surface.

### 6.1 `OVERVIEW.md` — conditions before merging

Two conditions, both discovered by audit:

**(a) It is line-cited.** `BACKLOG.md:347` (§2.6, Vault plaintext HTTP) cites
`docs/OVERVIEW.md:72` and `README.md:167`. **Both citations are already stale** —
`OVERVIEW.md:72` is now the deferred-items pointer, not a Vault-HTTP statement. Fix
`BACKLOG.md:347` to cite `ansible/templates/vault.hcl.j2:8-9` (which is accurate and is
the real source) *before* touching either file. Then the merge is safe.

**(b) The overlap is ~70%, not ~90%, and the residue is not what generation captures.**
These facts appear in `OVERVIEW.md` and nowhere in `README.md`, and none are
workload/ingress/fleet facts, so the `workloads` block will not reproduce them:

- `:11` shared NFS `/srv/libvirt-shared` for VM live migration
- `:12`, `:66` OpenTofu `tofu/vms/` module; DNS module parked (Pi-hole v5 provider vs v6)
- `:32` Promtail removed, Alloy DaemonSet
- `:34` `node-exporter` on non-cluster hosts
- `:35` `smartd` / `mdadm` disk + RAID alerting
- `:40` rknpu 0.9.6 caps NPU alloc to ~2.2 GB
- `:43` OVMS disabled, crash-looping
- `:44` M5Stack 3-tier escalation router *(the only summary pointing at `AI-ROUTING.md`)*
- `:46` Claude Code orchestrator live on opi5pro-1, HTTPS :8443
- `:53` `gitlab.lab.home.arpa`
- `:65` GitHub Actions self-hosted runner on H4 + weekly scheduled maintenance

Route each to an owner explicitly before deleting the file. Several belong in
`ARCHITECTURE.md` rather than `README.md`.

## 7. `WORKFLOWS.md` — split, do not just delete

The first draft called this "the file with no exclusive territory." **That was wrong.** It
has five H2 sections, not four, and reading it in full turns up content with no counterpart
anywhere in the repo.

**Must be preserved — unique:**

| Content | Where | Proposed owner |
|---|---|---|
| `scripts/sync-vault-to-ansible-vault.sh` invocation | `:112`, `:136` | `RUNBOOK.md` Vault ops — **the only reference to this script anywhere in the repo**; the script exists on disk |
| 4-step password-rotation procedure (`rotate-passwords.yml`) | `:130-145` | `OPS.md` — the playbook is named elsewhere but the procedure exists only here. `OPS.md:496` is a *different* thing (`ansible-vault rekey`) |
| Full `secret/lab/*` path inventory, 10 paths | `:80-91` | `RUNBOOK.md` — `secret/lab/lab-ca` appears in no other file; README has a 3-item subset |
| "Three-direction sync loop" diagram | `:93-99` | `RUNBOOK.md` — string "Three-direction" occurs only here |
| `## Key risk: single failure domain` | `:229-242` | `docs/ARCHITECTURE.md` §Storage tiers — the fifth section the first draft did not account for |

**Safe to drop — genuinely duplicated:** `:7-29` updates (→ `UPDATES.md`, `OPS.md`),
`:33-69` adding capabilities (→ `OPS.md:202`, `RUNBOOK.md:107`), `:161-195` Vault recovery
(near-verbatim in `RUNBOOK.md:166-203`), `:218-225` RAID degraded (`RUNBOOK.md:251-258`).

Also fix §6.3 here: `:118-128` documents the Vault root token that must not exist. Do not
carry that table into the new home.

**Sequence: move the unique content first, in its own commit; delete the file in a second
commit.** That way the deletion diff is provably subtractive-only.

## 8. `BREAK-GLASS.md` is exempt

It has to be correct **on paper, offline, with the cluster down**. It cannot depend on
generation from a repo you may not be able to clone, or a check running in CI you may not
be able to reach. `scripts/print-offline-envelope.sh` already reflects this.

Treat it as the one deliberately hand-maintained, manually verified file — and give it what
nothing else here gets: a **restore rehearsal** that proves it. That is `BACKLOG.md` §1.1,
still the single most valuable open item in the repo, and nothing in this plan displaces
it.

## 9. What CI enforces afterwards

Consolidation without enforcement decays back within a quarter. Additions to
`.github/workflows/validate.yml` — all offline, no cluster, matching the constraint that
file documents at `:8-11`:

1. **Generated-block drift** — regenerate; fail on diff.
2. **Unknown IP literals** — any `192.168.1.x` in a non-frozen doc absent from `hosts.yml`.
3. **The `.160` wildcard trap** — `192.168.1.160` on any line mentioning
   `*.apps.lab.home.arpa`, with the message from `CLAUDE.md:53-55`. **Would currently fail
   on 8 files** — hence §0 comes first.
4. **Truncated files** — last non-empty line must end in `.`, `:`, `|`, `)` or `-`. Catches
   `services.md:125`. Note what this defect *did*: a half-written sentence in `HARDWARE.md`
   kept a closed issue alive across two audits.
5. **Dead internal links** — every `docs/*.md` relative link must resolve.
6. **Duplicate H2 headings within a file** — catches `LAB-DESIGN.md:47/:49`; early warning
   for competing lists.
7. **Frozen files unchanged** — a diff to any bannered file fails the build.
8. **BACKLOG citation integrity** — every `file:line` cited in `BACKLOG.md` must resolve to
   an existing file with at least that many lines. Added because the audit found
   `BACKLOG.md:347`, `:604` and `:612` all citing lines that have moved or never matched.

Roughly 120 lines of Python. All deterministic; none of it uses a model.

## 10. Sequence

Each step independently mergeable and reversible.

| # | Step | Effort | Notes |
|---|---|---|---|
| **0** | **Fix the 8 `.160` wildcard references (§0)** | **S** | **Do first.** Only item that can cause an outage. Adjudicate CoreDNS/tofu separately. |
| 1 | Resolve `STANDUP.md:213-215` (H4 CRC fault) into `BACKLOG.md` or close it | S | Must precede freezing `STANDUP.md` |
| 2 | Fix `BACKLOG.md:347` citation; correct §6.9 `:121`→`:125`, §6.8 `:325`→`:329`, §6.7 `:360`→`:369,:372` | S | Unblocks the `OVERVIEW.md` merge; makes lint rule 8 passable |
| 3 | Banner the 6 freeze files; add lint rule 7 | S | Removes ~3,000 lines from the maintenance surface |
| 4 | Build the generator + `vips` and `fleet` blocks; wire lint rules 1–3 | M | Kills §0's class permanently, plus §6.1, §6.4, §6.10 |
| 5 | Add `ingress`, `workloads`, `host-services` blocks | M | |
| 6 | Split `WORKFLOWS.md` per §7 — move first, delete second | M | Two commits |
| 7 | Merge `OVERVIEW.md` → README/ARCHITECTURE per §6.1(b) | M | Blocked on step 2 |
| 8 | Fix remaining §6 items in place (6.3 ×2, 6.6, 6.11) | M | Closes §6 |
| 9 | Split `sso-authelia-*` (preserve `:65-102`); move `m5fw-contrib-README` | S | −2 files |
| 10 | Add lint rules 4–6, 8 | S | Prevents recurrence |
| 11 | Scope banners + missing cross-links (`AI-ROUTING`, `CAPABILITY`, `TROUBLESHOOTING`) | S | Stops re-derivation of unlinked docs |

Steps 0–4 carry nearly all the value. Steps 0–3 are cheap and should go this week.

Freeze files for step 3: `TODO-2026-07-23.md`, `TODO-2026-08-03.md`, `LAB-DESIGN.md`,
`STANDUP.md` (after step 1), `GITOPS-STUDY-GUIDE.md`, `HOSTMON-BUILD.md`,
`REVIEW-2026-07-24.md` — plus `TODO-2026-07-14.md` if BACKLOG §7's "archive" is read as
freeze-in-place.

## 11. Corrections applied after audit

Recorded rather than silently fixed, on the same principle `BACKLOG.md` §6 uses — a
document that quietly rewrites itself teaches you nothing about how it went wrong.

| Draft claim | Corrected to |
|---|---|
| 31 files / ~7,900 lines | **33 / ~8,850** — the glob missed `gitops/workloads/ai-gateway/m5stack-adapter/README.md`, one directory deeper |
| 174 IP literals | **184** |
| 81 ingress URLs | **92** |
| `WORKFLOWS.md` "no exclusive territory", delete | **Five sections; five unique items** — see §7 |
| `OVERVIEW.md` ~90% overlap, free deletion | **~70%; line-cited by BACKLOG** — see §6.1 |
| `TODO-2026-07-14.md` "cited, cannot delete" | **Not line-cited; BACKLOG §7 asks to archive it** |
| `m5fw-contrib-README.md` → `AI-ROUTING.md` | **→ `m5stack-adapter/README.md`** — it is build content, not design |
| `services.md:121` "Improvement need" | **`:125`** — copied from `BACKLOG.md:612` without reading the file. The exact failure mode this plan exists to prevent. |
| `UPDATES.md:325`, `BACKUP-RESTORE.md:360-372` | **`:329`; `:369`, `:372`** — BACKLOG's ranges start on headings |
| `CLAUDE.md:52-56` | **`:53-55`** |
| Net 31 → 25 | **33 → 29** |
| "6 freeze files, ~2,600 lines" | **8 files, 3,216 lines** |
| §6.1 framed as fixed | **§0 — still live in 8 files** |

The last row is the important one. The first draft repeated a "DONE" status from another
document without checking the code — which is, precisely, the bug.

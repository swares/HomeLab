# The Lab Ledger — design sketch

A long-retention, queryable record of **what happened and when**, separate from the
30-day log firehose, built so that a human or an agent can ask *"what changed the day
X broke?"* and *"have we broken this before?"* and get an answer grounded in facts
rather than in prose that may have drifted.

Status: **design sketch, nothing built.** No engine has been chosen. The engine choice
is deliberately the last decision, not the first (§8).

> **Guiding principle.** `docs/BACKUP-RESTORE.md` says *"a backup you have not restored
> is a hypothesis, not a backup."* The ledger's equivalent: **a claim not anchored to an
> event is a hypothesis, not a fact.** This document exists because retrieval over an
> unreliable corpus does not surface truth — it launders drift into apparent authority.

---

## 1. The question, and why the lab cannot answer it

The motivating query is concrete. Until 2026-07-27 the `*.apps.lab.home.arpa` wildcard
was a single A record pointing at `192.168.1.160` — the H4's own node IP — rather than
`192.168.1.201`, the kube-vip service VIP that floats between control-plane nodes. That
made every service URL in the lab depend on one host staying up, and losing it took
them all down, even though (per `ansible/inventory/hosts.yml:41-43`) k3s servicelb had
Traefik answering on all five node IPs the whole time. On 2026-07-27 the record was
moved to `.201`. The useful question, during the outage and after it, is: **what else
changed around then?**

Today that question is unanswerable, and not for want of a search engine:

| Source | What it knows | What is retained |
|---|---|---|
| Kubernetes Events | scheduling failures, probe failures, image pulls, OOM kills, Argo sync results | **~1 hour.** `--event-ttl` defaults to `1h0m0s`; then etcd garbage-collects |
| Alloy → Loki | pod logs, systemd journal (`max_age = "12h"`) | 30 days — but **`loki.source.kubernetes_events` is not configured**, so no events at all |
| Argo CD notifications | sync-failed, health-degraded | **nothing.** Fire-and-forget webhook to the M5Stack (`notifications-cm.yaml`); no store |
| Alertmanager | alert firings | **no queryable history.** Three receivers — `m5stack` (catch-all default), `ntfy`, `watchdog`. Its 2Gi PVC holds nflog/silences, not an alert log |
| healthchecks.io | backup liveness pings | external, free tier, not queryable from the lab |
| Git | ~730 commits, every cluster change | full history, but not joinable to anything above |

So five of the six sources that would answer the question are discarding their output
within the hour, or never producing a durable record at all. **The bottleneck is
capture, not query.** Standing up a search engine first would index an absence.

This is the single most important finding in this document. Every hour of delay is an
hour of ledger that cannot be recovered later; by contrast, deferring the engine choice
costs nothing, because a captured stream can be reindexed at any time.

---

## 2. Two corpora, opposite shapes

Much of the apparent cost of this project came from sizing one store for two jobs that
have nothing in common:

| | **Logs** | **Ledger** |
|---|---|---|
| Content | every line every pod emits | discrete facts: a commit, a sync, an alert, a job exit |
| Volume | gigabytes/day | kilobytes/day |
| Useful retention | 30 days | **years** |
| Cardinality | enormous | small |
| Home | Loki (already correct, leave alone) | new, small, long-lived |
| Value decay | steep — last week's pod logs are noise | flat — a 2026 incident still matters in 2029 |

Five years of this lab's ledger is on the order of tens of megabytes. Storage is a
non-issue; the only real cost is whatever the query engine's process floor turns out to
be. **Do not put the ledger in Loki's retention class, and do not put logs in the
ledger's.**

---

## 3. Sources and capture

Ordered by value per unit of effort.

### 3.1 Phase 1 — capture what is currently being destroyed

| Source | Mechanism | Notes |
|---|---|---|
| Kubernetes Events (all namespaces) | a second, singleton Alloy release — `gitops/apps/alloy-events.yaml` | **Not** a block added to the existing `alloy` release: that one is a DaemonSet, and the component watches the API server rather than the local node, so all five pods would ship a duplicate copy of every event. A singleton `Deployment` avoids that without enabling clustering on a healthy log pipeline. The chart's default RBAC already grants `events` watch. `log_format = "json"` so structure survives into the eventual ledger |
| Git commits | CronJob or CI step walking `git log` since last indexed SHA | ~730 commits at time of writing. Fields: SHA, timestamp, author, subject, files changed, PR number. Backfillable in full — this is the one source with complete history already |

Phase 1 is deliberately shippable without choosing an engine: events land in Loki
(30d) as a holding pen while the ledger design settles. Losing older events during
that window is acceptable; losing them *forever* starting now is not.

### 3.2 Phase 2 — sources needing a small shim

| Source | Mechanism | Notes |
|---|---|---|
| Argo CD sync/health | add a second `service.webhook` receiver alongside the M5Stack one | The triggers already exist (`on-sync-failed`, `on-health-degraded`). Consider adding `on-sync-succeeded` — the ledger wants successes too, since "what changed" is mostly successful changes |
| Alertmanager firings | add a fourth receiver to the existing route tree | Read `monitoring.yaml:279` first: the tree already has three live receivers plus `null`, `m5stack` is the catch-all default, and **Alertmanager stops at the first matching route**. The ledger receiver needs `continue: true` or it will silently steal alerts from the notification path |
| Backup outcomes | `backup-verify.sh` already prints structured `ok:` / `FAIL:` lines weekly | Emit as JSON alongside the human-readable output rather than parsing prose |
| Ansible runs | Semaphore keeps task history in its own DB | Lowest priority; export on a schedule |

### 3.3 Explicitly out of scope

Pod logs (Loki has them), metrics (Prometheus has them), and NAS file activity. The
ledger records *changes and outcomes*, not continuous telemetry.

---

## 4. Schema

Index (or collection) per source, sharing a common envelope so cross-source queries on
the time axis work without joins:

```
@timestamp     RFC3339, UTC                    — the shared axis, non-negotiable
source         k8s-event | git | argo | alert | backup | ansible
actor          who/what caused it              — human, controller, timer
subject        the thing acted on              — app name, host, unit, path
action         created | synced | failed | degraded | fired | resolved | exited
outcome        success | failure | unknown
detail         source-specific object          — kept nested, not flattened
refs[]         identifiers mentioned           — see below
```

`refs[]` is the field that makes this lab's data work. Extract identifiers at write
time: IPs (`192.168.1.201`), hostnames (`n150-1`), systemd units
(`backup-offsite.timer`), k8s resources (`vg_microshift`, `local-path`), file paths,
PR numbers. These are terrible embeddings — `192.168.1.160` and `192.168.1.201` sit
almost on top of each other in vector space, which is precisely the confusion that
caused the outage — but they are perfect exact-match tokens. **Any engine chosen must
support exact-token retrieval over `refs[]`, not dense vectors alone.**

Retention: no expiry on the ledger indices. Revisit if it ever exceeds a gigabyte,
which on current projections is roughly never.

---

## 5. The trust model — ledger vs narrative

Two classes of content, and conflating them is how a memory system becomes actively
harmful.

**Ledger entries are true by construction.** A commit happened. A sync failed at
14:32. A unit exited 0. These are observations, immutable, timestamped, and they do not
rot.

**Narrative is a claim about the past, and it decays.** `README.md`, `BACKLOG.md`,
`docs/*.md`, `CLAUDE.md` — all valuable, all capable of being wrong. This repo's own
README documents the failure mode:

> It drifted: it claimed offsite restic backup was done (it had never copied a byte),
> and it duplicated items that also appeared in `docs/OVERVIEW.md`, `docs/services.md`,
> `docs/STANDUP.md` and three dated `TODO-*.md` files, each with a different idea of
> what was outstanding.

Point a naive retrieval system at that corpus, ask "is offsite backup working?", and it
returns the confident false claim **with a citation**. That is worse than no memory at
all, because it is actionable. High-confidence wrong beats "I don't know" only in the
sense that it does more damage.

**Rule: index both, but never return narrative without its event anchor.** A claim
retrieved from prose is presented alongside the ledger entries that do or do not
support it, with the dates of both. The reader — human or agent — sees "the doc says X,
as of date D; the ledger last saw a supporting event on date E" and can judge.

---

## 6. Contradiction detection — the actual payload

Search is the obvious feature. It is not the valuable one. **The valuable one is
mechanically detecting where the ledger and the narrative disagree.**

### Worked example — the offsite backup

The prose said the offsite backup was done. The ledger would have shown
`backup-offsite.service` exiting 0 in a fraction of a second, every night, having
transferred zero bytes. Nobody had to read anything cleverly. The two records
disagreed, visibly and mechanically, **for months**. A weekly job asking *"which
claimed-DONE items have no supporting ledger event in the last 30 days?"* would have
caught it the first week.

Note that `backup-verify.sh.j2` was written for exactly this class of bug and says so
in its header — three mechanisms reporting success while doing nothing. The ledger
generalises that script's insight from backups to every claim in the repo.

### A live one, found while writing this

`docs/BACKUP-RESTORE.md` states in two places — lines 30–32 and again in the findings
table at line 372 ("Two offsite mechanisms, one fake") — that `backup-offsite.timer` is
a **no-op**: that its repo variable defaults to empty, the unit logs `skipping` and
exits 0, that `backup-cloud` → R2 is the real offsite, and that one of the two should
be deleted.

That was true. It is no longer. `BACKLOG.md` §1.3 records the `homelab-nas` seed
completing 2026-08-11 (~204 GiB, 3.1 days), the timer confirmed enabled and active by
`systemctl` on 08-15, nightly incrementals running in 73 seconds against 37 snapshots,
weekly integrity checking added to `backup-verify.sh` (§1.3b), and — decisively — a
successful restore drill on 2026-08-16 pulling a byte-identical dump from
`homelab-nas` snapshot `23056e8d`. The two buckets are also **deliberate, not a
mistake**: `ansible/playbooks/backup-offsite.yml:22` marks the separation from
`homelab-backup` as intentional — small fast-moving cluster state on one policy, a
large slow archive on the other.

So `BACKUP-RESTORE.md` — the document whose own opening principle is that a backup you
have not restored is a hypothesis — currently tells a reader to delete the one offsite
tier that has actually demonstrated a restore. **This should be corrected by hand
regardless of whether the ledger is ever built.**

What makes it the ideal specimen is that the file **contradicts itself**, and the
contradiction has been sitting there unnoticed. Line 356 of that same document records
the successful 2026-08-16 restore from `homelab-nas` — sixteen lines before the table
that calls the mechanism fake. Nobody had to cross-reference two files or reason about
prose; the disagreement is on one page. It survived because no check exists that reads
a document against its own dated claims, which is a smaller and much more tractable
problem than general fact-checking.

`BACKLOG.md` §1.3 makes the same point independently. It carries a note about a
*different* stale marker in that section being misread on 2026-08-15 as evidence the
timer was off, ending with the instruction **"Check the unit, not this file."** That is
this document's thesis, written down in the lab three days ago, on the page that
catalogues the failure mode.

A worked demonstration, for honesty's sake: the first draft of this section asserted
that the two bucket names were a contradiction and that one was wrong. That was
produced by reading two documents and reasoning about the prose — no ledger, no event
anchor — and it was confidently wrong in a way that would have sent someone to "fix" a
working backup tier. It was caught by checking the code and the dated records. That is
precisely the failure this design exists to prevent, and it happened while writing the
design.

### The recurring shape: success reported, nothing done

Every specimen above is the same bug wearing different clothes. `backup-offsite`
exiting 0 having copied zero bytes. `backup-etcd` snapshotting a file deleted a month
earlier and pinging healthchecks.io green for a month. `backup-cloud` retention
deleting nothing because a random staging path put every snapshot in its own group.
A CI job that could not report failure because its loop ran in a subshell. In each
case the mechanism emitted its success signal correctly; the *outcome* was absent.

**A third instance appeared while this branch was being pushed, on 2026-08-19.** A
stale zero-byte `.git/index.lock`, ~22 hours old from a crashed process, made
`git add` and `git commit` fail. The subsequent `git push` then succeeded — creating
the remote branch, printing a "Create a pull request" URL, and reporting
`Total 0 (delta 0), reused 0`. The branch was pushed pointing at the same SHA as
`main`, containing none of the work. Every signal git normally emits on success was
emitted. The only evidence was the object count.

This generalises the design's premise: **the check must be on the outcome, never on
the exit code.** `backup-verify.sh` already applies that rule to backups; §6 applies
it to documents; the list below applies it to everything else.

### Checks worth running weekly

- Claimed-DONE backlog items with no supporting ledger event
- Documented hosts/IPs that no ledger entry has mentioned in 90 days (decommissioned but still documented — cf. the `ldap-1` VM)
- Timers that report success but whose duration or byte count is implausible
- Ingress hostnames in docs with no corresponding sync event
- Documents whose last edit predates the last change to the thing they describe
- **Branch refs created or updated with no new commit SHA** — a push that moved a ref while transferring zero objects. Cheap to detect once git is a ledger source: the ref event exists, no corresponding commit event does
- **Stale lock files** older than a few hours anywhere git or a backup repo is used (`.git/index.lock`, restic locks). These do not announce themselves; they turn later commands into no-ops that still exit 0

---

## 7. The agent interface

For an agent to use any of this, the ledger needs an **MCP server** in front of it.
Without one it is a human tool behind a dashboard, and the "remember what we broke last
time" goal is unmet. This is a required component, not a follow-up.

Proposed surface, deliberately small:

| Tool | Purpose |
|---|---|
| `ledger_search(query, refs[], time_range)` | Hybrid: exact-match on `refs[]` + semantic over text |
| `ledger_window(timestamp, ±duration)` | "What changed the day X broke" — all sources, one axis |
| `ledger_history(subject)` | Every event touching a host/app/unit, oldest first |
| `claim_check(assertion)` | Returns supporting and contradicting evidence, with dates |

Trust rules the server enforces, not the caller:

1. Every result carries `source`, `@timestamp`, and provenance.
2. Narrative results are never returned bare — always with anchoring or contradicting ledger events.
3. Absence is reported explicitly. "No events found" must be distinguishable from "no events exist", or the agent will read silence as confirmation.
4. Read-only. The ledger is append-only from its collectors; nothing queries its way into a write.

**Scope caution.** `CLAUDE.md` is already this system, hand-run: the `.160` rule, the
two-checkout hour, the envelope-script duplication are curated lessons injected into
context, and they work. The ledger is the raw material curation draws from — it does
not replace the curation, and a lesson worth keeping still belongs in `CLAUDE.md`.

---

## 8. Engine choice — deferred on purpose

Not decided. Criteria, in priority order:

1. **Exact-token retrieval over `refs[]`** (§4) — hard requirement
2. Multi-index queries on a shared time axis (§6 depends on it)
3. Resource floor on a node already carrying kube-prometheus-stack and Loki
4. Snapshot to the existing MinIO
5. Compatibility with the `disallow-privileged-containers` ClusterPolicy, in Enforce mode

Candidates and their known shape against those criteria:

- **OpenSearch** — strongest on (1), (2) and ad-hoc exploration via Dashboards; weakest on (3) at a ~2 GB heap / ~4 GB limit floor; needs the `vm.max_map_count` sysctl set on the host via Ansible (pattern exists in `ansible/playbooks/zswap.yml`) with the chart's privileged init container disabled, to satisfy (5).
- **Qdrant** — strong on (1) via BM25 sparse vectors with the IDF modifier, ~300 MB, no sysctl friction, native S3 snapshots; weak on (2), which is most of §6.
- **Postgres** — worth a serious look given the ledger is small, relational, and this lab already runs several instances. Full-text search plus `pgvector` covers (1); ordinary SQL covers (2) better than either of the above. Do not attach to Immich's instance — it is app-owned and upgrade-coupled.

The Phase 1 capture work is engine-independent, which is why it goes first.

---

## 9. Risks and non-goals

- **This does not prevent incidents.** It shortens the second occurrence.
- **Garbage in.** If collectors silently stop, the ledger reports false absence — precisely the failure mode it exists to detect, now one level up. The ledger needs its own liveness check, and it should not be the ledger's own job to notice.
- **Scope creep into observability.** The ledger is not a SIEM, not an APM, not a Loki replacement. If it starts ingesting log lines, it has failed.
- **One more thing to maintain.** Weighed against a lab whose documented history includes an hour lost to two checkouts, a duplicated script across two spellings, and months of a backup that copied nothing.

---

## 10. Open questions

1. Which node? n150-2 carries no pinned cluster workload today — everything selects `n150-1`, `odroid-nas` or the OPis — and `docs/BREAK-GLASS.md:237` already recommends it over n150-1 "which carries the monitoring stack". Two caveats: it is also a KVM hypervisor, so "least loaded" is true only of cluster load; and on 2026-07-25 it wedged twice, taking all SSO down with it because a node-bound `local-path` PV could not reschedule (`gitops/workloads/lldap/postgres.yaml:6`). Siting the ledger there on `local-path` reproduces that exact failure mode.
2. Is the ledger in-cluster (Argo-managed, subject to the outages it records) or on a host outside it? An incident record that goes down during incidents is worth less — and question 1 is a concrete instance of this.
3. Do commit *diffs* get indexed, or only metadata? Diffs are much larger and mostly noise, but "what changed" sometimes means the hunk.
4. Retention on the k8s-events stream specifically — it is the highest-volume ledger source by an order of magnitude and may want its own, shorter class.
5. Backfill: git gives every commit in the repo's history for free. Is there value in a one-time pass over `BACKLOG.md`, `REVIEW-2026-07-24.md` and the dated `TODO-*.md` files to seed the narrative side with dated claims?

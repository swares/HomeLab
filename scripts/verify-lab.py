#!/usr/bin/env python3
"""
Assert that the lab's control mechanisms actually WORK — not that they exist.

Every check here exists because the corresponding mechanism was, at some point,
configured correctly and silently doing nothing. docs/REVIEW-2026-07-24.md put it
best: "Several mechanisms the lab depends on report success while doing nothing."
Config presence is not evidence. These are the assertions that would have caught
each failure the week it started rather than months later.

Read-only. Makes no changes and needs no privileges beyond a working kubeconfig
and LAN access to Prometheus.

Usage:
    scripts/verify-lab.py                    # all checks
    scripts/verify-lab.py --check pdb dns    # a subset
    scripts/verify-lab.py --list             # what exists and why
    scripts/verify-lab.py --json             # machine-readable

Exit codes:
    0  all checks passed
    1  at least one FAIL
    2  a check could not run (Prometheus unreachable, kubectl missing, ...)
       — deliberately distinct from FAIL: "I could not look" must never be
       mistaken for "I looked and it was fine". That conflation is the entire
       reason this script exists.
"""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROM = "https://prometheus.apps.lab.home.arpa"
API_VIP = "192.168.1.200"        # kube-vip control-plane VIP — api.lab.home.arpa
# kube-vip service VIP for Traefik — *.apps.lab.home.arpa. Was 192.168.1.160
# (the H4) until 2026-07-27; a single A record whose loss took down every service
# URL in the lab. Must match `ingress_vip` in ansible/inventory/hosts.yml, which
# is the source of truth applied by ansible/playbooks/dns.yml.
INGRESS_VIP = "192.168.1.201"

# Metrics known to be absent, with the reason. Anything absent and NOT listed
# here is a finding. Keeping this list short and annotated is the point: an
# entry is an admission that an alert cannot fire.
# Emptied 2026-08-07. Both former entries were wrong, and being wrong here is worse
# than being absent — a suppression tells the verifier not to look.
#
#   "node_systemd_unit_state" was excused on the grounds that the collector "cannot
#   read /run/systemd/private (runs as 65534, socket is 0700 root)". That diagnosis
#   was retracted on 2026-08-02: the collector uses the D-Bus SYSTEM bus, not
#   systemd's private socket, and it works once the socket is mounted into the pod
#   and AppArmor is unconfined on Ubuntu nodes. See the NOTE at the top of
#   gitops/workloads/monitoring/lab-alerts.yaml. The metric has been present since,
#   and LabBackupUnitFailed depends on it — so this entry was telling the verifier
#   to ignore a working metric that a critical alert relies on.
#
#   "node_systemd_timer_last_trigger_time_seconds" does not exist under that name at
#   all; the real metric has no "_time" in it. Suppressing a typo suppresses nothing
#   and hides the fact that nothing was ever checked.
#
# Keep this dict short and annotated. An entry is an admission that an alert cannot
# fire — and, as of 08-07, one that must be re-checked against the exporter before it
# is added, not inherited from an older note:
#   curl -s http://<host>:9100/metrics | grep node_systemd_unit_state
KNOWN_ABSENT = {}

# Different thing entirely: metrics absent BECAUSE THE LAB IS HEALTHY.
# kube-state-metrics emits condition series only for conditions a resource actually
# carries, so a metric describing failure has no series while nothing has failed.
#
# NOT the same as KNOWN_ABSENT. There the alert cannot fire; here it fires perfectly
# and the absence is the good outcome. Conflating them would either make this check
# permanently red on a healthy lab, or — worse — train someone to move a genuinely
# broken metric here to quiet it.
#
# Only add something if you have SEEN the alert fire. LabBackupJobFailed was proven
# on 2026-08-07 with a deliberately failing Job (backup-alerttest) that paged via
# ntfy and resolved on deletion.
ABSENT_WHEN_HEALTHY = {
    "kube_job_failed":
        "kube-state-metrics emits this only for Jobs carrying a Failed condition, "
        "so it has zero series when no Job has failed. LabBackupJobFailed was "
        "verified firing end-to-end on 2026-08-07.",
}

FAIL, PASS, ERROR = "FAIL", "PASS", "ERROR"


class CheckError(Exception):
    """Raised when a check cannot run, as distinct from failing."""


def sh(*args, timeout=60):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise CheckError(f"{' '.join(args[:3])}...: {r.stderr.strip()[:200]}")
    return r.stdout


def kubectl_json(*args):
    return json.loads(sh("kubectl", *args, "-o", "json"))


def promql(query, strict=True):
    """Run an instant query.

    strict=False returns None instead of raising, for callers auditing many
    generated queries where one bad token must not abort the whole check.
    """
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        # The lab CA is not in every trust store this might run from, and this
        # is a LAN-only endpoint with no auth — verification is not the control
        # protecting it. Read-only GET.
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(url, timeout=20, context=ctx) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        # 400 is Prometheus rejecting THIS query, not an outage — do not let it
        # masquerade as "Prometheus unreachable".
        if e.code == 400 and not strict:
            return None
        if e.code == 400:
            raise CheckError(f"query rejected ({query[:60]}): {e}")
        raise CheckError(f"Prometheus error at {PROM}: {e}")
    except Exception as e:
        if not strict:
            return None
        raise CheckError(f"Prometheus unreachable at {PROM}: {e}")
    if body.get("status") != "success":
        if not strict:
            return None
        raise CheckError(f"query failed: {body.get('error')}")
    return body["data"]["result"]


# ---------------------------------------------------------------------------
# Checks. Each returns (status, [detail lines]).
# ---------------------------------------------------------------------------

def _deliberate_collectors():
    """Collectors someone explicitly turned on via extraArgs in gitops.

    Derived from the repo rather than hard-coded so this stays true as the Helm
    values change. Only these are load-bearing: node_exporter enables a large
    default set, and most of them fail on any given box simply because it has no
    ZFS pool / InfiniBand HCA / tape drive. Those failures are noise.
    """
    path = pathlib.Path(__file__).resolve().parent.parent / "gitops/apps/monitoring.yaml"
    try:
        text = path.read_text()
    except OSError:
        return {"systemd"}
    found = set(re.findall(r'--collector\.([a-z_]+)(?:\s|$|=)', text))
    # Sub-flags like --collector.systemd.unit-include describe an already-named
    # collector; the bare name is what matters.
    return {c for c in found if c} or {"systemd"}


def check_collectors():
    """Deliberately-enabled node_exporter collectors that fail every scrape.

    Scoped to collectors chosen in gitops, NOT every collector reporting zero.
    node_exporter enables dozens by default and most fail on hardware that
    doesn't have the relevant subsystem — flagging those produces ~160 lines of
    normal and buries the signal.

    The signal in question: --collector.systemd was enabled cluster-wide and
    returned success:0 on every node, so three backup alert rules could never
    fire while looking perfectly healthy in git.
    """
    wanted = _deliberate_collectors()
    rows = promql('node_scrape_collector_success == 0')
    bad = [r for r in rows if r["metric"].get("collector") in wanted]
    noisy = len(rows) - len(bad)
    if not bad:
        return PASS, [f"deliberate collectors ({', '.join(sorted(wanted))}) all healthy",
                      f"({noisy} default collectors failing on absent hardware — ignored)"]
    out = [f"deliberately enabled but failing: {', '.join(sorted(wanted))}"]
    out += [f"  {r['metric'].get('instance','?'):24} collector={r['metric'].get('collector','?')}"
            for r in bad]
    out.append(f"({noisy} default-collector failures ignored as hardware-absent)")
    return FAIL, out


# PromQL aggregation/function keywords that appear without a following '(' —
# `count by (x) (...)`, `sum without (y) (...)`, `topk`, and friends.
_PROMQL_WORDS = {
    "by", "on", "and", "or", "unless", "group_left", "group_right", "offset",
    "bool", "ignoring", "without", "if", "for", "le", "inf", "nan", "count",
    "sum", "min", "max", "avg", "topk", "bottomk", "stddev", "stdvar",
    "quantile", "count_values", "group", "absent", "atan2", "start", "end",
}


def _metric_names(expr):
    """Extract metric names from a PromQL expression.

    Not a real parser, but the ordering matters: comments, then quoted strings,
    then label matchers are removed BEFORE identifiers are read. Skipping any of
    those steps yields label values ("Ready"), label names ("severity") and
    words from URLs inside comments ("robustperception") — all of which look
    exactly like missing metrics and drown the genuine findings.
    """
    expr = re.sub(r'#[^\n]*', ' ', expr)                  # comments
    expr = re.sub(r'"[^"]*"|\'[^\']*\'', ' ', expr)       # string literals
    expr = re.sub(r'[a-zA-Z_][a-zA-Z0-9_]*\s*(=~|!~|=|!=)', ' ', expr)  # label matchers
    # Grouping clauses name LABELS, not metrics. Added 2026-08-07 after
    # LabBackupJobFailed's `and on(namespace, job_name)` produced
    # "ABSENT: job_name — every rule referencing it cannot fire". job_name carries
    # an underscore and is not followed by '(', so it passed every other filter.
    # A false positive is expensive here: it fails the whole check and buries the
    # genuine finding underneath it.
    expr = re.sub(r'\b(on|ignoring|by|without|group_left|group_right)\s*\([^)]*\)',
                  ' ', expr)
    out = set()
    for tok in re.findall(r'\b([a-zA-Z_:][a-zA-Z0-9_:]*)\b(?!\s*\()', expr):
        if tok in _PROMQL_WORDS:
            continue
        # Real Prometheus metric names essentially always carry a '_' or ':'.
        # `up` is the one bare exception in normal use.
        if "_" in tok or ":" in tok or tok == "up":
            out.add(tok)
    return out


def check_alert_metrics():
    """Every metric referenced by a PrometheusRule must exist in Prometheus.

    An alert whose metric has zero series is not 'quiet' — it is incapable of
    firing, and looks identical to healthy on every dashboard. This is the check
    that would have caught LabBackupNasSilent, LabBackupEtcdSilent,
    LabBackupNasFailed and (before it was retargeted) LabVMUnexpectedShutoff.
    """
    rules = kubectl_json("get", "prometheusrules", "-A")
    names, audited, skipped = set(), [], 0
    for item in rules.get("items", []):
        labels = item["metadata"].get("labels", {})
        # Audit only rules WE wrote. The vendored kube-prometheus-stack rules
        # reference metrics for environments this lab doesn't have — HPAs,
        # remote-write, cloud providers — so auditing them yields pure noise and
        # trains you to ignore the output. Ours are the ones that can be wrong
        # in a way that matters.
        if labels.get("app.kubernetes.io/managed-by") == "Helm" or "chart" in labels:
            skipped += 1
            continue
        audited.append(item["metadata"]["name"])
        for group in item["spec"].get("groups", []):
            for rule in group.get("rules", []):
                names |= _metric_names(rule.get("expr", ""))

    # Prove Prometheus answers at all before interpreting any empty result as
    # "metric absent" — otherwise an outage reads as every alert being broken.
    if promql("vector(1)") is None:
        raise CheckError("Prometheus did not answer a trivial query")

    missing, excused, healthy_absent, unparsed = [], [], [], []
    for name in sorted(names):
        res = promql(f'count({name})', strict=False)
        if res is None:
            # Our token extraction produced something PromQL won't accept —
            # a label value or keyword, not a metric. Report it so the regex
            # can be tightened; never silently skip.
            unparsed.append(name)
        elif res:
            continue
        elif name in ABSENT_WHEN_HEALTHY:
            healthy_absent.append(name)
        else:
            (excused if name in KNOWN_ABSENT else missing).append(name)

    detail = [f"{len(names)} metrics referenced by {len(audited)} own rule set(s): "
              f"{', '.join(audited)}",
              f"({skipped} Helm-managed rule sets skipped — upstream rules target "
              f"environments this lab does not have)"]
    for n in excused:
        detail.append(f"  known-absent (documented): {n}")
    for n in healthy_absent:
        detail.append(f"  absent because healthy: {n} — "
                      f"{ABSENT_WHEN_HEALTHY[n].split('.')[0]}")
    if unparsed:
        detail.append(f"  not valid metric names, ignored: {', '.join(unparsed[:12])}")
    if not missing:
        return PASS, detail
    for n in missing:
        detail.append(f"  ABSENT: {n} — every rule referencing it cannot fire")
    return FAIL, detail


def check_targets():
    """Scrape targets that are down.

    Five hosts sat unscraped for weeks because they were added to
    additionalScrapeConfigs without node_exporter ever being installed.
    """
    rows = promql('up == 0')
    if not rows:
        return PASS, ["all scrape targets up"]
    return FAIL, [f"{r['metric'].get('job','?'):26} {r['metric'].get('instance','?')}"
                  for r in rows]


def check_pdb():
    """PodDisruptionBudgets that permit zero disruptions.

    minAvailable: 1 against replicas: 1 is not protection — it makes the pod
    permanently un-evictable, so `kubectl drain` can only ever time out. This
    failed the patch playbook on 2026-07-27; it had been written up as H7 in
    docs/REVIEW-2026-07-24.md three days earlier.
    """
    pdbs = kubectl_json("get", "pdb", "-A")
    bad = []
    for p in pdbs.get("items", []):
        allowed = p.get("status", {}).get("disruptionsAllowed", 0)
        if allowed < 1:
            bad.append(f"{p['metadata']['namespace']}/{p['metadata']['name']:28} "
                       f"disruptionsAllowed={allowed} — blocks drain")
    return (PASS, [f"{len(pdbs.get('items', []))} PDBs, all permit a disruption"]) \
        if not bad else (FAIL, bad)


def check_argo():
    """Applications not Synced+Healthy — i.e. git and the cluster disagree."""
    apps = kubectl_json("get", "applications", "-n", "argocd")
    bad, transient = [], []
    for a in apps.get("items", []):
        st = a.get("status", {})
        sync = st.get("sync", {}).get("status")
        health = st.get("health", {}).get("status")
        line = f"{a['metadata']['name']:24} sync={sync} health={health}"
        if sync != "Synced" or health in ("Degraded", "Missing", "Unknown"):
            bad.append(line)
        elif health == "Progressing":
            # A rollout in flight is normal, not a fault. Reported, not failed —
            # a check that fails during every deploy gets ignored during the one
            # deploy that actually broke something. `pods` catches a stuck roll.
            transient.append(line + "  (rollout in progress)")
    detail = transient or [f"{len(apps.get('items', []))} Applications Synced+Healthy"]
    return (PASS, detail) if not bad else (FAIL, bad + transient)


def check_dns():
    """CLAUDE.md calls DNS load-bearing; nothing verified it until now.

    api.lab.home.arpa must resolve to the kube-vip VIP and *.apps to Traefik.
    Checked against every resolver in resolv.conf, because a secondary serving
    stale records is the failure that presents as 'the cluster is down'.
    """
    if not shutil.which("dig"):
        raise CheckError("dig not installed (apt install dnsutils)")
    expected = {"api.lab.home.arpa": API_VIP,
                "grafana.apps.lab.home.arpa": INGRESS_VIP}
    servers = re.findall(r'^nameserver\s+(\S+)', open("/etc/resolv.conf").read(), re.M)
    if not servers:
        raise CheckError("no nameservers in /etc/resolv.conf")
    bad, checked = [], 0
    for host, want in expected.items():
        for srv in servers:
            got = sh("dig", "+short", "+time=3", "+tries=1", f"@{srv}", host).split()
            checked += 1
            if want not in got:
                bad.append(f"{host} via {srv} → {got or ['NXDOMAIN']} (want {want})")
    return (PASS, [f"{checked} resolver/name pairs correct"]) if not bad else (FAIL, bad)


def check_pods():
    """Pods stuck Pending, and terminal pods piling up.

    130 Failed Grafana pods accumulated on one node before anyone noticed the
    dashboards had been intermittently down for weeks. The kubelet's GC
    threshold is 12500, so nothing cleans these up on a lab-sized cluster.
    """
    pods = kubectl_json("get", "pods", "-A")
    pending, terminal = [], 0
    for p in pods.get("items", []):
        phase = p.get("status", {}).get("phase")
        if phase == "Pending":
            pending.append(f"{p['metadata']['namespace']}/{p['metadata']['name']}")
        elif phase in ("Failed", "Succeeded"):
            terminal += 1
    detail, status = [], PASS
    if pending:
        status = FAIL
        detail += [f"Pending: {p}" for p in pending[:10]]
    if terminal > 25:
        status = FAIL
        detail.append(f"{terminal} terminal pod objects — likely repeated evictions; "
                      f"investigate before deleting, they are the evidence")
    return status, detail or ["no Pending pods, terminal pod count normal"]


CHECKS = {
    "collectors":    check_collectors,
    "alert-metrics": check_alert_metrics,
    "targets":       check_targets,
    "pdb":           check_pdb,
    "argo":          check_argo,
    "dns":           check_dns,
    "pods":          check_pods,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", nargs="+", choices=list(CHECKS), metavar="NAME")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if args.list:
        for name, fn in CHECKS.items():
            print(f"\n{name}\n  " + (fn.__doc__ or "").strip().replace("\n    ", "\n  "))
        return 0

    selected = args.check or list(CHECKS)
    results, worst = {}, 0

    for name in selected:
        try:
            status, detail = CHECKS[name]()
        except CheckError as e:
            status, detail = ERROR, [str(e)]
        except Exception as e:                      # noqa: BLE001
            status, detail = ERROR, [f"{type(e).__name__}: {e}"]
        results[name] = {"status": status, "detail": detail}
        worst = max(worst, {PASS: 0, FAIL: 1, ERROR: 2}[status])

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for name, r in results.items():
            mark = {PASS: "ok  ", FAIL: "FAIL", ERROR: "ERR "}[r["status"]]
            print(f"[{mark}] {name}")
            for line in r["detail"]:
                print(f"         {line}")
        failed = [n for n, r in results.items() if r["status"] == FAIL]
        errored = [n for n, r in results.items() if r["status"] == ERROR]
        print()
        if errored:
            print(f"COULD NOT CHECK: {', '.join(errored)} — treat as unknown, not healthy")
        print(f"FAILED: {', '.join(failed)}" if failed else "All checks passed.")

    return worst


if __name__ == "__main__":
    sys.exit(main())

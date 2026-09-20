#!/usr/bin/env python3
"""Catch ApplicationSet name collisions before Argo does.

WHY THIS EXISTS
---------------
gitops/apps/workloads-appset.yaml generates one Argo Application per directory under
gitops/workloads/, named `{{path.basename}}`. Several directories must be excluded because
an Application of that name is already declared by hand in gitops/apps/ — cert-manager,
kyverno and monitoring are all Helm charts whose Application would otherwise be duplicated.

When a directory is added without the matching exclusion, TWO Applications claim one name
and Argo lets them fight. On 2026-08-21 `gitops/workloads/external-secrets/` was created
without the exclusion. The generated Application won, pointed at a directory holding three
RBAC objects, and — carrying `prune: true` — deleted the entire external-secrets Helm
release. The operator was gone for roughly twenty minutes. Nothing broke immediately,
because the ExternalSecret CRs and their target Secrets survived, so every dashboard stayed
green while nothing was reconciling.

That is the failure this script exists to make impossible: silent until destructive, and
detectable offline in milliseconds.

WHAT IT CHECKS
--------------
1. COLLISION — a directory under gitops/workloads/ whose basename matches an Application
   name declared in gitops/apps/, and which is not excluded from the generator. This is the
   destructive case.

2. ORPHAN — a directory that IS excluded but has no Application in gitops/apps/ pointing at
   it. The exclusion stops the generator, and nothing replaces it, so those manifests are
   silently never deployed. Less dangerous, equally invisible.

Usage:  python3 scripts/check-appset-collisions.py [repo-root]
Exit 0 clean, 1 on any finding.
"""
import sys
import pathlib

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
apps_dir = root / "gitops" / "apps"
workloads_dir = root / "gitops" / "workloads"
appset_file = apps_dir / "workloads-appset.yaml"

for p in (apps_dir, workloads_dir, appset_file):
    if not p.exists():
        sys.exit(f"FATAL: {p} not found — run from the repo root or pass it as an argument")


def docs(path):
    """Every YAML document in a file, skipping empties and non-mappings."""
    try:
        with path.open(encoding="utf-8") as fh:
            for d in yaml.safe_load_all(fh):
                if isinstance(d, dict):
                    yield d
    except yaml.YAMLError as exc:
        sys.exit(f"FATAL: {path} is not valid YAML: {exc}")


# --- Applications declared by hand, and what each points at ------------------
#
# An Application may use `source:` (single) OR `sources:` (multi-source). Both must be
# read: gitops/apps/gitlab-runner.yaml combines a Helm chart with a git overlay under
# `sources:`, and a first version of this script that only understood `source:` reported it
# as an orphan — a false positive on the very first run. A check that cries wolf gets
# switched off, which is worse than not having one.
declared = {}          # name -> (file, [paths and charts it references])
for f in sorted(apps_dir.glob("*.yaml")):
    for d in docs(f):
        if d.get("kind") != "Application":
            continue
        name = (d.get("metadata") or {}).get("name")
        if not name:
            continue
        spec = d.get("spec") or {}
        srcs = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
        refs = [s.get("path") or f"chart:{s.get('chart')}" for s in srcs if isinstance(s, dict)]
        declared[name] = (f.name, refs)

# --- Directories the generator is told to skip -------------------------------
excluded = set()
for d in docs(appset_file):
    for gen in (d.get("spec") or {}).get("generators") or []:
        for entry in (gen.get("git") or {}).get("directories") or []:
            if entry.get("exclude"):
                excluded.add(pathlib.PurePosixPath(entry["path"]).name)

# --- Compare ------------------------------------------------------------------
collisions, orphans = [], []
for d in sorted(p for p in workloads_dir.iterdir() if p.is_dir()):
    name = d.name
    if name in declared and name not in excluded:
        collisions.append((name, declared[name]))
    elif name in excluded:
        # Excluded is only safe if something else deploys the directory — via either a
        # single `source:` or any entry in a multi-source `sources:` list.
        target = f"gitops/workloads/{name}"
        if not any(target in refs for _, refs in declared.values()):
            orphans.append(name)

if collisions:
    print("COLLISION — a generated Application would share a name with a declared one:\n")
    for name, (f, refs) in collisions:
        print(f"  gitops/workloads/{name}/")
        print(f"    collides with Application '{name}' in gitops/apps/{f} -> {', '.join(refs) or '(no source)'}")
        print(f"    FIX: exclude gitops/workloads/{name} in workloads-appset.yaml, and")
        print(f"         declare a distinctly-named Application for the directory.\n")
    print("  Two Applications with one name fight, and the winner prunes the loser's")
    print("  resources. See scripts/check-appset-collisions.py for what that cost once.\n")

if orphans:
    print("ORPHAN — excluded from the generator, but nothing deploys it:\n")
    for name in orphans:
        print(f"  gitops/workloads/{name}/  — no Application in gitops/apps/ has")
        print(f"    source.path: gitops/workloads/{name}")
    print("\n  These manifests are in git and are not in the cluster. That is a silent")
    print("  no-op, not a safe exclusion.\n")

if collisions or orphans:
    sys.exit(1)

print(f"OK — {len(list(p for p in workloads_dir.iterdir() if p.is_dir()))} workload "
      f"directories, {len(declared)} declared Applications, no collisions or orphans.")

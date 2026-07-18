# Architecture

This lab has one always-on **core** (the H4 Ultra) carrying the cluster and storage, a
small set of **support roles** (DNS, edge AI, identity), and an optional **ARM expansion
fleet**. Everything that runs inside the cluster is declared in git and reconciled by Argo CD.

![Topology](diagrams/architecture.svg)

## The three layers

| Layer | Tool | Owns | Blast radius |
|-------|------|------|--------------|
| Host | **Ansible** | OS config, storage (LVM/RAID), k3s install, backups | Whole box — gate hardest |
| Cluster | **Argo CD** | Namespaces, workloads, Ingress, config inside k3s | Recoverable from git |
| VMs | **KVM / libvirt** | gitlab-1 and other services on n150-1/n150-2 hypervisors (lldap moved to k3s) | Per-VM |

Ansible runs rarely (setup and changes you approve). Argo runs continuously. Claude lives
mostly in the git/Argo layer.

## k3s cluster — 3-node HA control plane

k3s is Rancher's lightweight, single-binary Kubernetes distribution. It brings a minimal
control plane (containerd, Flannel CNI, embedded etcd), **Traefik** as the default ingress
controller, and the **local-path** StorageClass for dynamic persistent volumes — but drops
the heavy parts of full Kubernetes.

The control plane runs across **three server nodes** with embedded etcd, providing quorum
and tolerating one server failure without cluster downtime:

| Node | IP | Hardware |
|------|----|---------|
| `odroid-nas` | `192.168.1.160` | H4 Ultra — also runs NAS (`smbd`/`nfs`) |
| `n150-1` | `192.168.1.42` | N150 mini PC — also KVM hypervisor |
| `n150-2` | `192.168.1.21` | N150 mini PC — also KVM hypervisor |

**kube-vip** runs as a DaemonSet on all three server nodes and advertises a floating VIP at
`192.168.1.200` via ARP. All k3s traffic (internal + `kubectl`) targets the VIP; if any
one server goes down, the VIP moves to another server within seconds.

The API endpoint is `https://api.lab.home.arpa:6443` (DNS: `api.lab.home.arpa → 192.168.1.200`).
The VIP's SAN is in the k3s TLS certificate.

The base domain is `lab.home.arpa` (RFC 8375 reserved for home networks), so an Ingress
named `web` resolves as `web.apps.lab.home.arpa`.

**opi5pro-1/2** run as k3s agents — ARM64 inference compute. Target with
`nodeSelector: kubernetes.io/arch: arm64`.

## GitOps reconcile loop

The cluster's desired state is this repo. Argo's `app-of-apps` root watches `gitops/apps/`.
Most workloads are managed by a **git-directory ApplicationSet** (`workloads-appset.yaml`)
that auto-creates an Application for every directory under `gitops/workloads/` where the
directory name equals the target namespace. Adding a new standard workload requires only
a new `gitops/workloads/<name>/` directory — no `gitops/apps/` entry needed.
Special cases (namespace ≠ dirname, Helm sources, infrastructure apps) keep individual
Application files in `gitops/apps/`. With `selfHeal` and `prune` on, the live cluster is
continuously forced to match git.

```mermaid
flowchart LR
    C[Claude / you] -->|edit + PR| G[(git: main)]
    G -->|watched by| R[Argo: root app-of-apps]
    R --> AS[ApplicationSet: workloads<br/>git directory generator]
    R --> A1[App: ai-backends]
    R --> A2[App: kyverno / monitoring / ...]
    AS -->|one App per dir| W[App: authelia · immich · semaphore · ...]
    A1 & A2 & W -->|sync| K[k3s cluster]
    K -->|drift detected| H{selfHeal}
    H -->|revert to git| K
    classDef g fill:#15111f,stroke:#a78bfa,color:#e6edf3;
    classDef k fill:#1a1113,stroke:#ff4d4d,color:#e6edf3;
    class G,R,AS,A1,A2,W g;
    class K,H k;
```

The practical upshot: there is almost no imperative `kubectl apply` in normal operation. To
change the cluster you change git; to undo a change you `git revert`. This is also what
makes letting an agent near the cluster safe — its changes are diffs you review, and
anything it does out of band gets reconciled away.

## Bootstrap order

Stages are independent playbooks so you can run and verify them one at a time. Storage must
exist before k3s starts (etcd and PVs need the NVMe); Argo comes last.

```mermaid
flowchart TD
    S[storage.yml<br/>RAID assemble · LVM tiers] --> K[k3s.yml<br/>install · config · firewalld]
    K --> B[backup.yml<br/>restic + etcd timers]
    K --> A[argocd.yml<br/>install Argo · apply root]
    A --> W[Argo syncs gitops/apps → workloads]
    classDef a fill:#161b22,stroke:#2b3440,color:#e6edf3;
    class S,K,B,A,W a;
```

## Storage tiers

![Storage tiers](diagrams/storage-tiers.svg)

A single fast NVMe holds everything latency-sensitive; two SATA disks hold cold copies;
git holds desired state. Cold storage is two mdadm RAID 1 mirrors — 8 TB primary
(`/mnt/cold-8t`) + ~5.45 TB secondary (`/mnt/cold-sec`); each survives a disk failure.
Because the NVMe is fast (high random IOPS), co-locating etcd with NAS I/O is fine — the
classic "etcd hates shared storage" warning applies to slow spinning disks, not NVMe.
The real risks are space contention (handled by LVM separation) and the box being a single
failure domain (handled by two independent cold copies plus git).

```mermaid
flowchart LR
    subgraph HOT[Hot · NVMe 4TB]
      OS[OS/root]; ETCD[etcd]; NAS[live NAS]; PV[k8s PVs via local-path]
    end
    subgraph COLD[Cold · md1 8TB + md0 ~5.45TB]
      RES[md1 restic primary + Immich library]; CP[md0 restic copy]; ARC[archive]
    end
    RES -->|copy| CP
    GIT[(Off-box: git)]
    NAS -->|restic daily| RES
    ETCD -->|weekly snapshot| RES
    HOT -.full loss.-> REC{recover}
    COLD -->|state| REC
    GIT -->|config via Argo| REC
    classDef h fill:#1f1605,stroke:#f59e0b,color:#e6edf3;
    classDef c fill:#0c1a2e,stroke:#3b82f6,color:#e6edf3;
    class OS,ETCD,NAS,PV h;
    class RES,CP,ARC c;
```

## Network & DNS

The lab is a flat **192.168.1.0/24** network. **DNS is the linchpin of the install** —
k3s needs `api.lab.home.arpa → 192.168.1.200` (kube-vip VIP) and
`*.apps.lab.home.arpa → 192.168.1.160` (H4 Traefik ingress).

Three DNS servers provide redundancy:

| Role | Host | IP | Engine |
|------|------|----|--------|
| Primary | RPi 3B #2 (octopi) | `192.168.1.148` | Pi-hole (Bookworm pending) |
| Secondary | RPi 4B | `192.168.1.116` | Pi-hole v6 |
| Tertiary | OPi Zero 2W #1 | `192.168.1.184` | dnsmasq (fallback) |

Inside the cluster, CoreDNS has a custom zone (`coredns-custom` ConfigMap in kube-system)
that answers all `*.apps.lab.home.arpa` queries with `192.168.1.160`, ensuring pods on any
node resolve Ingress names without relying on the host's `systemd-resolved`.

## Identity & SSO

**lldap** runs as a k3s Deployment in the `lldap` namespace (`lldap.apps.lab.home.arpa`,
LDAP port 3890 via ClusterIP service). It is the LDAP directory — a lightweight
read-optimised server with a web UI at port 17170. It holds lab users and groups.
SQLite data is on a `local-path` PVC; secrets come from Vault via ExternalSecret.
The previous `ldap-1` KVM VM on n150-1 (`192.168.1.70`) has been decommissioned.

**Authelia** runs in k3s (`authelia.apps.lab.home.arpa`) as an OIDC provider backed by
lldap. It gates SSO for apps that support OIDC but not LDAP directly (Immich). The OIDC
private key and all secrets live in the `authelia-secrets` k8s Secret, ESO-managed
via Vault (`gitops/workloads/authelia/external-secret.yaml`).

**cert-manager** (`lab-ca` ClusterIssuer) signs TLS certs for all `*.apps.lab.home.arpa`
Ingresses using a self-signed lab root CA stored in the `lab-root-ca` secret.

## Where the rest of the fleet fits

The H4 is the only box that can carry a real control plane plus storage, so it stays the
core. The other hardware has defined supporting roles:

- **n150-1 / n150-2** (`192.168.1.42` / `192.168.1.21`) — dual role: k3s server nodes
  (embedded etcd quorum) + KVM hypervisors (Ubuntu 24.04). `ldap-1` VM decommissioned;
  lldap now runs in the cluster.
- **Orange Pi 5 Pro ×2 (8C/16 GB/NPU)** — k3s agents; opi5pro-1/2 run Ollama inference.
- **RPi 5** (`192.168.1.128`) — HashiCorp Vault.
- **RPi 4B** (`192.168.1.116`) — DNS secondary (Pi-hole v6, Debian Bookworm).
- **octopi (RPi 3B #2)** (`192.168.1.148`) — DNS primary (Pi-hole, Bookworm flash pending).
- **OPi Zero 2W #1** (`192.168.1.184`) — DNS tertiary / fallback (dnsmasq).
- **opi-zero2w-2** (`192.168.1.188`) — MQTT primary broker (Mosquitto); bridges all topics
  to opi-zero2w-4 for HA.
- **opi-zero2w-4** (`192.168.1.99`) — MQTT secondary broker (Mosquitto); bridges all topics
  to opi-zero2w-2. M5Stack fails over here automatically if the primary is unreachable.
- **xu3-1** (`192.168.1.64`) — build agent.
- **M5Stack + OPi NPUs** — edge inference endpoints, not cluster nodes.

## Security posture (summary)

The box is the blast-radius boundary: scoped credentials, no `root`-equivalents for
cluster operations, and a permission config (`.claude/settings.json`) that allows reads,
asks before mutations, and denies destructive storage operations outright. Secrets never
committed to git; OIDC/Authelia secrets created out-of-band. Full model in
[SECURITY.md](SECURITY.md).

## Service map

Grouped services and the hosts that provide them:

![Service map](diagrams/service-map.svg)

An **interactive, filterable** version (toggle hardware classes, select-all/clear) is at
[service-map.html](service-map.html) — open it in a browser. A **host-centric** companion
(one card per box, everything it runs, same filters) is at [host-map.html](host-map.html).

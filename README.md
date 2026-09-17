# DevOps Assignment 2

**Name:** Manasvi Sabbarwal
**Roll No:** 24BCS10406

Homework for the DevOps course. Each topic gets its own folder with a
`README.md` holding the commands I ran, the real output from my terminal, and
what I understood from it. Manifests live in `manifests/`, terminal captures in
`screenshots/`.

Nothing in these READMEs is invented output. Each folder has a script that runs
every check and writes the raw result to `output.log`, and the README quotes
that file.

## Submissions

| # | Topic | Session | README |
|---|---|---|---|
| 1 | Kubernetes Services (ClusterIP) | Session 11 | [01_K8s_Services/README.md](01_K8s_Services/README.md) |

## Environment

- macOS 26.5.1 (Apple Silicon) with Docker Desktop, Docker Engine 29.1.3
- Kubernetes: local 3-node cluster created with [kind](https://kind.sigs.k8s.io/)
  v0.33.0, config in [`cluster/kind-cluster.yaml`](cluster/kind-cluster.yaml)
- Cluster version: v1.37.0 (1 control-plane, 2 workers)
- kubectl: v1.37.0
- Class repository used for the labs: <https://github.com/Nency-Ravaliya/devops-heros>

Bringing the cluster up:

```bash
kind create cluster --name svc-lab --config cluster/kind-cluster.yaml
kubectl get nodes -o wide
```

```text
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
svc-lab-control-plane   Ready    control-plane   46s   v1.37.0   172.22.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.12.54-linuxkit (arm64)   containerd://2.3.4
svc-lab-worker          Ready    <none>          32s   v1.37.0   172.22.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.12.54-linuxkit (arm64)   containerd://2.3.4
svc-lab-worker2         Ready    <none>          32s   v1.37.0   172.22.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.12.54-linuxkit (arm64)   containerd://2.3.4
```

Two workers on purpose, so pods behind a service land on different nodes and the
traffic actually crosses a node boundary instead of staying local.

## Repo conventions

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
The rules are in [CLAUDE.md](CLAUDE.md) and enforced by the hook in
[.githooks/commit-msg](.githooks/commit-msg):

```bash
git config core.hooksPath .githooks
```

The hook rejects a commit whose subject is not `<type>(<scope>): <subject>`, and
it also rejects any attribution trailer in the message body.

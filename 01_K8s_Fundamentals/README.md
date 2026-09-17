# Kubernetes Fundamentals

**Name:** Manasvi Sabbarwal
**Roll No:** 24BCS10406
**Cluster:** kind v0.33.0, 3 nodes (1 control-plane + 2 workers), Kubernetes v1.37.0

Architecture, the control plane, and what a pod actually is. Every output block
below is quoted from [`output.log`](output.log), written by
[`verify.sh`](verify.sh) against a live cluster.

---

## 1. The cluster

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

```text
$ kubectl cluster-info
Kubernetes control plane is running at https://127.0.0.1:63179
CoreDNS is running at https://127.0.0.1:63179/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

$ kubectl get nodes -o wide
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
svc-lab-control-plane   Ready    control-plane   15m   v1.37.0   172.22.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.12.54-linuxkit (arm64)   containerd://2.3.4
svc-lab-worker          Ready    <none>          15m   v1.37.0   172.22.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.12.54-linuxkit (arm64)   containerd://2.3.4
svc-lab-worker2         Ready    <none>          15m   v1.37.0   172.22.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.12.54-linuxkit (arm64)   containerd://2.3.4
```

The API server is on `127.0.0.1:63179` because kind runs the nodes as Docker
containers on this Mac and maps the API port out to localhost. The nodes
themselves are on `172.22.0.0/16`, which is the Docker bridge network, not
anything on my home LAN.

`ROLES` is just a label. `node-role.kubernetes.io/control-plane` on that node is
what makes kubectl print `control-plane`, and it is also what the default taint
keys off so ordinary pods do not get scheduled there.

---

## 2. The control plane is made of pods

The thing that surprised me most: the control plane is not a daemon installed on
the host. It is containers, running on the cluster, visible to `kubectl`.

```bash
kubectl -n kube-system get pods -o wide --sort-by=.spec.nodeName
```

```text
NAME                                            READY   STATUS    RESTARTS   AGE   IP           NODE                    NOMINATED NODE   READINESS GATES
coredns-559f6c778d-4llch                        1/1     Running   0          15m   10.244.0.4   svc-lab-control-plane   <none>           <none>
coredns-559f6c778d-cr56z                        1/1     Running   0          15m   10.244.0.2   svc-lab-control-plane   <none>           <none>
etcd-svc-lab-control-plane                      1/1     Running   0          15m   172.22.0.2   svc-lab-control-plane   <none>           <none>
kindnet-s45m9                                   1/1     Running   0          15m   172.22.0.2   svc-lab-control-plane   <none>           <none>
kube-apiserver-svc-lab-control-plane            1/1     Running   0          15m   172.22.0.2   svc-lab-control-plane   <none>           <none>
kube-controller-manager-svc-lab-control-plane   1/1     Running   0          15m   172.22.0.2   svc-lab-control-plane   <none>           <none>
kube-proxy-vlz77                                1/1     Running   0          15m   172.22.0.2   svc-lab-control-plane   <none>           <none>
kube-scheduler-svc-lab-control-plane            1/1     Running   0          15m   172.22.0.2   svc-lab-control-plane   <none>           <none>
kindnet-x6phb                                   1/1     Running   0          15m   172.22.0.4   svc-lab-worker          <none>           <none>
kube-proxy-vnzhj                                1/1     Running   0          15m   172.22.0.4   svc-lab-worker          <none>           <none>
kindnet-vmznc                                   1/1     Running   0          15m   172.22.0.3   svc-lab-worker2         <none>           <none>
kube-proxy-kddsq                                1/1     Running   0          15m   172.22.0.3   svc-lab-worker2         <none>           <none>
```

Reading this by IP column tells you a lot:

- `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` all have
  IP `172.22.0.2`, the **node's own IP**, not a pod IP. They run with
  `hostNetwork: true`. They have to: the API server cannot depend on the pod
  network, because the pod network is configured by things that talk to the API
  server. It would be a chicken and egg problem.
- The two CoreDNS pods have real pod IPs (`10.244.0.x`). CoreDNS is a normal
  workload, it just happens to ship with the cluster.
- `kube-proxy` and `kindnet` appear once per node. Those are DaemonSets. Every
  node needs its own copy because each one programs that node's iptables rules
  and its CNI.

| Component | Job | Where it runs |
|---|---|---|
| `kube-apiserver` | The only thing that talks to etcd. Every read and write goes through it | control-plane, host network |
| `etcd` | The database. The entire cluster state is here and nowhere else | control-plane, host network |
| `kube-scheduler` | Watches for pods with no `nodeName` and picks a node | control-plane, host network |
| `kube-controller-manager` | Runs the control loops (deployment, replicaset, endpoints and so on) | control-plane, host network |
| `kubelet` | Talks to the container runtime, keeps the node's pods alive | every node, as a host process, not a pod |
| `kube-proxy` | Writes the service iptables rules | every node, DaemonSet |
| CNI (`kindnet` here) | Gives pods IPs and routes between nodes | every node, DaemonSet |

`kubelet` is the one exception. It is not a pod, because something has to exist
before pods can be started. In kind it is a systemd service inside the node
container.

---

## 3. Static pods: who owns the control plane

If the control plane runs as pods, and pods are created by the API server, what
creates the API server pod? Answer: nothing does. The kubelet reads them off
disk.

```bash
docker exec svc-lab-control-plane ls -1 /etc/kubernetes/manifests/
kubectl -n kube-system get pod kube-apiserver-svc-lab-control-plane -o jsonpath='{.metadata.ownerReferences[0].kind}'
```

```text
$ docker exec svc-lab-control-plane ls -1 /etc/kubernetes/manifests/
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml

$ kubectl -n kube-system get pod kube-apiserver-svc-lab-control-plane -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
Node
```

```text
$ kubectl -n kube-system get pods -l tier=control-plane -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,OWNER:.metadata.ownerReferences[0].kind
NAME                                            NODE                    OWNER
etcd-svc-lab-control-plane                      svc-lab-control-plane   Node
kube-apiserver-svc-lab-control-plane            svc-lab-control-plane   Node
kube-controller-manager-svc-lab-control-plane   svc-lab-control-plane   Node
kube-scheduler-svc-lab-control-plane            svc-lab-control-plane   Node
```

The owner is `Node`, not a ReplicaSet or a DaemonSet. These are **static pods**:
the kubelet watches `/etc/kubernetes/manifests/` and runs whatever YAML is in
there, entirely on its own. It then reports a read-only mirror of them to the
API server so they show up in `kubectl get pods`.

Two consequences worth remembering:

- The bootstrap order makes sense now. kubelet starts, reads the directory,
  starts etcd and the API server. Only then does a cluster exist.
- Deleting a static pod with `kubectl delete` does nothing useful. The mirror
  disappears and the kubelet immediately recreates it, because the file on disk
  is the real source. To actually stop one you move the file.

The pod name pattern `<component>-<nodename>` is also a giveaway: static pods get
the node name appended so two nodes running the same static pod do not collide.

---

## 4. Namespaces

```text
$ kubectl get namespaces
NAME                 STATUS   AGE
default              Active   15m
kube-node-lease      Active   15m
kube-public          Active   15m
kube-system          Active   15m
local-path-storage   Active   15m
svc-lab              Active   14m
```

| Namespace | What it is for |
|---|---|
| `default` | Where your objects go if you do not say otherwise |
| `kube-system` | Everything the cluster itself runs |
| `kube-public` | World readable, holds cluster info for bootstrapping |
| `kube-node-lease` | One Lease object per node, the heartbeat used for node health |
| `local-path-storage` | kind's default storage provisioner |
| `svc-lab` | Mine, from the services lab in [`../03_K8s_Networking_Services`](../03_K8s_Networking_Services) |

`kube-node-lease` is worth knowing about. Node heartbeats used to be status
updates on the Node object itself, which was expensive because every heartbeat
rewrote a large object. Leases are tiny objects updated instead, so a 5000 node
cluster does not melt etcd.

Namespaces scope **names**, not security and not networking. Two services can
both be called `backend` in different namespaces, but by default a pod in one
namespace can still reach a pod in another. Stopping that needs NetworkPolicy.

---

## 5. A first pod

```bash
kubectl apply -f manifests/01-first-pod.yaml
kubectl -n k8s-basics get pod first-pod -o wide
```

```text
$ kubectl apply -f manifests/01-first-pod.yaml
pod/first-pod created

$ kubectl -n k8s-basics wait --for=condition=Ready pod/first-pod --timeout=120s
pod/first-pod condition met

$ kubectl -n k8s-basics get pod first-pod -o wide
NAME        READY   STATUS    RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
first-pod   1/1     Running   0          1s    10.244.1.10   svc-lab-worker   <none>           <none>
```

It landed on `svc-lab-worker`, not the control-plane, because of the
control-plane taint. The pod IP `10.244.1.10` is in `svc-lab-worker`'s slice of
the pod CIDR.

`describe` shows what the scheduler and kubelet filled in:

```text
$ kubectl -n k8s-basics describe pod first-pod | sed -n '1,25p'
Name:             first-pod
Namespace:        k8s-basics
Priority:         0
Service Account:  default
Node:             svc-lab-worker/172.22.0.4
Start Time:       Thu, 17 Sep 2026 23:20:40 +0530
Labels:           app=first-pod
Annotations:      <none>
Status:           Running
IP:               10.244.1.10
IPs:
  IP:  10.244.1.10
Containers:
  web:
    Container ID:   containerd://23ad4b996c07dd9fd257b61e10e954e3dce65d46898c41d34931a70a577afdc3
    Image:          nginxdemos/nginx-hello:plain-text
    Image ID:       docker.io/nginxdemos/nginx-hello@sha256:7444c8fe498146490bf8acaea9a0313610cfff2ab4acf16cd6555cfdf7558876
    Port:           8080/TCP (http)
    Host Port:      0/TCP (http)
    State:          Running
      Started:      Thu, 17 Sep 2026 23:20:41 +0530
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     100m
```

Note `Image` is the tag I wrote but `Image ID` is a sha256 digest. The tag is
resolved once at pull time. That is why `:latest` is unsafe: two pods created a
week apart from the same tag can be running different code.

`Host Port: 0/TCP` means the container port is not published on the node.
`containerPort` is documentation plus a name to reference. It does not open
anything by itself.

### Talking to it

```text
$ kubectl -n k8s-basics exec first-pod -- curl -s http://localhost:8080
Server address: ::1:8080
Server name: first-pod
Date: 17/Sep/2026:17:50:41 +0000
URI: /
Request ID: 4001b8a7a21f367c247102509fa8c18f

$ kubectl -n k8s-basics logs first-pod --tail=5
2026/09/17 17:50:41 [notice] 1#1: start worker process 38
2026/09/17 17:50:41 [notice] 1#1: start worker process 39
::1 - - [17/Sep/2026:17:50:41 +0000] "GET / HTTP/1.1" 200 133 "-" "curl/8.14.1" "-"
```

`Server name: first-pod` is the pod name, because the container's hostname is set
from it. And the request I made with `exec` shows up in `logs` a line later,
logged from `::1`, which is the pod talking to itself over loopback.

`kubectl logs` is just reading the container's stdout off the node. That is why
an app that writes to a log file inside the container shows nothing here.

---

## 6. A pod is the unit, not a container

Two containers in one pod, sharing an `emptyDir`:

```text
$ kubectl -n k8s-basics get pod shared-pod -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'
writer
reader

# the reader sees what the writer wrote, through the shared emptyDir:
$ kubectl -n k8s-basics exec shared-pod -c reader -- sh -c 'sleep 5; tail -3 /data/log.txt'
line 1 from the writer
line 2 from the writer
line 3 from the writer

# both containers report the same pod IP, they share one network namespace:
$ kubectl -n k8s-basics exec shared-pod -c writer -- hostname -i
10.244.2.11

$ kubectl -n k8s-basics exec shared-pod -c reader -- hostname -i
10.244.2.11
```

Two separate containers, one IP. That is the whole idea of a pod: the containers
in it share a network namespace and can share volumes, so they behave like
processes on one machine. `-c <container>` is required once a pod has more than
one container, otherwise kubectl picks the first and you get confusing results.

This is what a sidecar is. The writer is the app, the reader could be a log
shipper. They are deployed together, scheduled together and die together.

The pod also landed on `svc-lab-worker2` while `first-pod` is on
`svc-lab-worker`, which is the scheduler spreading things out.

---

## 7. Self healing, and its limit

The kubelet restarts a container that dies. I killed the running container
directly through the runtime, behind Kubernetes' back:

```bash
docker exec svc-lab-worker crictl stop <container-id>
```

```text
$ kubectl -n k8s-basics get pod first-pod -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount
NAME        RESTARTS
first-pod   0

$ docker exec svc-lab-worker crictl stop 23ad4b996c07dd9fd257b61e10e954e3dce65d46898c41d34931a70a577afdc3
23ad4b996c07dd9fd257b61e10e954e3dce65d46898c41d34931a70a577afdc3

$ kubectl -n k8s-basics get pod first-pod -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATUS:.status.phase
NAME        RESTARTS   STATUS
first-pod   1          Running
```

`RESTARTS` went 0 to 1 and the pod is `Running` again, with no help from me.
That is `restartPolicy: Always` (the default) being enforced by the kubelet
locally. It did not need the API server's permission.

Important detail: the **pod** did not get recreated. Same pod, same name, same
IP, new container inside it. A restart is cheap. Rescheduling is not.

Now the limit:

```text
$ kubectl -n k8s-basics delete pod shared-pod
pod "shared-pod" deleted from k8s-basics namespace

$ kubectl -n k8s-basics get pods
NAME        READY   STATUS    RESTARTS      AGE
first-pod   1/1     Running   1 (43s ago)   57s
```

`shared-pod` is simply gone. Nothing recreated it, because a bare pod has no
controller watching it. The kubelet restarts containers inside a pod, but
nothing recreates the pod itself.

That is the entire reason ReplicaSets and Deployments exist, which is the next
lab: [`../02_K8s_Pods_ReplicaSets_Deployments`](../02_K8s_Pods_ReplicaSets_Deployments).

---

## 8. Everything is an object in etcd

```text
$ kubectl -n k8s-basics get pod first-pod -o yaml | sed -n '1,12p'
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Pod","metadata":{"annotations":{},"labels":{"app":"first-pod"},"name":"first-pod","namespace":"k8s-basics"},"spec":{"containers":[{"image":"nginxdemos/nginx-hello:plain-text","name":"web","ports":[{"containerPort":8080,"name":"http"}],"resources":{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"25m","memory":"32Mi"}}}]}}
  creationTimestamp: "2026-09-17T17:50:40Z"
  generation: 1
  labels:
    app: first-pod
  name: first-pod
  namespace: k8s-basics
```

That `last-applied-configuration` annotation is how `kubectl apply` knows what to
do on the next apply. It stores the previous applied YAML and diffs against it,
which is how it can tell "the user removed this field" from "the user never set
this field". `kubectl create` does not write it, which is why mixing `create`
and `apply` on the same object behaves oddly.

```text
$ kubectl api-resources --namespaced=true -o name | head -20
bindings
configmaps
endpoints
events
limitranges
persistentvolumeclaims
pods
podtemplates
replicationcontrollers
resourcequotas
secrets
serviceaccounts
services
controllerrevisions.apps
daemonsets.apps
deployments.apps
replicasets.apps
statefulsets.apps
```

Everything is one of these types, stored in etcd, reached through one API. There
is no special path for pods versus services. That uniformity is why one tool,
`kubectl`, handles all of it, and why writing a controller is possible at all:
you watch a type and react.

---

## 9. What I took away

- The control plane is pods, and the pods that make the control plane are static
  pods owned by the `Node`, read off disk by the kubelet. That is the bootstrap.
- Control plane components use `hostNetwork` because they cannot depend on the
  pod network they are responsible for setting up.
- `kubelet` is the only piece that is not a pod, for the same bootstrapping reason.
- A pod is one network namespace and a shared filesystem, which is why two
  containers in one pod report the same IP.
- The kubelet restarts failed **containers** in place, keeping the pod and its
  IP. Nothing restarts a deleted **pod** unless a controller owns it.
- `Image` is a tag, `Image ID` is a digest. Tags move, digests do not.

---

## 10. Reproducing this

```bash
kind create cluster --name svc-lab --config ../cluster/kind-cluster.yaml
cd 01_K8s_Fundamentals
chmod +x verify.sh && ./verify.sh
```

## 11. Cleanup

```bash
kubectl delete namespace k8s-basics
```

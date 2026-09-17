# Kubernetes Pods, ReplicaSets and Deployments

**Name:** Manasvi Sabbarwal
**Roll No:** 24BCS10406
**Cluster:** kind v0.33.0, 3 nodes (1 control-plane + 2 workers), Kubernetes v1.37.0

The controller chain: what a ReplicaSet does that a bare pod cannot, and what a
Deployment does that a ReplicaSet cannot. Every output block is quoted from
[`output.log`](output.log), written by [`verify.sh`](verify.sh).

The previous lab ([`../01_K8s_Fundamentals`](../01_K8s_Fundamentals)) ended by
deleting a bare pod and watching nothing bring it back. This one starts there.

---

## 1. ReplicaSet: keep N pods alive

```bash
kubectl apply -f manifests/01-replicaset.yaml
kubectl -n workloads get rs web-rs
```

```text
$ kubectl -n workloads get rs web-rs
NAME     DESIRED   CURRENT   READY   AGE
web-rs   3         3         3       8s

$ kubectl -n workloads get pods -l app=web-rs -o wide
NAME           READY   STATUS    RESTARTS   AGE   IP            NODE              NOMINATED NODE   READINESS GATES
web-rs-mp5vp   1/1     Running   0          8s    10.244.1.21   svc-lab-worker    <none>           <none>
web-rs-p75dg   1/1     Running   0          8s    10.244.1.20   svc-lab-worker    <none>           <none>
web-rs-sg498   1/1     Running   0          8s    10.244.2.22   svc-lab-worker2   <none>           <none>
```

Three columns, three different meanings: `DESIRED` is what I asked for,
`CURRENT` is how many pod objects exist, `READY` is how many are passing their
readiness check. When something is wrong these three diverge, and which pair
diverges tells you where the problem is.

Every pod carries an owner reference back to the ReplicaSet:

```text
$ kubectl -n workloads get pods -l app=web-rs -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind
NAME           OWNER    KIND
web-rs-mp5vp   web-rs   ReplicaSet
web-rs-p75dg   web-rs   ReplicaSet
web-rs-sg498   web-rs   ReplicaSet
```

This is not decoration. Garbage collection uses it: delete the ReplicaSet and
the pods go with it, because they are its dependents.

### Deleting a pod now does something different

```text
$ kubectl -n workloads delete pod web-rs-mp5vp
pod "web-rs-mp5vp" deleted from workloads namespace

$ kubectl -n workloads get pods -l app=web-rs
NAME           READY   STATUS    RESTARTS   AGE
web-rs-p75dg   1/1     Running   0          15s
web-rs-jdm4c   1/1     Running   0          15s
web-rs-p8nfg   1/1     Running   0          7s
```

A replacement appeared with a **new name** and an age of 7s. That is the
difference from the container restart in the previous lab: there, the pod
survived and the container inside it restarted. Here the pod is genuinely gone
and a new one was created.

The mechanism is a control loop, not an event handler. The ReplicaSet controller
watches pods matching its selector, counts them, compares to `spec.replicas` and
acts on the difference. Nothing tells it "a pod was deleted". It just notices
that 2 is not 3. That is why it also works after a node dies, or if someone
creates a matching pod by hand, in which case it deletes one.

```text
$ kubectl -n workloads scale rs/web-rs --replicas=5
replicaset.apps/web-rs scaled

$ kubectl -n workloads get rs web-rs
NAME     DESIRED   CURRENT   READY   AGE
web-rs   5         5         5       21s
```

---

## 2. Deployment: a controller over ReplicaSets

A ReplicaSet keeps pods alive but has no idea how to change them. Edit its
template and existing pods are left alone. That is what a Deployment adds.

```text
$ kubectl -n workloads get deployment web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    4/4     4            4           9s

$ kubectl -n workloads get rs -l app=web
NAME             DESIRED   CURRENT   READY   AGE
web-6789f69948   4         4         4       9s
```

I created one Deployment and a ReplicaSet appeared that I never asked for. The
suffix `6789f69948` is a hash of the pod template. That detail is the whole
mechanism, as section 3 shows.

The full ownership chain:

```text
$ kubectl -n workloads get pods -l app=web -o custom-columns=POD:.metadata.name,OWNER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind | head -3
POD                    OWNER            KIND
web-6789f69948-mpms7   web-6789f69948   ReplicaSet
web-6789f69948-q6t9p   web-6789f69948   ReplicaSet

$ kubectl -n workloads get rs -l app=web -o custom-columns=RS:.metadata.name,OWNER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind
RS               OWNER   KIND
web-6789f69948   web     Deployment
```

```text
Deployment  web
     |  owns
     v
ReplicaSet  web-6789f69948        (name = hash of the pod template)
     |  owns
     v
Pods        web-6789f69948-xxxxx
```

Three objects, three controllers, each one only responsible for the layer below
it. The Deployment controller never touches pods. It only ever scales
ReplicaSets up and down.

---

## 3. Rolling update

```bash
kubectl apply -f manifests/03-deployment-v2.yaml   # nginx:1.27 -> nginx:1.29
kubectl -n workloads rollout status deployment/web
```

```text
$ kubectl -n workloads rollout status deployment/web --timeout=180s
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "web" rollout to finish: 1 old replicas are pending termination...
deployment "web" successfully rolled out
```

```text
$ kubectl -n workloads get rs -l app=web
NAME             DESIRED   CURRENT   READY   AGE
web-66d744c6cf   4         4         4       8s
web-6789f69948   0         0         0       12s
```

**Two ReplicaSets now.** The old one was not deleted, it was scaled to 0. The
new one has a different hash because the pod template changed. A rolling update
is just the Deployment controller moving replicas from one ReplicaSet to the
other, a few at a time, within the bounds of `maxUnavailable` and `maxSurge`.

Caught mid-rollout, one old pod was still alive alongside the new ones:

```text
$ kubectl -n workloads get pods -l app=web -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,VERSION:.metadata.labels.version
POD                    IMAGE               VERSION
web-66d744c6cf-8wb52   nginx:1.29-alpine   v2
web-66d744c6cf-c5hlt   nginx:1.29-alpine   v2
web-66d744c6cf-fc2tp   nginx:1.29-alpine   v2
web-66d744c6cf-gfp75   nginx:1.29-alpine   v2
web-6789f69948-s7mw9   nginx:1.27-alpine   v1
```

Both versions serving at once is not a bug, it is what a rolling update *is*.
It is also the thing people forget: during a rollout your API is running two
versions simultaneously, so a schema change has to be compatible with both.

```text
$ kubectl -n workloads rollout history deployment/web
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

`CHANGE-CAUSE` is `<none>` because I did not annotate the change. In a real
setup you would set `kubernetes.io/change-cause` so the history is readable.

Keeping the old ReplicaSet around is what makes rollback instant: the object and
its template are still there, so undoing is another scale operation rather than
a rebuild. `revisionHistoryLimit: 5` in the manifest caps how many are kept.

---

## 4. A rollout that fails

Deliberately deploying a tag that does not exist:

```bash
kubectl apply -f manifests/04-deployment-broken.yaml   # nginx:this-tag-does-not-exist
```

```text
$ kubectl -n workloads rollout status deployment/web --timeout=20s || true
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
error: timed out waiting for the condition

$ kubectl -n workloads get pods -l app=web
NAME                   READY   STATUS             RESTARTS   AGE
web-66d744c6cf-c5hlt   1/1     Running            0          48s
web-66d744c6cf-fc2tp   1/1     Running            0          44s
web-66d744c6cf-gfp75   1/1     Running            0          48s
web-69d9b65857-257p9   0/1     ImagePullBackOff   0          40s
web-69d9b65857-qr9cl   0/1     ErrImagePull       0          40s

$ kubectl -n workloads get deployment web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/4     2            3           52s
```

This is the most useful result in this lab. **The app never went down.**

```text
$ kubectl -n workloads get pods -l app=web -o custom-columns=POD:.metadata.name,VERSION:.metadata.labels.version,STATUS:.status.phase,READY:.status.containerStatuses[0].ready
POD                    VERSION     STATUS    READY
web-66d744c6cf-c5hlt   v2          Running   true
web-66d744c6cf-fc2tp   v2          Running   true
web-66d744c6cf-gfp75   v2          Running   true
web-69d9b65857-257p9   v3-broken   Pending   false
web-69d9b65857-qr9cl   v3-broken   Pending   false
```

Three healthy v2 pods still `Running` and `READY=true`, two broken v3 pods stuck
at `Pending`. `maxUnavailable: 1` is what did this: the controller is only
allowed to take down one old pod at a time, and it will not take down the next
one until a replacement becomes Ready. The replacement never becomes Ready, so
the rollout stalls forever rather than proceeding to destroy the working pods.

A stalled rollout is the *safe* failure. If I had set `maxUnavailable: 4`, all
four working pods would have been removed before anyone discovered the image was
wrong.

`ErrImagePull` then `ImagePullBackOff` is the retry sequence: the first pull
fails, then the kubelet backs off exponentially rather than hammering the
registry. Same backoff idea as `CrashLoopBackOff`, different cause.

Note `STATUS: Pending`, not `Failed`. The pod is still waiting to start, since
there is no container to run yet. `kubectl get pods` prints the container's
reason, `.status.phase` prints the pod's, and they are different fields.

---

## 5. Rollback

```bash
kubectl -n workloads rollout undo deployment/web
```

```text
$ kubectl -n workloads rollout undo deployment/web
Warning: resource deployments/web was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations. Consider using 'kubectl apply' with your previous configuration file instead.
deployment.apps/web rolled back

$ kubectl -n workloads get pods -l app=web -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,VERSION:.metadata.labels.version
POD                    IMAGE               VERSION
web-66d744c6cf-c5hlt   nginx:1.29-alpine   v2
web-66d744c6cf-fc2tp   nginx:1.29-alpine   v2
web-66d744c6cf-gfp75   nginx:1.29-alpine   v2
web-66d744c6cf-z8jzv   nginx:1.29-alpine   v2
```

Back to four v2 pods. Notice the ReplicaSet hash is `66d744c6cf`, the **same**
one from section 3. Nothing was rebuilt. The Deployment scaled the broken
ReplicaSet back to 0 and the old one back to 4. Three of the four pods even kept
their original names and ages, because they were never touched in the first place.

That warning is worth reading rather than ignoring. `rollout undo` changes the
live object but not the `last-applied-configuration` annotation, so the next
`kubectl apply` from your unchanged v3 file would happily redeploy the broken
version. Rollback is an emergency stop, not a fix. The fix is in the file.

```text
$ kubectl -n workloads rollout history deployment/web
REVISION  CHANGE-CAUSE
1         <none>
3         <none>
4         <none>
```

Revision 2 is gone and there is now a 4. Revisions are keyed by pod template:
rolling back to the v2 template re-registered it as the newest revision (4)
rather than keeping its old number. So the numbers are an ordering, not a stable
identifier, and `--to-revision` should be read off a fresh `history` rather than
remembered.

---

## 6. DaemonSet: one pod per node

```text
$ kubectl -n workloads get daemonset node-agent
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-agent   2         2         2       2            2           <none>          1s

$ kubectl -n workloads get pods -l app=node-agent -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
POD                NODE
node-agent-42w89   svc-lab-worker
node-agent-chbld   svc-lab-worker2

$ kubectl get nodes
NAME                    STATUS   ROLES           AGE   VERSION
svc-lab-control-plane   Ready    control-plane   22m   v1.37.0
svc-lab-worker          Ready    <none>          22m   v1.37.0
svc-lab-worker2         Ready    <none>          22m   v1.37.0
```

`DESIRED 2` with **three** nodes in the cluster. I never specified 2 anywhere.
A DaemonSet has no `replicas` field at all, it derives the count from how many
nodes it is allowed to run on, and the control-plane node's
`node-role.kubernetes.io/control-plane:NoSchedule` taint excludes it. Add a
worker and a third pod appears by itself.

One on each worker, exactly. This is the shape every node level agent uses:
`kube-proxy` and `kindnet` from the previous lab are DaemonSets for this reason,
along with log collectors and monitoring agents.

---

## 7. Which controller for which job

| Object | Guarantee | Pod identity | Use it for |
|---|---|---|---|
| bare Pod | none, gone when deleted | n/a | debugging only |
| ReplicaSet | N pods exist | interchangeable | almost never directly |
| Deployment | N pods, plus versioned rollouts and rollback | interchangeable | stateless apps, the default |
| DaemonSet | one pod per eligible node | tied to a node | node agents, log shippers, CNI |
| StatefulSet | ordered, stable names and storage | stable (`pod-0`, `pod-1`) | databases, anything with per-pod state |

You almost never write a ReplicaSet by hand. It is worth doing once to see that
a Deployment is not magic: it is a thing that creates ReplicaSets.

---

## 8. What I took away

- The controllers are level triggered loops, comparing desired to actual. They
  do not react to events, which is why they recover from situations nobody
  anticipated.
- A container restart keeps the pod, its name and its IP. A ReplicaSet
  replacement creates a new pod with a new name. Different failure, different
  blast radius.
- The ReplicaSet name is a hash of the pod template, so changing the template
  creates a new ReplicaSet and keeps the old one. That single fact explains
  rolling updates, rollback and revision history.
- `maxUnavailable` is what makes a bad rollout stall instead of causing an
  outage. A stuck rollout is the system protecting you.
- `rollout undo` fixes the cluster, not your YAML. The next `apply` will
  redeploy the bad version if you have not changed the file.
- A DaemonSet's replica count comes from the nodes and their taints, so
  "DESIRED 2" on a 3 node cluster is correct, not a bug.

---

## 9. Reproducing this

```bash
kind create cluster --name svc-lab --config ../cluster/kind-cluster.yaml
cd 02_K8s_Pods_ReplicaSets_Deployments
chmod +x verify.sh && ./verify.sh
```

## 10. Cleanup

```bash
kubectl delete namespace workloads
```

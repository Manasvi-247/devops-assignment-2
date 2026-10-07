# Kubernetes volumes

Notes on the storage objects, each one verified on the cluster in
[`../README.md`](../README.md).

## emptyDir

A directory created when the pod is scheduled and deleted when the pod is
removed. Shared by every container in the pod.

```yaml
volumes:
  - name: scratch
    emptyDir: {}
```

The lifetime is the **pod**, not the container. A container restart keeps the
data; deleting the pod loses it. Right for caches, scratch space and handing
files to a sidecar, wrong for anything you want to keep.

Verified in [`../README.md`](../README.md#1-emptydir-scratch-space-that-dies-with-the-pod):
a reader container read the file a writer container had created.

## hostPath

Mounts a path from the node's own filesystem.

```yaml
hostPath:
  path: /mnt/static-pv
```

It survives the pod, but it is tied to **one node**. That caught me out: a
replacement pod was scheduled onto the other worker and found an empty
directory, because the data was on the first node. The fix is `nodeAffinity` on
the PersistentVolume, and the broader lesson is that hostPath is a lab tool,
not production storage.

## PersistentVolume and PersistentVolumeClaim

A **PV** is a piece of storage that exists. A **PVC** is a request for storage.
Separate objects on purpose: whoever runs the cluster supplies PVs, and
whoever deploys an app writes a PVC without caring what backs it.

```text
static-pv   500Mi   RWO   Retain   Available
static-pv   500Mi   RWO   Retain   Bound   storage-lab/static-pvc
```

Binding is **exclusive**: one PVC takes the whole PV, even if it asked for less
than the capacity. For a bind to happen the access mode, capacity and storage
class must all be compatible.

### Access modes

| Mode | Meaning |
|---|---|
| ReadWriteOnce | one node may mount it read write |
| ReadOnlyMany | many nodes, read only |
| ReadWriteMany | many nodes, read write, needs NFS or similar |

RWO is per **node**, not per pod. Several pods on the same node can share an
RWO volume, which is why an RWO claim and a multi replica Deployment appear to
work right up until the scheduler spreads the pods.

### Reclaim policy

`Retain` leaves the data after the claim is deleted, and the PV goes to
`Released` rather than being reused. `Delete` removes the underlying storage,
which is what the dynamic class uses.

## StorageClass and dynamic provisioning

A StorageClass names a provisioner that creates a PV on demand, so nobody has
to pre-create them.

```text
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

`VOLUMEBINDINGMODE` is the column worth reading. With `WaitForFirstConsumer`
the claim deliberately stays `Pending` until a pod mounts it, so the scheduler
picks the node first and the storage follows. With `Immediate` the volume is
created straight away and can land somewhere the pod cannot run.

I got this wrong on the first run and recorded the correction in
[`../README.md`](../README.md#4-storageclass-and-dynamic-provisioning): a
`Pending` PVC on a `WaitForFirstConsumer` class is the normal state, not a
fault.

## Which to use

| Need | Use |
|---|---|
| scratch space inside a pod | emptyDir |
| a file from the node, in a lab | hostPath with nodeAffinity |
| storage that outlives the pod | PVC against a StorageClass |
| one volume per replica | `volumeClaimTemplates` on a StatefulSet |

The last row is the one that matters for scaling. A Deployment with an RWO PVC
and an HPA pulls in opposite directions, because every replica wants the same
volume on the same node. A StatefulSet gives each pod its own claim, which is
shown in
[`../../02_K8s_Pods_ReplicaSets_Deployments`](../../02_K8s_Pods_ReplicaSets_Deployments).

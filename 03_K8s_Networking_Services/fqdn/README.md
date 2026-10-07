# FQDN in Kubernetes

Every Service gets a DNS name. The fully qualified form is:

```text
<service>.<namespace>.svc.cluster.local
```

so `hello-api-svc` in namespace `svc-lab` is
`hello-api-svc.svc-lab.svc.cluster.local`.

All four labels are verified against the live cluster in
[`../README.md`](../README.md#4-three-ways-to-reach-it).

## The four parts

| Part | Means |
|---|---|
| `hello-api-svc` | the Service name |
| `svc-lab` | the namespace it lives in |
| `svc` | the kind of record, as opposed to `pod` |
| `cluster.local` | the cluster domain, configurable at install |

## Why short names work

A pod does not normally use the full name, because of the search list the
kubelet writes into `/etc/resolv.conf`:

```text
search svc-lab.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

The resolver appends each suffix in turn until one resolves. From inside
`svc-lab`, `hello-api-svc` becomes
`hello-api-svc.svc-lab.svc.cluster.local` on the first try.

## Which is why short names break across namespaces

A pod in `default` gets `search default.svc.cluster.local ...`. Nothing in that
list ever produces the `svc-lab` form, so the short name simply does not
resolve. Measured in [`../README.md`](../README.md#8-test-4-how-far-a-clusterip-reaches):
the short name failed and the FQDN succeeded one second later, same image, same
namespace.

Anything crossing namespaces needs at least `<service>.<namespace>`.

## ndots:5

Any name with fewer than 5 dots is tried against the search list **before**
being tried as written. `hello-api-svc` has none, so it costs up to three extra
queries before it resolves.

That is cheap in a lab and measurable in production, where an application
calling an external API thousands of times per second pays for several failed
lookups on every call. Using the full name, with a trailing dot to make it
absolute, skips the search list entirely.

## Pod records

Pods get records too, in the form `<ip-with-dashes>.<namespace>.pod.cluster.local`,
which is rarely useful. The exception is a StatefulSet behind a headless
service, where each pod gets a stable name:

```text
web-stateful-0.web-headless.svc-lab.svc.cluster.local
```

That name survives the pod being deleted and rescheduled onto a new IP, which
is demonstrated in [`../README.md`](../README.md#13-headless-service).

## Shapes worth remembering

| Name | Resolves to |
|---|---|
| `hello-api-svc` | only within the same namespace |
| `hello-api-svc.svc-lab` | from anywhere in the cluster |
| `hello-api-svc.svc-lab.svc.cluster.local` | the same, unambiguously |
| `web-stateful-0.web-headless` | one specific pod |
| `kubernetes.default.svc` | the API server |

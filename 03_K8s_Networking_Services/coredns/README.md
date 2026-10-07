# CoreDNS

CoreDNS is the DNS server inside the cluster. It answers the Service names
described in [`../fqdn`](../fqdn/README.md).

## What it is

A plugin driven DNS server, running as an ordinary Deployment in
`kube-system`, fronted by a Service on a fixed address:

```text
$ kubectl -n kube-system get pods -l k8s-app=kube-dns
coredns-559f6c778d-4llch   1/1   Running   0   15m   10.244.0.4
coredns-559f6c778d-cr56z   1/1   Running   0   15m   10.244.0.2
```

Two replicas, with real pod IPs, because unlike the control plane components it
is a normal workload. That output is from
[`../../01_K8s_Fundamentals`](../../01_K8s_Fundamentals).

The address every pod uses is the Service in front of them, `10.96.0.10`, which
is why `/etc/resolv.conf` can be written once at pod creation and stay correct
when a CoreDNS pod is replaced.

## Why Kubernetes needs it

Pod IPs change on every reschedule, so nothing can hardcode them. A Service
gives a stable virtual IP, and CoreDNS gives that IP a stable **name**. Without
it, service discovery would mean every application talking to the API server.

CoreDNS replaced kube-dns in 1.13. It is one binary rather than three
containers, and the plugin chain is configurable.

## How a lookup resolves

1. The pod's resolver reads `/etc/resolv.conf` and sends the query to
   `10.96.0.10`.
2. kube-proxy's rules forward it to one of the CoreDNS pods.
3. The `kubernetes` plugin matches names under `cluster.local` and answers from
   its watch of Services and EndpointSlices.
4. Anything else falls through to `forward`, which sends it upstream.

The answer depends on the Service type, which is the part worth knowing:

| Service type | Answer |
|---|---|
| ClusterIP | one A record, the virtual IP |
| Headless | one A record per ready pod |
| ExternalName | a CNAME, no A record of its own |

All three are measured in [`../README.md`](../README.md#13-headless-service):
the headless service returned three pod IPs where the ClusterIP service over
the same pods returned a single VIP.

## Configuration

A ConfigMap named `coredns` in `kube-system`, holding a Corefile:

```text
.:53 {
    errors
    health
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
```

`forward . /etc/resolv.conf` sends anything not matching `cluster.local` to the
node's own resolver, which is how a pod reaches the internet. `cache 30` holds
answers for 30 seconds, which is also why a change can take up to half a minute
to be seen.

## Troubleshooting

Work from the outside in.

```bash
# is it running at all
kubectl -n kube-system get pods -l k8s-app=kube-dns

# what does the pod think its resolver is
kubectl exec <pod> -- cat /etc/resolv.conf

# does the name resolve, and to what
kubectl exec <pod> -- nslookup <service>.<namespace>.svc.cluster.local

# if it resolves but traffic fails, it is not DNS
kubectl get endpointslices -l kubernetes.io/service-name=<service>
```

The distinction that saves the most time: **a name that resolves rules DNS
out.** In the broken service drill in
[`../../06_K8s_Troubleshooting`](../../06_K8s_Troubleshooting) the name resolved
correctly and curl still failed with exit 7, because the Service had no
endpoints. Reaching for CoreDNS there would have been the wrong direction
entirely.

Curl exit codes separate the cases: 6 is a name that did not resolve, 7 is a
name that resolved with nothing behind it.

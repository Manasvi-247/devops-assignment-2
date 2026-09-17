# Session 11: Kubernetes Services (ClusterIP)

**Name:** Manasvi Sabbarwal
**Roll No:** 24BCS10406
**Cluster used:** kind v0.33.0, 3 nodes (1 control-plane + 2 workers), Kubernetes v1.37.0

This is the ClusterIP exercise from the class repo:
[session-11-kubernetes-services/01-clusterip](https://github.com/Nency-Ravaliya/devops-heros/tree/main/session-11-kubernetes-services/01-clusterip).

I wrote my own manifests instead of just applying the class ones. The reason is
that the class version uses a plain nginx image, and every nginx pod returns the
exact same welcome page, so you cannot actually see the service picking a
different pod each time. I wanted the output to prove the load balancing, not
just claim it.

What I changed and why:

| Change | Reason |
|---|---|
| Used `nginxdemos/nginx-hello:plain-text` as the backend | It prints the pod name and pod IP in the response body, so you can see which pod answered. |
| Put everything in a `svc-lab` namespace instead of `default` | Makes the FQDN `<service>.<namespace>.svc.cluster.local` actually mean something, and lets me test what a client in a different namespace sees. |
| Service port 9090, container port 8080, `targetPort` set to the named port `http` | Three different numbers, so it is obvious which field is which. Using the port name also means the service keeps working if I change the container port later. |
| Added a readiness probe to the deployment | A pod joins the service endpoints only when it is Ready, not when it is merely Running. Wanted to see that. |
| Ran it on a 2-worker cluster instead of a single node | The three backend pods get spread over both workers, so the service traffic really does cross a node boundary. |

Every block of output below was copied from [`output.log`](output.log), which is
written by [`verify.sh`](verify.sh). Nothing in this file is typed by hand.

---

## 1. Why services exist

Pods die. When a pod is rescheduled or restarted it comes back with a different
IP, so nothing can hardcode a pod IP. A ClusterIP service gives you a fixed
virtual IP and a fixed DNS name that sits in front of whichever pods currently
match its label selector.

```text
      curl-box pod
           |
   http://hello-api-svc:9090        (name never changes)
           |
           v
  +--------------------------+
  |  Service (ClusterIP)     |   virtual IP, handled by kube-proxy
  |  10.96.214.58 : 9090     |   (iptables / ipvs rules on every node)
  +--------------------------+
           |
  selector: app=hello-api  ->  EndpointSlice = list of Ready pod IPs
           |
   +-------+-------+-------+
   v               v       v
 pod:8080      pod:8080  pod:8080
```

One thing that confused me at first: the ClusterIP is not assigned to any
network interface anywhere. Nothing is listening on it. kube-proxy writes rules
on every node that rewrite packets headed for `10.96.214.58:9090` so they go to
one of the pod IPs on port 8080 instead. That is why the ClusterIP only works
inside the cluster. From my laptop it is just a random unroutable address, and
section 8 shows exactly that.

Where this is used in real setups: service to service calls (orders calling
payments), databases and caches running inside the cluster that should never be
public, internal metrics and logging endpoints, and as the backend that an
Ingress controller forwards traffic to.

---

## 2. Files

```text
01_K8s_Services/
├── README.md                     this file
├── verify.sh                     runs every check and writes output.log
├── output.log                    the raw terminal output, unedited
├── manifests/
│   └── 01-clusterip/
│       ├── 00-namespace.yaml
│       ├── 01-deployment.yaml
│       ├── 02-service.yaml
│       └── 03-client-pod.yaml
└── screenshots/                  terminal captures
```

| File | What it creates |
|---|---|
| [`00-namespace.yaml`](manifests/01-clusterip/00-namespace.yaml) | Namespace `svc-lab` |
| [`01-deployment.yaml`](manifests/01-clusterip/01-deployment.yaml) | Deployment `hello-api`, 3 replicas, label `app: hello-api`, container port 8080 |
| [`02-service.yaml`](manifests/01-clusterip/02-service.yaml) | Service `hello-api-svc`, type ClusterIP, 9090 to http (8080) |
| [`03-client-pod.yaml`](manifests/01-clusterip/03-client-pod.yaml) | Pod `curl-box`, a client inside the cluster to test from |
| [`verify.sh`](verify.sh) | Runs every check below and saves the raw output to `output.log` |

The two fields that have to match, otherwise none of this works:

```yaml
# 01-deployment.yaml            # 02-service.yaml
template:                     spec:
  metadata:                     selector:
    labels:                       app: hello-api   # must match
      app: hello-api   # <----------------------------'
```

Checked on the running cluster, the pod labels and the service selector do line
up. This check and the `port-forward` one in section 8 were added to
`verify.sh` after the first run and captured a minute later against the same
cluster, so the pod names here are the replacements from section 7, not the
ones in section 3:

```text
$ kubectl -n svc-lab get pods --show-labels
NAME                         READY   STATUS    RESTARTS   AGE    LABELS
curl-box                     1/1     Running   0          100s   app=curl-box,tier=client
hello-api-6ddb65475c-c2hlm   1/1     Running   0          70s    app=hello-api,pod-template-hash=6ddb65475c,tier=backend
hello-api-6ddb65475c-j2vds   1/1     Running   0          70s    app=hello-api,pod-template-hash=6ddb65475c,tier=backend
hello-api-6ddb65475c-tl64v   1/1     Running   0          70s    app=hello-api,pod-template-hash=6ddb65475c,tier=backend

$ kubectl -n svc-lab get svc hello-api-svc -o jsonpath="{.spec.selector}"
{"app":"hello-api"}
```

Note the selector is only `app: hello-api`. The pods also carry `tier: backend`
and a `pod-template-hash`, and that is fine: a selector has to be a subset of
the pod labels, not an exact match. The `curl-box` pod has `app=curl-box` so it
is not picked up, which is what I wanted, the client should not be a backend of
the service it is calling.

If the labels do not match, Kubernetes still creates the service without
complaining. It just ends up with zero endpoints. That is the most common reason
a service "does not work".

---

## 3. Deploying it

```bash
kubectl apply -f manifests/01-clusterip/00-namespace.yaml
kubectl apply -f manifests/01-clusterip/
kubectl -n svc-lab rollout status deployment/hello-api
```

```text
$ kubectl apply -f manifests/01-clusterip/00-namespace.yaml
namespace/svc-lab created

$ kubectl apply -f manifests/01-clusterip/
namespace/svc-lab unchanged
deployment.apps/hello-api created
service/hello-api-svc created
pod/curl-box created

$ kubectl -n svc-lab rollout status deployment/hello-api --timeout=180s
Waiting for deployment "hello-api" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "hello-api" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "hello-api" rollout to finish: 2 of 3 updated replicas are available...
deployment "hello-api" successfully rolled out

$ kubectl -n svc-lab wait --for=condition=Ready pod/curl-box --timeout=180s
pod/curl-box condition met
```

The namespace gets applied on its own first. If you only run the second command
on a fresh cluster it is a race: `kubectl` can try to create the deployment in a
namespace that does not exist yet and the apply fails. Applying the namespace
first makes the second apply report `namespace/svc-lab unchanged`, which is the
harmless case.

The replicas going available one at a time is the readiness probe doing its job.
The pods were Running almost immediately, but each one only counts as available
once its first probe succeeds.

### Checking what got created

```bash
kubectl -n svc-lab get pods -o wide
kubectl -n svc-lab get svc hello-api-svc
kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc
```

```text
$ kubectl -n svc-lab get pods -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINATED NODE   READINESS GATES
curl-box                     1/1     Running   0          14s   10.244.1.2   svc-lab-worker    <none>           <none>
hello-api-6ddb65475c-b2ltm   1/1     Running   0          14s   10.244.2.3   svc-lab-worker2   <none>           <none>
hello-api-6ddb65475c-fwbx4   1/1     Running   0          14s   10.244.1.3   svc-lab-worker    <none>           <none>
hello-api-6ddb65475c-tdqpf   1/1     Running   0          14s   10.244.2.2   svc-lab-worker2   <none>           <none>

$ kubectl -n svc-lab get svc hello-api-svc
NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
hello-api-svc   ClusterIP   10.96.214.58   <none>        9090/TCP   14s

$ kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc
NAME                  ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
hello-api-svc-n595n   IPv4          8080    10.244.2.3,10.244.1.3,10.244.2.2   15s
```

Things to notice in this output:

- `EXTERNAL-IP` is `<none>`, so the service is internal only. That single column
  is the difference between ClusterIP and the other service types.
- The EndpointSlice lists port **8080**, not 9090, because the port translation
  happens at the service. Endpoints are always container ports.
- The pod IPs are on two different subnets, `10.244.1.x` and `10.244.2.x`. Each
  node gets its own pod CIDR, so you can tell from the IP which worker a pod is
  on. `curl-box` is on `svc-lab-worker` and two of the three backends are on
  `svc-lab-worker2`, so most of these requests are crossing nodes.

`describe` shows the same thing in one place, including the `targetPort` still
being the name rather than a number:

```text
$ kubectl -n svc-lab describe svc hello-api-svc
Name:                     hello-api-svc
Namespace:                svc-lab
Labels:                   app=hello-api
Annotations:              <none>
Selector:                 app=hello-api
Type:                     ClusterIP
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.96.214.58
IPs:                      10.96.214.58
Port:                     http  9090/TCP
TargetPort:               http/TCP
Endpoints:                10.244.1.4:8080,10.244.2.6:8080,10.244.2.5:8080
Session Affinity:         None
Internal Traffic Policy:  Cluster
Events:                   <none>
```

Also, `kubectl get endpoints` still works but the Endpoints object is deprecated
now. EndpointSlices is what replaced it, and it is what the service controller
actually maintains.

---

## 4. Three ways to reach it

```bash
kubectl -n svc-lab exec curl-box -- curl -s http://hello-api-svc:9090
kubectl -n svc-lab exec curl-box -- curl -s http://10.96.214.58:9090
kubectl -n svc-lab exec curl-box -- curl -s http://hello-api-svc.svc-lab.svc.cluster.local:9090
```

```text
$ kubectl -n svc-lab exec curl-box -- curl -s http://hello-api-svc:9090
Server address: 10.244.2.2:8080
Server name: hello-api-6ddb65475c-tdqpf
Date: 17/Sep/2026:17:36:08 +0000
URI: /
Request ID: e3e09bccebb12ac86905c557d1087ed4

$ kubectl -n svc-lab exec curl-box -- curl -s http://10.96.214.58:9090
Server address: 10.244.1.3:8080
Server name: hello-api-6ddb65475c-fwbx4
Date: 17/Sep/2026:17:36:08 +0000
URI: /
Request ID: 812cb1204465c74716c582c07a29eb5a

$ kubectl -n svc-lab exec curl-box -- curl -s http://hello-api-svc.svc-lab.svc.cluster.local:9090
Server address: 10.244.1.3:8080
Server name: hello-api-6ddb65475c-fwbx4
Date: 17/Sep/2026:17:36:08 +0000
URI: /
Request ID: 295585373e60b3479957641fa236a125
```

All three reach the same service. The `Server address` line is the pod that
answered, and it is a different pod for the first request than for the other
two, which is already a hint that something is balancing.

The short name only works because of the search domains inside the client pod:

```bash
kubectl -n svc-lab exec curl-box -- cat /etc/resolv.conf
kubectl -n svc-lab exec curl-box -- nslookup hello-api-svc.svc-lab.svc.cluster.local
```

```text
$ kubectl -n svc-lab exec curl-box -- cat /etc/resolv.conf
search svc-lab.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5

$ kubectl -n svc-lab exec curl-box -- nslookup hello-api-svc.svc-lab.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	hello-api-svc.svc-lab.svc.cluster.local
Address: 10.96.214.58
```

The `search svc-lab.svc.cluster.local svc.cluster.local cluster.local` line means
the resolver keeps appending those suffixes to a short name until one of them
resolves. The nameserver `10.96.0.10` is CoreDNS, itself a ClusterIP service in
`kube-system`. The full form of the name is
`<service>.<namespace>.svc.cluster.local`.

`options ndots:5` is worth knowing about: any name with fewer than 5 dots gets
tried against the search list first, so `hello-api-svc` costs a few extra DNS
queries before it lands. Using the FQDN skips that, which is why busy services
are often addressed by the full name.

The important part of the `nslookup` result is that DNS returns the **ClusterIP**
`10.96.214.58`, one single address, not the three pod IPs. That is the
difference between a normal ClusterIP service and a headless one.

---

## 5. Test 1: does it really load balance

Twelve requests, counting which pod answered each one:

```bash
kubectl -n svc-lab exec curl-box -- sh -c \
  'for i in $(seq 1 12); do curl -s http://hello-api-svc:9090 | grep "Server name"; done' \
  | sort | uniq -c
```

```text
$ kubectl -n svc-lab exec curl-box -- sh -c 'for i in $(seq 1 12); do curl -s http://hello-api-svc:9090 | grep "Server name"; done' | sort | uniq -c
   6 Server name: hello-api-6ddb65475c-b2ltm
   4 Server name: hello-api-6ddb65475c-fwbx4
   2 Server name: hello-api-6ddb65475c-tdqpf
```

All three pods answered, so the service really is spreading requests. The split
is 6/4/2 rather than 4/4/4, which surprised me until I read that kube-proxy in
iptables mode picks a backend at random per connection, using probability rules,
not strict round robin. Over 12 requests random is visibly lumpy. It evens out
over thousands.

The other thing this proves is that it balances per connection, not per client.
Same client pod, same URL, twelve separate TCP connections, three different
backends. If I had used one keep-alive connection instead, every request would
have gone to the same pod, which is a real problem with gRPC and other long
lived connections.

---

## 6. Test 2: endpoints follow the pods on their own

```bash
kubectl -n svc-lab delete pod hello-api-6ddb65475c-b2ltm
kubectl -n svc-lab rollout status deployment/hello-api
kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc
kubectl -n svc-lab exec curl-box -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://hello-api-svc:9090
```

```text
$ kubectl -n svc-lab delete pod hello-api-6ddb65475c-b2ltm
pod "hello-api-6ddb65475c-b2ltm" deleted from svc-lab namespace

$ kubectl -n svc-lab rollout status deployment/hello-api --timeout=120s
Waiting for deployment "hello-api" rollout to finish: 2 of 3 updated replicas are available...
deployment "hello-api" successfully rolled out

$ kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc
NAME                  ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
hello-api-svc-n595n   IPv4          8080    10.244.1.3,10.244.2.2,10.244.2.4   23s

$ kubectl -n svc-lab exec curl-box -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://hello-api-svc:9090
HTTP 200
```

Compare the endpoint list with the one in section 3. `10.244.2.3` (the pod I
deleted) is gone and `10.244.2.4` (the replacement) has taken its place, while
`10.244.1.3` and `10.244.2.2` stayed. I did not touch the service at all. The
client kept using the same URL and still got HTTP 200.

Notice the EndpointSlice name `hello-api-svc-n595n` did not change either, and
neither did the ClusterIP. The slice is an object that gets edited in place as
pods come and go. This is basically the whole point of a service: the identity
is stable, the membership is not.

---

## 7. Test 3: what a broken service looks like

Scaling the deployment to zero is the quickest way to reproduce the "no
endpoints" problem deliberately:

```bash
kubectl -n svc-lab scale deployment/hello-api --replicas=0
kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc
kubectl -n svc-lab exec curl-box -- curl -s -m 5 http://hello-api-svc:9090
```

```text
$ kubectl -n svc-lab scale deployment/hello-api --replicas=0
deployment.apps/hello-api scaled

$ kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc
NAME                  ADDRESSTYPE   PORTS     ENDPOINTS   AGE
hello-api-svc-n595n   IPv4          <unset>   <unset>     30s

$ kubectl -n svc-lab exec curl-box -- curl -s -m 5 -o /dev/null -w 'exit=%{exitcode} http=%{http_code}\n' http://hello-api-svc:9090
exit=7 http=000
command terminated with exit code 7

$ kubectl -n svc-lab scale deployment/hello-api --replicas=3
deployment.apps/hello-api scaled

$ kubectl -n svc-lab rollout status deployment/hello-api --timeout=120s
Waiting for deployment "hello-api" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "hello-api" rollout to finish: 1 of 3 updated replicas are available...
deployment "hello-api" successfully rolled out
```

The EndpointSlice still exists, it just shows `<unset>` for both PORTS and
ENDPOINTS now. That is the empty state, and it is exactly what a misconfigured
selector looks like too. So `<unset>` in that column is the single most useful
thing to look for when a service is not working.

The failure itself is worth reading carefully. curl exited **7**, which is
`CURLE_COULDNT_CONNECT`, and the HTTP code is `000` because there was never a
response. It failed instantly, it did not sit there until the 5 second timeout.
That matters for debugging:

- **exit 7, immediate** means the packet was rejected. DNS worked, the ClusterIP
  exists, kube-proxy had no backend to send it to, so it rejected the connection.
  The problem is endpoints.
- **exit 28, after the full timeout** would mean the packet went somewhere and
  nothing answered, which points at a network policy, a wrong `targetPort`, or an
  app that is not actually listening.
- **exit 6** would mean the name did not resolve at all, which is a DNS or
  namespace problem.

So: the name still resolves and the ClusterIP still exists even with zero pods.
A service does not "go down" when its backends do. If the name resolves and curl
still fails fast, look at endpoints, not DNS.

---

## 8. Test 4: how far a ClusterIP reaches

From a pod in the `default` namespace:

```bash
kubectl -n default run tmp-client --rm -i --restart=Never --image=curlimages/curl:8.7.1 \
  -- curl -s -m 5 http://hello-api-svc:9090

kubectl -n default run tmp-client2 --rm -i --restart=Never --image=curlimages/curl:8.7.1 \
  -- curl -s -m 5 http://hello-api-svc.svc-lab.svc.cluster.local:9090
```

```text
$ kubectl -n default run tmp-client --rm -i --restart=Never --image=curlimages/curl:8.7.1 -- curl -s -m 5 http://hello-api-svc:9090
pod "tmp-client" deleted from default namespace
pod default/tmp-client terminated (Error)

$ kubectl -n default run tmp-client2 --rm -i --restart=Never --image=curlimages/curl:8.7.1 -- curl -s -m 5 http://hello-api-svc.svc-lab.svc.cluster.local:9090
Server address: 10.244.2.5:8080
Server name: hello-api-6ddb65475c-c2hlm
Date: 17/Sep/2026:17:36:33 +0000
URI: /
Request ID: ed55168b5386a06691f738c5c5d1b9be
pod "tmp-client2" deleted from default namespace
```

The short name produced no body at all and the pod `terminated (Error)`. The
FQDN from the same namespace, with the same image, in the same second, returned
a normal response. The service did not change between the two, only the name
did.

The reason is the search list from section 4. A pod in `default` gets
`search default.svc.cluster.local svc.cluster.local cluster.local`, so
`hello-api-svc` is tried as `hello-api-svc.default.svc.cluster.local` first,
which does not exist. Nothing in that list ever produces the `svc-lab` form.
Short names are a same-namespace convenience, and anything calling across
namespaces needs at least `<service>.<namespace>`.

And from my laptop, outside the cluster:

```bash
curl -m 5 http://10.96.214.58:9090
```

```text
# From the laptop itself (outside the cluster) the ClusterIP is unreachable:

$ curl -s -m 5 http://10.96.214.58:9090 || echo 'failed as expected - ClusterIP is not routable from outside'
failed as expected - ClusterIP is not routable from outside
```

`10.96.0.0/12` is a made up range that only exists as iptables rules on the
cluster nodes. My Mac has no route to it and no rules for it, so the request
just dies. This is the defining property of ClusterIP, and it is a feature: an
internal database service is not one firewall mistake away from being public.

If you want to see the app in a browser while developing, you have to tunnel:

```bash
kubectl -n svc-lab port-forward svc/hello-api-svc 9090:9090
# then open http://localhost:9090
```

```text
$ kubectl -n svc-lab port-forward svc/hello-api-svc 9090:9090 &
Forwarding from 127.0.0.1:9090 -> 8080
Forwarding from [::1]:9090 -> 8080

$ curl -s http://localhost:9090
Server address: 127.0.0.1:8080
Server name: hello-api-6ddb65475c-c2hlm
Date: 17/Sep/2026:17:37:41 +0000
URI: /
Request ID: 32623a3dd97de771ace1d96a2c3df084
```

Same ClusterIP that was unreachable a moment ago, now reachable on
`localhost:9090`. Two details in this output give away how it works.
`Forwarding from 127.0.0.1:9090 -> 8080` shows it resolved the service down to a
container port, and `Server address: 127.0.0.1:8080` shows the backend saw the
connection as coming from inside its own pod. The traffic went through the API
server and out of the kubelet, it never touched the ClusterIP or kube-proxy at
all. It also picked one pod and stayed on it, so there is no load balancing here.

`port-forward` is a debugging tunnel, not a way to expose an app. For actual
external access you need NodePort, LoadBalancer or Ingress, which is the next
part of the session.

---

## 9. Troubleshooting notes

| What you see | What is actually wrong | How to check |
|---|---|---|
| EndpointSlice shows `<unset>` | Service selector does not match the pod labels, or no pod is Ready | `kubectl -n svc-lab get pods --show-labels` and compare with `kubectl -n svc-lab get svc hello-api-svc -o jsonpath='{.spec.selector}'` |
| Pods are Running but still not in endpoints | Readiness probe is failing, Running is not Ready | `kubectl -n svc-lab describe pod <pod>` and read the Events |
| curl exits 7 immediately | No endpoints behind the service | `kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hello-api-svc` |
| curl exits 28 after the full timeout | `targetPort` does not match the port the container listens on, or a NetworkPolicy is dropping it | `kubectl -n svc-lab get svc hello-api-svc -o yaml` against the container port |
| curl exits 6 | Name does not resolve: wrong namespace in the name, or CoreDNS is down | `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| Works by ClusterIP but not by name | DNS problem only, the service itself is fine | Compare `nslookup` with a direct IP curl |
| Works inside the namespace, fails from another one | Short name, needs the FQDN | Retry with `<svc>.<namespace>.svc.cluster.local` |

---

## 10. What I took away

- A service is not a process running somewhere. It is a set of packet rules that
  kube-proxy programs on every node from the EndpointSlice. Nothing listens on
  the ClusterIP.
- `port`, `targetPort` and the container port are three separate numbers.
  Endpoints always show the container port, never the service port.
- Readiness, not liveness, decides whether a pod gets traffic. That is why the
  rollout went available one replica at a time.
- Balancing is random per connection, not round robin, and it is per connection,
  so anything holding one long lived connection will pin itself to one pod.
- The service survives its pods. Delete one and the endpoint list edits itself
  while the name, the ClusterIP and the client all stay untouched.
- The curl exit code tells you which layer broke: 6 is DNS, 7 is no endpoints,
  28 is ports or policy.
- Short DNS names are just the search domains in `/etc/resolv.conf`. Anything
  crossing namespaces uses the full name.

---

## 11. Screenshots

Terminal captures of the same run, straight from [`output.log`](output.log).

| Step | Capture |
|---|---|
| Deploy the namespace, deployment, service and client pod | [`k11-01-deploy.png`](screenshots/k11-01-deploy.png) |
| Pods, service and EndpointSlice after the rollout | [`k11-02-created.png`](screenshots/k11-02-created.png) |
| Reaching the service by short name, ClusterIP and FQDN | [`k11-03-three-ways.png`](screenshots/k11-03-three-ways.png) |
| `resolv.conf` search domains and the CoreDNS lookup | [`k11-04-dns.png`](screenshots/k11-04-dns.png) |
| 12 requests split across all three pods | [`k11-05-load-balancing.png`](screenshots/k11-05-load-balancing.png) |
| Deleting a pod, the EndpointSlice updates itself | [`k11-06-endpoints-follow-pods.png`](screenshots/k11-06-endpoints-follow-pods.png) |
| Scaled to zero: empty endpoints and curl exit 7 | [`k11-07-empty-endpoints.png`](screenshots/k11-07-empty-endpoints.png) |
| Cross-namespace short name vs FQDN, and from the laptop | [`k11-08-clusterip-scope.png`](screenshots/k11-08-clusterip-scope.png) |

![Load balancing across three pods](screenshots/k11-05-load-balancing.png)

---

## 12. Reproducing this

```bash
kind create cluster --name svc-lab --config ../cluster/kind-cluster.yaml
cd 01_K8s_Services
chmod +x verify.sh && ./verify.sh
```

`verify.sh` writes everything to `output.log`, which is what this README quotes.

## 13. Cleanup

```bash
kubectl delete namespace svc-lab
kind delete cluster --name svc-lab
```

Deleting the namespace takes the deployment, service, EndpointSlice and client
pod with it in one go. Deleting the kind cluster removes the nodes as well.

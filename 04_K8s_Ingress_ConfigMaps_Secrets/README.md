# Kubernetes Ingress, ConfigMaps and Secrets

**Name:** Manasvi Sabbarwal
**Roll No:** 24BCS10406
**Cluster:** kind v0.33.0, 3 nodes (1 control-plane + 2 workers), Kubernetes v1.37.0
**Ingress controller:** ingress-nginx v1.11.3

Getting configuration and credentials into a pod, and getting HTTP traffic into
the cluster by name. Every output block is quoted from [`output.log`](output.log),
written by [`verify.sh`](verify.sh).

---

## 1. ConfigMap and Secret: what is actually stored

```text
$ kubectl -n app-config get configmap app-settings -o yaml | sed -n '1,20p'
apiVersion: v1
data:
  APP_NAME: checkout-service
  APP_TIER: backend
  LOG_LEVEL: info
  app.properties: |
    feature.newCheckout=true
    feature.darkMode=false
    cache.ttlSeconds=300
kind: ConfigMap
```

A ConfigMap holds both shapes at once: short key/value pairs, and a whole file
keyed by filename. Which one you use decides how it can be consumed. Simple keys
work as environment variables; a multi-line value really only makes sense
mounted as a file.

The Secret was written with `stringData` so the YAML stays readable, but that is
not what gets stored:

```text
$ kubectl -n app-config get secret db-credentials -o jsonpath='{.data}'
{"DB_PASSWORD":"czNjcjN0LXBAc3N3MHJk","DB_USER":"Y2hlY2tvdXRfYXBw"}

$ kubectl -n app-config get secret db-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
s3cr3t-p@ssw0rd
```

**base64 is encoding, not encryption.** One command turns it back into the
password. A Secret is not a vault, it is a ConfigMap with slightly different
handling and much better etiquette around it. What actually protects it is RBAC
(who can `get secrets` in this namespace) and encryption at rest on etcd, which
is off by default.

`describe` is the one place the difference shows:

```text
$ kubectl -n app-config describe secret db-credentials
Type:  Opaque

Data
====
DB_PASSWORD:  15 bytes
DB_USER:      12 bytes
```

It prints sizes, not values, so a secret does not end up in your terminal
scrollback or a screen share. `describe configmap` prints values in full. That
asymmetry is the practical reason to use a Secret for credentials even though
the storage is barely different.

---

## 2. Four ways to consume them, in one pod

```text
# env vars, from the configmap and from the secret:
$ kubectl -n app-config exec config-consumer -- sh -c 'echo APP_NAME=$APP_NAME; echo LOG_LEVEL=$LOG_LEVEL; echo DB_PASSWORD=$DB_PASSWORD'
APP_NAME=checkout-service
LOG_LEVEL=info
DB_PASSWORD=s3cr3t-p@ssw0rd
```

```text
# the configmap mounted as a directory of files:
$ kubectl -n app-config exec config-consumer -- ls -l /etc/app
total 0
lrwxrwxrwx    1 root     root            15 Sep 17 18:01 APP_NAME -> ..data/APP_NAME
lrwxrwxrwx    1 root     root            15 Sep 17 18:01 APP_TIER -> ..data/APP_TIER
lrwxrwxrwx    1 root     root            16 Sep 17 18:01 LOG_LEVEL -> ..data/LOG_LEVEL
lrwxrwxrwx    1 root     root            21 Sep 17 18:01 app.properties -> ..data/app.properties

$ kubectl -n app-config exec config-consumer -- cat /etc/app/app.properties
feature.newCheckout=true
feature.darkMode=false
cache.ttlSeconds=300
```

Every entry is a **symlink into `..data/`**, not a regular file. That is
deliberate. When the content changes the kubelet writes a whole new hidden
directory and then swings one symlink, so a reader never catches a half-written
file. The update is atomic. It also means code that stats the file by inode, or
watches it with a naive file watcher, can miss changes.

```text
# the secret mounted as files, decoded automatically, on a tmpfs:
$ kubectl -n app-config exec config-consumer -- cat /etc/creds/DB_PASSWORD
s3cr3t-p@ssw0rd

$ kubectl -n app-config exec config-consumer -- df -h /etc/creds
Filesystem                Size      Used Available Use% Mounted on
tmpfs                    32.0M      8.0K     32.0M   0% /etc/creds
```

Two things here. The file contains the **decoded** password, so the app never
deals with base64. And the mount is a **tmpfs**, memory backed, so the secret is
never written to the node's disk and disappears when the pod does. Secret
volumes get this automatically; ConfigMap volumes do not.

---

## 3. The one that catches everyone: env vars do not update

Patching the ConfigMap while the pod keeps running:

```bash
kubectl -n app-config patch configmap app-settings --type merge \
  -p '{"data":{"LOG_LEVEL":"debug", ...}}'
```

```text
# the mounted file picked up the change:
$ kubectl -n app-config exec config-consumer -- cat /etc/app/app.properties
feature.newCheckout=true
feature.darkMode=TRUE-UPDATED
cache.ttlSeconds=900

# but the env var is still the OLD value, because env is set once at start:
$ kubectl -n app-config exec config-consumer -- sh -c 'echo LOG_LEVEL=$LOG_LEVEL'
LOG_LEVEL=info

$ kubectl -n app-config get configmap app-settings -o jsonpath='{.data.LOG_LEVEL}'
debug
```

The same ConfigMap, the same pod, the same instant: the file says `TRUE-UPDATED`
and the env var still says `info` while the ConfigMap says `debug`.

Environment variables are handed to the process at exec time and the kernel
copies them into the process. Nothing can go back and change them afterwards. A
mounted volume is a live projection the kubelet keeps syncing, on its sync loop,
so it takes up to about a minute rather than being instant.

| | Env var | Mounted file |
|---|---|---|
| Updates without a restart | no, never | yes, after the kubelet syncs |
| Good for | small, stable settings | anything you might change at runtime |
| Visible in `describe pod` | yes, including secret values | no, just the mount |
| Subpath mounts | n/a | do **not** update, this is a known trap |

The practical rule: if you change config through env vars, you must roll the
deployment for it to take effect. `kubectl rollout restart deployment/<name>` is
the usual way. If you want live reload, mount it and have the app watch the file.

This is also a real debugging trap. Someone updates a ConfigMap, sees the new
value in `kubectl get configmap`, and cannot understand why the app still
behaves the old way. The pod is not broken, env vars simply do not work that way.

---

## 4. Ingress: two apps, one entry point

Two deployments, two ClusterIP services, one Ingress routing by hostname.

```text
$ kubectl -n app-config get ingress site
NAME   CLASS   HOSTS                    ADDRESS   PORTS   AGE
site   nginx   shop.local,admin.local             80      8s

$ kubectl -n app-config describe ingress site | sed -n '1,25p'
Name:             site
Namespace:        app-config
Ingress Class:    nginx
Default backend:  <default>
Rules:
  Host         Path  Backends
  ----         ----  --------
  shop.local   
               /   shop:80 (10.244.1.32:80,10.244.2.33:80)
  admin.local  
               /   admin:80 (10.244.1.33:80)
Annotations:   nginx.ingress.kubernetes.io/rewrite-target: /
Events:
  Type    Reason  Age   From                      Message
  ----    ------  ----  ----                      -------
  Normal  Sync    8s    nginx-ingress-controller  Scheduled for sync
```

`describe` resolving the backends down to **pod IPs** is the useful part.
`shop:80 (10.244.1.32:80,10.244.2.33:80)` means the controller found the service
and its endpoints. If that bracket is empty or an error, the Ingress is pointing
at nothing, which is section 7.

The controller sends traffic to the pod IPs directly, not through the service's
ClusterIP. It watches EndpointSlices itself and load balances in nginx. So the
ClusterIP service here is mostly acting as a grouping and a name.

### Host based routing

```text
# ingress controller ClusterIP: 10.96.191.177

$ kubectl -n app-config exec config-consumer -- wget -qO- --header='Host: shop.local' http://10.96.191.177/
SHOP app, pod shop-588b6b98d5-pfztr

$ kubectl -n app-config exec config-consumer -- wget -qO- --header='Host: admin.local' http://10.96.191.177/
ADMIN app, pod admin-67d6bb595f-5xg7q

# no Host header at all: nothing matches, the default backend answers 404
$ kubectl -n app-config exec config-consumer -- wget -S -qO- http://10.96.191.177/
  HTTP/1.1 404 Not Found
```

**One IP, three different answers, decided entirely by the `Host:` header.**
That is the thing an Ingress does that a Service cannot: a Service routes on
IP and port, an Ingress reads the HTTP request. It is layer 7, so it can also
route on path, and it can terminate TLS, because it understands the protocol.

The 404 with no Host header is the default backend, not an error. Nothing
matched, so nothing was served.

---

## 5. The controller is just nginx in a pod

```text
$ kubectl -n ingress-nginx get svc ingress-nginx-controller
NAME                       TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller   NodePort   10.96.191.177   <none>        80:31280/TCP,443:31965/TCP   2m2s

$ kubectl -n ingress-nginx get pods -o wide
NAME                                        READY   STATUS      RESTARTS       AGE    IP            NODE
ingress-nginx-controller-746c8469d8-xbqkt   1/1     Running     0              2m1s   10.244.1.31   svc-lab-worker
```

And the proof that an Ingress object is not magic, read out of the controller's
own generated nginx config:

```text
$ kubectl -n ingress-nginx exec ingress-nginx-controller-746c8469d8-xbqkt -- cat /etc/nginx/nginx.conf | grep -A2 'server_name shop.local'
		server_name shop.local ;
		
		http2 on;
```

My `shop.local` rule became a literal `server_name shop.local;` block. The whole
Ingress system is: a controller watches Ingress objects, writes an nginx config,
reloads nginx. The Ingress object is the desired state, nginx.conf is the
result.

That also explains why an Ingress does nothing at all in a cluster with no
controller installed. The object is accepted and simply ignored, which is a
confusing first experience.

### Note on reaching it from the Mac

The controller service is a NodePort on `31280`, but I could not curl it from
macOS. kind runs its nodes as Docker containers, and a node port is only
reachable from the host if the cluster was created with `extraPortMappings` for
it, which mine was not. So every request above was made from a pod inside the
cluster, against the controller's ClusterIP. Same path through nginx, just
entered from inside.

Also worth recording: the kind flavour of the ingress-nginx manifest pins the
controller with `nodeSelector: ingress-ready=true`, so on my cluster it sat
`Pending` until I labelled a worker:

```bash
kubectl label node svc-lab-worker ingress-ready=true
```

A controller stuck in `Pending` with no obvious reason is worth a
`kubectl describe pod` before assuming the install failed.

---

## 6. A broken Ingress

Pointing a rule at a service that does not exist:

```text
$ kubectl -n app-config exec config-consumer -- wget -S -qO- --header='Host: broken.local' http://10.96.191.177/
  HTTP/1.1 503 Service Temporarily Unavailable

$ kubectl -n app-config describe ingress broken | sed -n '1,20p'
Rules:
  Host          Path  Backends
  ----          ----  --------
  broken.local  
                /   no-such-service:80 (<error: services "no-such-service" not found>)
```

Two useful details.

The status code is **503**, not 404. Those mean different things here and the
difference is a fast diagnosis:

| Code | Meaning | Look at |
|---|---|---|
| 404 | No rule matched the Host or path | the Ingress rules, and the `Host` header you sent |
| 503 | A rule matched, but it has no healthy backend | the service name, its selector, and its endpoints |

And the Ingress object itself was accepted without complaint. `kubectl get
ingress` lists it looking perfectly normal. Only `describe` shows
`<error: services "no-such-service" not found>`. Kubernetes does not validate
that the backend exists at admission time, because the service is allowed to be
created later.

This is the same lesson as the empty endpoints case in
[`../03_K8s_Networking_Services`](../03_K8s_Networking_Services): the object
existing and the object working are separate things, and `describe` is where the
gap shows.

---

## 7. What I took away

- base64 is not security. What protects a Secret is RBAC and etcd encryption at
  rest, not the encoding. The real reason to prefer a Secret over a ConfigMap is
  that the tooling stops printing it.
- Secret volumes are tmpfs, so credentials stay in memory and never hit the
  node's disk. ConfigMap volumes are not.
- ConfigMap and Secret volumes are symlinks into `..data/` so updates are
  atomic.
- **Mounted files update in a running pod. Environment variables never do.**
  Proven side by side above: the file said `TRUE-UPDATED` while the env var was
  still `info`.
- An Ingress routes on the HTTP `Host` header, which is why one IP served the
  shop, the admin app and a 404 depending only on that header.
- An ingress controller is an nginx deployment plus a loop that rewrites
  `nginx.conf`. Without a controller, Ingress objects do nothing.
- 404 means no rule matched. 503 means a rule matched but the backend is empty.

---

## 8. Reproducing this

```bash
kind create cluster --name svc-lab --config ../cluster/kind-cluster.yaml

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
kubectl label node svc-lab-worker ingress-ready=true
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller

cd 04_K8s_Ingress_ConfigMaps_Secrets
chmod +x verify.sh && ./verify.sh
```

## 9. Cleanup

```bash
kubectl delete namespace app-config
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
```

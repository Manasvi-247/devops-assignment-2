#!/usr/bin/env bash
# Covers the remaining four service types plus a service with no selector.
# Writes the real output to output-service-types.log.
#
# Assumes the ClusterIP lab is already applied (manifests/01-clusterip/).
#
set -u
NS=svc-lab
M=manifests
LOG=output-service-types.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "kubectl apply -f $M/01-clusterip/"
run "kubectl -n $NS rollout status deployment/hello-api --timeout=180s"

echo "" | tee -a "$LOG"
echo "===== 1. NodePort =====" | tee -a "$LOG"
run "kubectl apply -f $M/02-nodeport/service.yaml"
note "giving kube-proxy a moment to program the rules on every node"
sleep 10
run "kubectl -n $NS get svc hello-api-nodeport"
note "PORT(S) reads 9090:30080/TCP: service port 9090, node port 30080"
note "a NodePort still has a ClusterIP, it is a superset of ClusterIP:"
run "kubectl -n $NS get svc hello-api-nodeport -o jsonpath='type={.spec.type} clusterIP={.spec.clusterIP} nodePort={.spec.ports[0].nodePort}{\"\n\"}'"

note "the port is open on EVERY node, not just the ones running pods."
note "curling each node from inside its own container:"
for n in svc-lab-control-plane svc-lab-worker svc-lab-worker2; do
  run "docker exec $n curl -s -m 5 http://localhost:30080 | head -2"
done
note "and from one node to another node's IP, to prove it is not node local:"
run "docker exec svc-lab-worker curl -s -m 5 http://172.22.0.3:30080 | head -2"

note "from the Mac itself it is NOT reachable: kind runs nodes as containers"
note "and this cluster was created without extraPortMappings for 30080."
run "curl -s -m 5 http://localhost:30080 || echo 'failed as expected from the host'"

echo "" | tee -a "$LOG"
echo "===== 2. LoadBalancer =====" | tee -a "$LOG"
run "kubectl apply -f $M/03-loadbalancer/service.yaml"
sleep 5
run "kubectl -n $NS get svc hello-api-lb"
note "EXTERNAL-IP is <pending> and stays that way: no cloud controller exists"
note "on a local cluster to answer the request. on EKS/GKE/AKS this is where"
note "a real load balancer would be provisioned and its IP written back."
run "kubectl -n $NS describe svc hello-api-lb | grep -E 'Type|IP:|Port|NodePort|Endpoints|Events' "
note "the inner layers still work. the NodePort it allocated:"
run "docker exec svc-lab-worker curl -s -m 5 http://localhost:30081 | head -2"
note "and its ClusterIP:"
LBIP=$(kubectl -n $NS get svc hello-api-lb -o jsonpath='{.spec.clusterIP}')
run "kubectl -n $NS exec curl-box -- curl -s -m 5 http://$LBIP/ | head -2"

echo "" | tee -a "$LOG"
echo "===== 3. ExternalName =====" | tee -a "$LOG"
run "kubectl apply -f $M/04-externalname/service.yaml"
run "kubectl -n $NS get svc external-api legacy-db"
note "CLUSTER-IP is <none> and EXTERNAL-IP holds the target hostname"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=external-api || echo 'no endpointslices: ExternalName never has any'"
note "resolving it from a pod returns a CNAME, not a service IP:"
run "kubectl -n $NS exec curl-box -- nslookup external-api.svc-lab.svc.cluster.local"
run "kubectl -n $NS exec curl-box -- nslookup legacy-db.svc-lab.svc.cluster.local"

echo "" | tee -a "$LOG"
echo "===== 4. Headless service =====" | tee -a "$LOG"
run "kubectl apply -f $M/05-headless/statefulset.yaml"
run "kubectl -n $NS rollout status statefulset/web-stateful --timeout=300s"
run "kubectl -n $NS get pods -l app=web-stateful -o wide"
run "kubectl -n $NS get svc web-headless web-clusterip"
note "THE SIDE BY SIDE. headless returns one A record per pod:"
run "kubectl -n $NS exec curl-box -- nslookup web-headless.svc-lab.svc.cluster.local"
note "the normal ClusterIP service returns ONE virtual IP for the same pods:"
run "kubectl -n $NS exec curl-box -- nslookup web-clusterip.svc-lab.svc.cluster.local"
note "each pod also gets its own stable DNS name:"
for i in 0 1 2; do
  run "kubectl -n $NS exec curl-box -- nslookup web-stateful-$i.web-headless.svc-lab.svc.cluster.local | tail -3"
done
note "addressing one specific pod by name, which a ClusterIP cannot do."
note "NOTE the port: a headless service does no proxying, so the service port"
note "(80) is never applied and you must use the real container port (8080)."
run "kubectl -n $NS exec curl-box -- curl -s -m 5 http://web-stateful-0.web-headless:80 || echo 'exit 7: nothing listens on port 80, there is no proxy to remap it'"
run "kubectl -n $NS exec curl-box -- curl -s -m 5 http://web-stateful-0.web-headless:8080 | head -2"
note "the name is stable across deletion: delete web-stateful-0 and re-resolve"
run "kubectl -n $NS get pod web-stateful-0 -o jsonpath='before: {.status.podIP}{\"\n\"}'"
run "kubectl -n $NS delete pod web-stateful-0"
run "kubectl -n $NS wait --for=condition=Ready pod/web-stateful-0 --timeout=180s"
run "kubectl -n $NS get pod web-stateful-0 -o jsonpath='after:  {.status.podIP}{\"\n\"}'"
run "kubectl -n $NS exec curl-box -- curl -s -m 5 http://web-stateful-0.web-headless:8080 | head -2"
note "headless services DO still have endpoints, they just are not fronted by a VIP:"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=web-headless"

echo "" | tee -a "$LOG"
echo "===== 5. A Service with no selector, endpoints written by hand =====" | tee -a "$LOG"
run "kubectl apply -f $M/06-no-selector/service.yaml"
run "kubectl -n $NS get svc external-legacy-db"
run "kubectl -n $NS get svc external-legacy-db -o jsonpath='selector={.spec.selector}{\"\n\"}'"
note "the selector is empty, so nothing populates endpoints automatically."
note "the EndpointSlice applied alongside it was written by hand:"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=external-legacy-db"
run "kubectl -n $NS get endpointslice external-legacy-db-manual -o jsonpath='address={.endpoints[0].addresses[0]} port={.ports[0].port}{\"\n\"}'"
note "the in-cluster DNS name now points at infrastructure outside the cluster."
note "192.168.1.150 does not exist on this network, so a connection just times"
note "out, but the abstraction is the point: pods use one name either way."
run "kubectl -n $NS exec curl-box -- nslookup external-legacy-db.svc-lab.svc.cluster.local | tail -3"

echo "" | tee -a "$LOG"
echo "===== 6. All five types side by side =====" | tee -a "$LOG"
run "kubectl -n $NS get svc"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

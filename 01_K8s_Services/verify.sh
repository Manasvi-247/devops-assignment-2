#!/usr/bin/env bash
# Runs every check for the ClusterIP exercise and writes the real output to
# output.log, so the README can be filled in with actual terminal results.
#
#   Run it from the 01_K8s_Services folder:
#   chmod +x verify.sh && ./verify.sh
#
set -u
NS=svc-lab
SVC=hello-api-svc
LOG=output.log
: > "$LOG"

run() {
  echo ""                | tee -a "$LOG"
  echo "\$ $*"           | tee -a "$LOG"
  # shellcheck disable=SC2068
  eval "$@" 2>&1 | tee -a "$LOG"
}

echo "===== 1. Deploy =====" | tee -a "$LOG"
run "kubectl apply -f manifests/01-clusterip/00-namespace.yaml"
run "kubectl apply -f manifests/01-clusterip/"
run "kubectl -n $NS rollout status deployment/hello-api --timeout=180s"
run "kubectl -n $NS wait --for=condition=Ready pod/curl-box --timeout=180s"

echo "" | tee -a "$LOG"
echo "===== 2. What got created =====" | tee -a "$LOG"
run "kubectl -n $NS get pods -o wide"
run "kubectl -n $NS get svc $SVC"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=$SVC"

CIP=$(kubectl -n $NS get svc $SVC -o jsonpath='{.spec.clusterIP}')

echo "" | tee -a "$LOG"
echo "===== 3. Reach the service three different ways =====" | tee -a "$LOG"
run "kubectl -n $NS exec curl-box -- curl -s http://$SVC:9090"
run "kubectl -n $NS exec curl-box -- curl -s http://$CIP:9090"
run "kubectl -n $NS exec curl-box -- curl -s http://$SVC.$NS.svc.cluster.local:9090"

echo "" | tee -a "$LOG"
echo "===== 4. DNS =====" | tee -a "$LOG"
run "kubectl -n $NS exec curl-box -- cat /etc/resolv.conf"
run "kubectl -n $NS exec curl-box -- nslookup $SVC.$NS.svc.cluster.local"

echo "" | tee -a "$LOG"
echo "===== 5. Load balancing: 12 requests, count which pod answered =====" | tee -a "$LOG"
run "kubectl -n $NS exec curl-box -- sh -c 'for i in \$(seq 1 12); do curl -s http://$SVC:9090 | grep \"Server name\"; done' | sort | uniq -c"

echo "" | tee -a "$LOG"
echo "===== 6. Kill a pod: endpoints follow, the name keeps working =====" | tee -a "$LOG"
VICTIM=$(kubectl -n $NS get pods -l app=hello-api -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS delete pod $VICTIM"
run "kubectl -n $NS rollout status deployment/hello-api --timeout=120s"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=$SVC"
run "kubectl -n $NS exec curl-box -- curl -s -o /dev/null -w 'HTTP %{http_code}\\n' http://$SVC:9090"

echo "" | tee -a "$LOG"
echo "===== 7. Scale to 0: no endpoints, connection refused =====" | tee -a "$LOG"
run "kubectl -n $NS scale deployment/hello-api --replicas=0"
sleep 6
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=$SVC"
run "kubectl -n $NS exec curl-box -- curl -s -m 5 -o /dev/null -w 'exit=%{exitcode} http=%{http_code}\\n' http://$SVC:9090"
run "kubectl -n $NS scale deployment/hello-api --replicas=3"
run "kubectl -n $NS rollout status deployment/hello-api --timeout=120s"

echo "" | tee -a "$LOG"
echo "===== 8. ClusterIP is namespace-scoped and cluster-internal =====" | tee -a "$LOG"
run "kubectl -n default run tmp-client --rm -i --restart=Never --image=curlimages/curl:8.7.1 -- curl -s -m 5 http://$SVC:9090"
run "kubectl -n default run tmp-client2 --rm -i --restart=Never --image=curlimages/curl:8.7.1 -- curl -s -m 5 http://$SVC.$NS.svc.cluster.local:9090"
echo "" | tee -a "$LOG"
echo "# From the laptop itself (outside the cluster) the ClusterIP is unreachable:" | tee -a "$LOG"
run "curl -s -m 5 http://$CIP:9090 || echo 'failed as expected - ClusterIP is not routable from outside'"

echo "" | tee -a "$LOG"
echo "===== 9. Labels and selector: why these pods and not the client =====" | tee -a "$LOG"
run "kubectl -n $NS get pods --show-labels"
run "kubectl -n $NS get svc $SVC -o jsonpath='{.spec.selector}'"
run "kubectl -n $NS describe svc $SVC"

echo "" | tee -a "$LOG"
echo "===== 10. port-forward: the debugging tunnel =====" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "\$ kubectl -n $NS port-forward svc/$SVC 9090:9090 &" | tee -a "$LOG"
kubectl -n $NS port-forward svc/$SVC 9090:9090 > /tmp/pf.$$.log 2>&1 &
PF=$!
for _ in $(seq 1 20); do grep -q "Forwarding from" /tmp/pf.$$.log 2>/dev/null && break; sleep 0.5; done
cat /tmp/pf.$$.log | tee -a "$LOG"
run "curl -s -m 5 http://localhost:9090"
kill $PF 2>/dev/null; wait $PF 2>/dev/null; rm -f /tmp/pf.$$.log

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

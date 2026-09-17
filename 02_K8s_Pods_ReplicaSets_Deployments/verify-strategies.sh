#!/usr/bin/env bash
# Runs the blue-green, canary and recreate deployment strategies and writes the
# real output to output-strategies.log. The recreate section captures the
# deliberate outage window with a live curl loop.
#
#   chmod +x verify-strategies.sh && ./verify-strategies.sh
#
set -u
NS=strategies
M=manifests/strategies
LOG=output-strategies.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "kubectl apply -f $M/00-namespace.yaml"
run "kubectl apply -f $M/client.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/loadgen --timeout=180s"

############################################################
echo "" | tee -a "$LOG"
echo "===== A. BLUE-GREEN: two full environments, instant selector cutover =====" | tee -a "$LOG"
run "kubectl apply -f $M/bg-deployment-blue.yaml -f $M/bg-deployment-green.yaml"
run "kubectl -n $NS rollout status deployment/app-blue --timeout=180s"
run "kubectl -n $NS rollout status deployment/app-green --timeout=180s"
note "both environments are live at once, 6 pods total:"
run "kubectl -n $NS get pods -l app=myapp --show-labels --no-headers | sort"

note "route live traffic to BLUE"
run "kubectl apply -f $M/bg-service-blue.yaml"
sleep 4
run "kubectl -n $NS describe svc myapp-service | grep -E 'Selector|Endpoints'"
run "kubectl -n $NS exec loadgen -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://myapp-service/; done' | sort | uniq -c"

note "THE SWITCH: flip the service selector to GREEN"
run "kubectl apply -f $M/bg-service-green.yaml"
sleep 4
run "kubectl -n $NS describe svc myapp-service | grep -E 'Selector|Endpoints'"
run "kubectl -n $NS exec loadgen -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://myapp-service/; done' | sort | uniq -c"

note "instant rollback: flip the selector back to BLUE"
run "kubectl apply -f $M/bg-service-blue.yaml"
sleep 4
run "kubectl -n $NS exec loadgen -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://myapp-service/; done' | sort | uniq -c"
run "kubectl delete -f $M/bg-service-blue.yaml -f $M/bg-deployment-blue.yaml -f $M/bg-deployment-green.yaml"

############################################################
echo "" | tee -a "$LOG"
echo "===== B. CANARY: one service, two tracks, ratio decides the split =====" | tee -a "$LOG"
run "kubectl apply -f $M/canary-deployment-stable.yaml -f $M/canary-service.yaml"
run "kubectl -n $NS rollout status deployment/app-stable --timeout=180s"
run "kubectl apply -f $M/canary-deployment-canary.yaml"
run "kubectl -n $NS rollout status deployment/app-canary --timeout=180s"
note "9 stable + 1 canary = 10 pods behind ONE service"
run "kubectl -n $NS get deploy app-stable app-canary"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=myapp-canary-service -o jsonpath='{.items[0].endpoints[*].addresses[0]}{\"\n\"}' | tr ' ' '\n' | wc -l"
note "100 requests, expect roughly 10 percent canary:"
run "kubectl -n $NS exec loadgen -- sh -c 'for i in \$(seq 1 100); do curl -s http://myapp-canary-service/; done' | sort | uniq -c"

note "shift the split to 30 percent: canary 3, stable 7"
run "kubectl -n $NS scale deployment app-canary --replicas=3"
run "kubectl -n $NS scale deployment app-stable --replicas=7"
run "kubectl -n $NS rollout status deployment/app-canary --timeout=180s"
run "kubectl -n $NS rollout status deployment/app-stable --timeout=180s"
sleep 5
run "kubectl -n $NS exec loadgen -- sh -c 'for i in \$(seq 1 100); do curl -s http://myapp-canary-service/; done' | sort | uniq -c"

note "abort the canary: scale it to 0, stable back to 9"
run "kubectl -n $NS scale deployment app-canary --replicas=0"
run "kubectl -n $NS scale deployment app-stable --replicas=9"
run "kubectl -n $NS rollout status deployment/app-stable --timeout=180s"
sleep 5
run "kubectl -n $NS exec loadgen -- sh -c 'for i in \$(seq 1 20); do curl -s http://myapp-canary-service/; done' | sort | uniq -c"
run "kubectl delete -f $M/canary-service.yaml -f $M/canary-deployment-canary.yaml -f $M/canary-deployment-stable.yaml"

############################################################
echo "" | tee -a "$LOG"
echo "===== C. RECREATE: all old pods die before any new pod starts =====" | tee -a "$LOG"
run "kubectl apply -f $M/recreate-deployment-v1.yaml -f $M/recreate-service.yaml"
run "kubectl -n $NS rollout status deployment/app-recreate --timeout=180s"
run "kubectl -n $NS get pods -l app=app-recreate --no-headers"

note "starting a continuous curl loop in the client pod, then applying v2."
note "each line is one request, half a second apart. OUTAGE means no backend answered."
kubectl -n $NS exec loadgen -- sh -c \
  'for i in $(seq 1 60); do curl -s -m 1 http://app-recreate-svc/ || echo "[OUTAGE] connection refused / 0 pods alive"; sleep 0.5; done' \
  > /tmp/recreate.$$.log 2>&1 &
LOOP=$!
sleep 3
kubectl apply -f $M/recreate-deployment-v2.yaml >/dev/null 2>&1
kubectl -n $NS rollout status deployment/app-recreate --timeout=180s >/dev/null 2>&1
wait $LOOP 2>/dev/null

echo "" | tee -a "$LOG"
echo "\$ for i in \$(seq 1 60); do curl -s -m 1 http://app-recreate-svc/ || echo '[OUTAGE] ...'; sleep 0.5; done" | tee -a "$LOG"
cat /tmp/recreate.$$.log | uniq -c | tee -a "$LOG"
OUT=$(grep -c OUTAGE /tmp/recreate.$$.log || true)
echo "" | tee -a "$LOG"
echo "# $OUT of 60 requests failed. At ~0.5s per request that is roughly $(echo "$OUT" | awk '{printf "%.1f", $1*0.5}') seconds of downtime." | tee -a "$LOG"
rm -f /tmp/recreate.$$.log

run "kubectl -n $NS get pods -l app=app-recreate --no-headers"
run "kubectl -n $NS rollout history deployment/app-recreate"
run "kubectl -n $NS rollout undo deployment/app-recreate"
run "kubectl -n $NS rollout status deployment/app-recreate --timeout=180s"
run "kubectl -n $NS exec loadgen -- curl -s http://app-recreate-svc/"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

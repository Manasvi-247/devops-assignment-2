#!/usr/bin/env bash
# Troubleshooting drills. Each one breaks something on purpose, diagnoses it
# with the standard commands, then fixes it. Writes the real output to
# output.log.
#
set -u
NS=triage
M=manifests
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "kubectl apply -f $M/00-namespace.yaml"
run "kubectl apply -f $M/01-healthy-app.yaml -f $M/07-client.yaml"
run "kubectl -n $NS rollout status deployment/shop --timeout=180s"
run "kubectl -n $NS wait --for=condition=Ready pod/triage-client --timeout=180s"

echo "" | tee -a "$LOG"
echo "===== 1. kubectl get: the first look =====" | tee -a "$LOG"
run "kubectl -n $NS get pods"
run "kubectl -n $NS get pods -o wide"
note "wide adds IP and NODE, which is what you need when one replica misbehaves"
run "kubectl -n $NS get all"

echo "" | tee -a "$LOG"
echo "===== 2. kubectl describe: spec, status and events in one place =====" | tee -a "$LOG"
POD=$(kubectl -n $NS get pods -l app=shop -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS describe pod $POD | sed -n '1,20p'"
note "the Events block at the bottom is the part that actually explains failures"
run "kubectl -n $NS describe pod $POD | sed -n '/Events:/,\$p'"

echo "" | tee -a "$LOG"
echo "===== 3. kubectl logs: what the application said =====" | tee -a "$LOG"
run "kubectl -n $NS logs $POD --tail=5"
run "kubectl -n $NS logs -l app=shop --tail=3 --prefix"

echo "" | tee -a "$LOG"
echo "===== 4. kubectl exec: look from inside the container =====" | tee -a "$LOG"
run "kubectl -n $NS exec $POD -- hostname -i"
run "kubectl -n $NS exec $POD -- ls /etc/nginx"
note "a request from inside the cluster, through the service:"
run "kubectl -n $NS exec triage-client -- curl -s http://shop/ | head -2"

echo "" | tee -a "$LOG"
echo "===== 5. Events: the cluster's own timeline =====" | tee -a "$LOG"
run "kubectl -n $NS get events --sort-by=.lastTimestamp | tail -12"

echo "" | tee -a "$LOG"
echo "===== 6. Drill: CrashLoopBackOff =====" | tee -a "$LOG"
run "kubectl apply -f $M/02-crashloop.yaml"
note "step 1, the symptom"
for i in 1 2 3 4 5 6; do
  sleep 15
  run "kubectl -n $NS get pod broken-crashloop --no-headers"
  kubectl -n $NS get pod broken-crashloop -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -q CrashLoopBackOff && break
done
note "step 2, the logs say exactly why. --previous reads the crashed instance"
run "kubectl -n $NS logs broken-crashloop --previous"
note "step 3, confirm with describe"
run "kubectl -n $NS describe pod broken-crashloop | grep -E 'Reason|Exit Code|Restart Count' | head -4"
run "kubectl -n $NS delete pod broken-crashloop"

echo "" | tee -a "$LOG"
echo "===== 7. Drill: ImagePullBackOff, a typo in the tag =====" | tee -a "$LOG"
run "kubectl apply -f $M/03-imagepull.yaml"
sleep 20
run "kubectl -n $NS get pod broken-image --no-headers"
note "logs are useless here, there is no container to read from:"
run "kubectl -n $NS logs broken-image 2>&1 | head -2"
note "describe is where the answer is:"
run "kubectl -n $NS describe pod broken-image | grep -A4 'Events:' | tail -3"
note "the fix: alpne -> alpine"
run "kubectl -n $NS delete pod broken-image"
run "kubectl apply -f $M/03-imagepull-fixed.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/broken-image --timeout=180s"
run "kubectl -n $NS get pod broken-image --no-headers"

echo "" | tee -a "$LOG"
echo "===== 8. Drill: Pending, nothing can schedule it =====" | tee -a "$LOG"
run "kubectl apply -f $M/04-pending.yaml"
sleep 10
run "kubectl -n $NS get pod broken-pending --no-headers"
run "kubectl -n $NS describe pod broken-pending | grep -A4 'Events:'"
note "the fix: ask for an amount a node actually has"
run "kubectl -n $NS delete pod broken-pending"
run "kubectl apply -f $M/04-pending-fixed.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/broken-pending --timeout=180s"
run "kubectl -n $NS get pod broken-pending -o wide --no-headers"

echo "" | tee -a "$LOG"
echo "===== 9. Drill: OOMKilled =====" | tee -a "$LOG"
run "kubectl apply -f $M/08-oomkilled.yaml"
sleep 25
run "kubectl -n $NS get pod broken-oom --no-headers"
run "kubectl -n $NS get pod broken-oom -o jsonpath='reason={.status.containerStatuses[0].lastState.terminated.reason} exitCode={.status.containerStatuses[0].lastState.terminated.exitCode}{\"\n\"}'"
note "it asked for 200M with a 64Mi limit. the kernel killed it, exit 137"
run "kubectl -n $NS delete pod broken-oom"

echo "" | tee -a "$LOG"
echo "===== 10. Drill: service with no endpoints =====" | tee -a "$LOG"
run "kubectl apply -f $M/05-broken-service.yaml"
sleep 5
note "the service exists and looks fine"
run "kubectl -n $NS get svc shop-broken"
note "DNS resolves, so this is not a DNS problem"
run "kubectl -n $NS exec triage-client -- nslookup shop-broken.triage.svc.cluster.local | tail -3"
note "but the request fails immediately"
run "kubectl -n $NS exec triage-client -- sh -c 'curl -s -m 5 http://shop-broken/ ; echo exit=\$?'"
note "the smoking gun: no endpoints"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=shop-broken"
note "compare the selector with the pod labels"
run "kubectl -n $NS get svc shop-broken -o jsonpath='selector: {.spec.selector}{\"\n\"}'"
run "kubectl -n $NS get pods -l app=shop --show-labels --no-headers"
note "tier=api vs tier=web. the fix:"
run "kubectl apply -f $M/05-broken-service-fixed.yaml"
sleep 5
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=shop-broken"
run "kubectl -n $NS exec triage-client -- curl -s http://shop-broken/ | head -2"

echo "" | tee -a "$LOG"
echo "===== 11. Drill: endpoints exist but the port is wrong =====" | tee -a "$LOG"
run "kubectl apply -f $M/06-wrong-targetport.yaml"
sleep 5
note "endpoints are present, so the selector is fine"
run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=shop-wrongport"
note "yet it still fails, and with the SAME exit 7 as the empty service."
note "the pod is reachable and actively refuses on a closed port, so curl"
note "gets a reset rather than a timeout. the exit code alone cannot tell"
note "these two faults apart, which is why you check the endpoint list."
run "kubectl -n $NS exec triage-client -- sh -c 'curl -s -m 5 http://shop-wrongport/ ; echo exit=\$?'"
note "targetPort 9999, container listens on 8080"
run "kubectl -n $NS get svc shop-wrongport -o jsonpath='targetPort={.spec.ports[0].targetPort}{\"\n\"}'"
run "kubectl -n $NS get deploy shop -o jsonpath='containerPort={.spec.template.spec.containers[0].ports[0].containerPort}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 12. Final state =====" | tee -a "$LOG"
run "kubectl -n $NS get pods"
run "kubectl -n $NS get svc"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

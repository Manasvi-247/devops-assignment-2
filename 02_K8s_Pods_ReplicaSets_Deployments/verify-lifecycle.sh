#!/usr/bin/env bash
# Exercises all 12 pod lifecycle manifests and writes the real output to
# output-lifecycle.log.
#
#   chmod +x verify-lifecycle.sh && ./verify-lifecycle.sh
#
set -u
NS=lifecycle
M=manifests/pod-lifecycle
LOG=output-lifecycle.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "kubectl apply -f $M/00-namespace.yaml"

echo "" | tee -a "$LOG"
echo "===== 1. Running =====" | tee -a "$LOG"
run "kubectl apply -f $M/01-running.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/lifecycle-running --timeout=120s"
run "kubectl -n $NS get pod lifecycle-running -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount"

echo "" | tee -a "$LOG"
echo "===== 2. Pending: unschedulable, nothing has 900Gi =====" | tee -a "$LOG"
run "kubectl apply -f $M/02-pending.yaml"
sleep 8
run "kubectl -n $NS get pod lifecycle-pending"
run "kubectl -n $NS describe pod lifecycle-pending | grep -A6 'Events:'"

echo "" | tee -a "$LOG"
echo "===== 3. Succeeded: exit 0, restartPolicy Never =====" | tee -a "$LOG"
run "kubectl apply -f $M/03-succeeded.yaml"
sleep 10
run "kubectl -n $NS get pod lifecycle-succeeded"
run "kubectl -n $NS logs lifecycle-succeeded"
run "kubectl -n $NS get pod lifecycle-succeeded -o jsonpath='{.status.phase} exitCode={.status.containerStatuses[0].state.terminated.exitCode}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 4. Failed: exit 1, restartPolicy Never =====" | tee -a "$LOG"
run "kubectl apply -f $M/04-failed.yaml"
sleep 10
run "kubectl -n $NS get pod lifecycle-failed"
run "kubectl -n $NS get pod lifecycle-failed -o jsonpath='{.status.phase} exitCode={.status.containerStatuses[0].state.terminated.exitCode} reason={.status.containerStatuses[0].state.terminated.reason}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 5. CrashLoopBackOff: exit 1 with restartPolicy Always =====" | tee -a "$LOG"
run "kubectl apply -f $M/05-crashloopbackoff.yaml"
note "polling to watch RESTARTS climb and the backoff grow"
note "CrashLoopBackOff only shows once the backoff is long enough that the pod"
note "is waiting rather than running, so this polls well past the first crashes"
for i in $(seq 1 12); do
  sleep 20
  run "kubectl -n $NS get pod lifecycle-crashloop --no-headers"
  if kubectl -n $NS get pod lifecycle-crashloop -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -q CrashLoopBackOff; then
    run "kubectl -n $NS get pod lifecycle-crashloop -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}: {.status.containerStatuses[0].state.waiting.message}{\"\n\"}'"
    break
  fi
done
run "kubectl -n $NS logs lifecycle-crashloop --previous || (sleep 15; kubectl -n $NS logs lifecycle-crashloop --previous)"
run "kubectl -n $NS describe pod lifecycle-crashloop | grep -A6 'Events:' | tail -5"

echo "" | tee -a "$LOG"
echo "===== 6. ErrImagePull -> ImagePullBackOff =====" | tee -a "$LOG"
run "kubectl apply -f $M/06-imagepullbackoff.yaml"
sleep 6
run "kubectl -n $NS get pod lifecycle-image-error"
sleep 20
note "a few seconds later the state moves from ErrImagePull to ImagePullBackOff"
run "kubectl -n $NS get pod lifecycle-image-error"
run "kubectl -n $NS describe pod lifecycle-image-error | grep -A8 'Events:'"
note "the API object exists in etcd even though no container could ever run:"
run "kubectl -n $NS get pod lifecycle-image-error -o jsonpath='{.metadata.uid}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 7. Readiness probe: Running is not the same as Ready =====" | tee -a "$LOG"
run "kubectl apply -f $M/07-readiness.yaml"
note "polling: PHASE goes Running immediately, READY stays false for ~20s"
for i in 1 2 3 4 5 6; do
  sleep 5
  run "kubectl -n $NS get pod lifecycle-readiness -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready --no-headers"
done

echo "" | tee -a "$LOG"
echo "===== 8. Liveness probe: automated restart =====" | tee -a "$LOG"
run "kubectl apply -f $M/08-liveness.yaml"
note "the app deletes its own health file after 15s, probe then fails 3 times"
for i in 1 2 3 4 5 6 7; do
  sleep 8
  run "kubectl -n $NS get pod lifecycle-liveness --no-headers"
done
run "kubectl -n $NS describe pod lifecycle-liveness | grep -A8 'Events:' | tail -6"

echo "" | tee -a "$LOG"
echo "===== 9. Startup probe: protects a slow boot =====" | tee -a "$LOG"
run "kubectl apply -f $M/09-startup.yaml"
note "liveness is aggressive (failureThreshold 1) but is held off until startup succeeds"
for i in 1 2 3 4 5 6 7; do
  sleep 6
  run "kubectl -n $NS get pod lifecycle-startup --no-headers"
done
note "RESTARTS stayed 0: without the startup probe the liveness probe would have killed it"

echo "" | tee -a "$LOG"
echo "===== 10. Init container: runs to completion first =====" | tee -a "$LOG"
run "kubectl apply -f $M/10-init-container.yaml"
note "status shows Init:0/1 while the init container works"
for i in 1 2 3; do
  sleep 5
  run "kubectl -n $NS get pod lifecycle-init --no-headers"
done
run "kubectl -n $NS wait --for=condition=Ready pod/lifecycle-init --timeout=120s"
run "kubectl -n $NS logs lifecycle-init -c setup"
run "kubectl -n $NS logs lifecycle-init -c app"
run "kubectl -n $NS describe pod lifecycle-init | grep -A8 'Init Containers:'"

echo "" | tee -a "$LOG"
echo "===== 11. Multi container pod: 2/2 ready, sidecar reads the app's log =====" | tee -a "$LOG"
run "kubectl apply -f $M/11-multi-container.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/lifecycle-multi-container --timeout=120s"
sleep 12
run "kubectl -n $NS get pod lifecycle-multi-container"
run "kubectl -n $NS logs lifecycle-multi-container -c sidecar --tail=4"

echo "" | tee -a "$LOG"
echo "===== 12. Graceful termination: SIGTERM trap and the grace period =====" | tee -a "$LOG"
run "kubectl apply -f $M/12-termination.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/lifecycle-termination --timeout=120s"
run "kubectl -n $NS logs lifecycle-termination"
note "timing the delete, streaming the log so the SIGTERM handler is captured"
kubectl -n $NS logs -f lifecycle-termination > /tmp/term.$$.log 2>&1 &
TAIL=$!
sleep 1
START=$(date +%s)
kubectl -n $NS delete pod lifecycle-termination 2>&1 | tee -a "$LOG"
END=$(date +%s)
kill $TAIL 2>/dev/null; wait $TAIL 2>/dev/null
echo "" | tee -a "$LOG"
echo "\$ kubectl -n $NS logs -f lifecycle-termination   # streamed during the delete" | tee -a "$LOG"
cat /tmp/term.$$.log | tee -a "$LOG"
rm -f /tmp/term.$$.log
echo "# delete took $((END-START)) seconds: the 10s drain, then exit" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "===== Summary of every state produced =====" | tee -a "$LOG"
run "kubectl -n $NS get pods -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,REASON:.status.containerStatuses[0].state.waiting.reason"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

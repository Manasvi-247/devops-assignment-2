#!/usr/bin/env bash
# Transient pod phases, StatefulSet ordinals and PVCs, and the immutable
# selector rejection. Writes the real output to output-extras.log.
#
#   chmod +x verify-extras.sh && ./verify-extras.sh
#
set -u
NS=workloads
M=manifests
LOG=output-extras.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "kubectl apply -f $M/00-namespace.yaml"

echo "" | tee -a "$LOG"
echo "===== 1. Transient phases: ContainerCreating -> Running -> Completed =====" | tee -a "$LOG"
kubectl -n $NS delete pod hello-pod --ignore-not-found >/dev/null 2>&1
note "watching in the background, then applying, so the transitions are captured"
kubectl -n $NS get pods -w --no-headers > /tmp/watch.$$.log 2>&1 &
W=$!
sleep 1
run "kubectl apply -f $M/hello.yaml"
sleep 25
kill $W 2>/dev/null; wait $W 2>/dev/null
echo "" | tee -a "$LOG"
echo "\$ kubectl -n $NS get pods -w        # streamed while the pod ran" | tee -a "$LOG"
grep hello-pod /tmp/watch.$$.log | tee -a "$LOG"
rm -f /tmp/watch.$$.log
run "kubectl -n $NS get pod hello-pod"
run "kubectl -n $NS logs hello-pod"
run "kubectl -n $NS get pod hello-pod -o jsonpath='phase={.status.phase} exitCode={.status.containerStatuses[0].state.terminated.exitCode} reason={.status.containerStatuses[0].state.terminated.reason}{\"\n\"}'"
run "kubectl -n $NS delete -f $M/hello.yaml"

echo "" | tee -a "$LOG"
echo "===== 2. StatefulSet: ordinal names, stable identity, one PVC each =====" | tee -a "$LOG"
run "kubectl apply -f $M/06-statefulset.yaml"
note "pods are created strictly in order, 0 then 1 then 2, each waiting for the last"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 20
  READY=$(kubectl -n $NS get statefulset mysql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  run "kubectl -n $NS get pods -l app=mysql --no-headers"
  [ "${READY:-0}" = "3" ] && break
done
run "kubectl -n $NS get statefulset mysql"
note "each pod has its own PersistentVolumeClaim, named <claim>-<pod>:"
run "kubectl -n $NS get pvc -l app=mysql"
note "stable network identity: one DNS name per pod via the headless service"
run "kubectl -n $NS get svc mysql"

note "identity drill: delete mysql-1 and watch the SAME name come back"
run "kubectl -n $NS get pod mysql-1 -o jsonpath='before: name={.metadata.name} uid={.metadata.uid} node={.spec.nodeName}{\"\n\"}'"
run "kubectl -n $NS delete pod mysql-1"
sleep 25
run "kubectl -n $NS get pod mysql-1 -o jsonpath='after:  name={.metadata.name} uid={.metadata.uid} node={.spec.nodeName}{\"\n\"}'"
note "and the PVC is unchanged, so the new pod reattaches the same disk:"
run "kubectl -n $NS get pvc data-mysql-1"

note "contrast with a Deployment: delete a pod and the replacement gets a NEW name"
run "kubectl -n $NS get pods -l app=web --no-headers | head -1"
DPOD=$(kubectl -n $NS get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS delete pod $DPOD"
sleep 10
run "kubectl -n $NS get pods -l app=web --no-headers"

echo "" | tee -a "$LOG"
echo "===== 3. Immutable selector: the API server rejects a mismatch =====" | tee -a "$LOG"
note "selector says app=frontend, the pod template says app=backend"
run "kubectl apply -f $M/07-selector-mismatch.yaml || true"
note "the fix is to make the template labels match the selector"
run "kubectl apply -f $M/08-selector-fixed.yaml"
run "kubectl -n $NS rollout status deployment/selector-error-demo --timeout=120s"
run "kubectl -n $NS get pods -l app=frontend --no-headers"
note "the selector itself is immutable once set. changing it on a live deployment:"
run "kubectl -n $NS patch deployment selector-error-demo --type merge -p '{\"spec\":{\"selector\":{\"matchLabels\":{\"app\":\"changed\"}}}}' || true"
run "kubectl -n $NS delete -f $M/08-selector-fixed.yaml"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

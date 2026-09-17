#!/usr/bin/env bash
# Runs every check for the pods / replicasets / deployments exercise and writes
# the real output to output.log.
#
#   chmod +x verify.sh && ./verify.sh
#
set -u
NS=workloads
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}

run "kubectl apply -f manifests/00-namespace.yaml"

echo "" | tee -a "$LOG"
echo "===== 1. ReplicaSet: keeps N pods alive =====" | tee -a "$LOG"
run "kubectl apply -f manifests/01-replicaset.yaml"
sleep 8
run "kubectl -n $NS get rs web-rs"
run "kubectl -n $NS get pods -l app=web-rs -o wide"
echo "# every pod is owned by the replicaset:" | tee -a "$LOG"
run "kubectl -n $NS get pods -l app=web-rs -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind"

echo "" | tee -a "$LOG"
echo "===== 2. Delete a pod: the replicaset replaces it =====" | tee -a "$LOG"
VICTIM=$(kubectl -n $NS get pods -l app=web-rs -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS delete pod $VICTIM"
sleep 6
run "kubectl -n $NS get pods -l app=web-rs"

echo "" | tee -a "$LOG"
echo "===== 3. Scaling a replicaset =====" | tee -a "$LOG"
run "kubectl -n $NS scale rs/web-rs --replicas=5"
sleep 6
run "kubectl -n $NS get rs web-rs"
run "kubectl -n $NS delete rs web-rs"

echo "" | tee -a "$LOG"
echo "===== 4. Deployment: a controller that manages replicasets =====" | tee -a "$LOG"
run "kubectl apply -f manifests/02-deployment-v1.yaml"
run "kubectl -n $NS rollout status deployment/web --timeout=180s"
run "kubectl -n $NS get deployment web"
run "kubectl -n $NS get rs -l app=web"
run "kubectl -n $NS get pods -l app=web -o wide"
echo "# ownership chain: deployment -> replicaset -> pod" | tee -a "$LOG"
run "kubectl -n $NS get pods -l app=web -o custom-columns=POD:.metadata.name,OWNER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind | head -3"
run "kubectl -n $NS get rs -l app=web -o custom-columns=RS:.metadata.name,OWNER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind"

echo "" | tee -a "$LOG"
echo "===== 5. Rolling update to v2 =====" | tee -a "$LOG"
run "kubectl apply -f manifests/03-deployment-v2.yaml"
run "kubectl -n $NS rollout status deployment/web --timeout=180s"
echo "# two replicasets now: the old one scaled to 0, the new one at 4" | tee -a "$LOG"
run "kubectl -n $NS get rs -l app=web"
run "kubectl -n $NS get pods -l app=web -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,VERSION:.metadata.labels.version"
run "kubectl -n $NS rollout history deployment/web"

echo "" | tee -a "$LOG"
echo "===== 6. A rollout that fails: bad image tag =====" | tee -a "$LOG"
run "kubectl apply -f manifests/04-deployment-broken.yaml"
sleep 20
run "kubectl -n $NS rollout status deployment/web --timeout=20s || true"
run "kubectl -n $NS get pods -l app=web"
run "kubectl -n $NS get deployment web"
echo "# the old pods are still serving. maxUnavailable=1 protected them:" | tee -a "$LOG"
run "kubectl -n $NS get pods -l app=web -o custom-columns=POD:.metadata.name,VERSION:.metadata.labels.version,STATUS:.status.phase,READY:.status.containerStatuses[0].ready"

echo "" | tee -a "$LOG"
echo "===== 7. Rollback =====" | tee -a "$LOG"
run "kubectl -n $NS rollout undo deployment/web"
run "kubectl -n $NS rollout status deployment/web --timeout=180s"
run "kubectl -n $NS get pods -l app=web -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,VERSION:.metadata.labels.version"
run "kubectl -n $NS rollout history deployment/web"

echo "" | tee -a "$LOG"
echo "===== 8. DaemonSet: exactly one pod per worker node =====" | tee -a "$LOG"
run "kubectl apply -f manifests/05-daemonset.yaml"
run "kubectl -n $NS rollout status daemonset/node-agent --timeout=180s"
run "kubectl -n $NS get daemonset node-agent"
run "kubectl -n $NS get pods -l app=node-agent -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName"
echo "# for comparison, the nodes in the cluster:" | tee -a "$LOG"
run "kubectl get nodes"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

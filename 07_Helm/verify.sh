#!/usr/bin/env bash
# Helm: chart structure, templating, install, upgrade, rollback and history.
# Writes the real output to output.log.
#
set -u
NS=helm-lab
REL=notes
C=notes-chart
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "helm version --short"
run "kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -"

echo "" | tee -a "$LOG"
echo "===== 1. Chart structure =====" | tee -a "$LOG"
run "find $C -type f | sort"
run "cat $C/Chart.yaml"
note "lint before anything is installed"
run "helm lint $C"

echo "" | tee -a "$LOG"
echo "===== 2. Templating: values in, manifests out =====" | tee -a "$LOG"
note "render locally without touching the cluster"
run "helm template $REL $C | head -40"
note "the same template with the production overlay, showing only what changed"
run "diff <(helm template $REL $C) <(helm template $REL $C -f $C/values-prod.yaml) | head -30"

echo "" | tee -a "$LOG"
echo "===== 3. Install =====" | tee -a "$LOG"
run "helm install $REL $C -n $NS --wait --timeout 5m"
run "helm list -n $NS"
run "kubectl -n $NS get deploy,svc,pods"
note "the release is stored in the cluster as a secret, not in a local file:"
run "kubectl -n $NS get secret -l owner=helm"

echo "" | tee -a "$LOG"
echo "===== 4. Values: what the release was rendered with =====" | tee -a "$LOG"
run "helm get values $REL -n $NS"
run "helm get values $REL -n $NS --all | head -25"

echo "" | tee -a "$LOG"
echo "===== 5. Upgrade: scale up and switch to the production overlay =====" | tee -a "$LOG"
run "helm upgrade $REL $C -n $NS -f $C/values-prod.yaml --wait --timeout 5m"
run "helm list -n $NS"
run "kubectl -n $NS get deploy -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas"
run "kubectl -n $NS get pods --no-headers"
note "the env var changed too, not just the replica count:"
run "kubectl -n $NS rollout status deployment/$REL-$C --timeout=180s"
POD=$(kubectl -n $NS get pods -l app.kubernetes.io/instance=$REL --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS exec $POD -- sh -c 'echo APP_ENV=\$APP_ENV; echo BANNER=\$BANNER'"

echo "" | tee -a "$LOG"
echo "===== 6. Upgrade again, with a single --set override =====" | tee -a "$LOG"
run "helm upgrade $REL $C -n $NS -f $C/values-prod.yaml --set replicaCount=3 --wait --timeout 5m"
run "kubectl -n $NS get deploy -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas"

echo "" | tee -a "$LOG"
echo "===== 7. History and rollback =====" | tee -a "$LOG"
run "helm history $REL -n $NS"
note "roll back to revision 1, the original development values"
run "helm rollback $REL 1 -n $NS --wait --timeout 5m"
run "helm history $REL -n $NS"
run "kubectl -n $NS get deploy -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas"
run "kubectl -n $NS rollout status deployment/$REL-$C --timeout=180s"
POD=$(kubectl -n $NS get pods -l app.kubernetes.io/instance=$REL --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS exec $POD -- sh -c 'echo APP_ENV=\$APP_ENV; echo BANNER=\$BANNER'"
note "back to the development values, so the rollback really changed the pods"
note "rollback is recorded as a NEW revision, it does not erase history"

echo "" | tee -a "$LOG"
echo "===== 8. Package and inspect =====" | tee -a "$LOG"
run "helm package $C -d /tmp"
run "helm show chart $C"

echo "" | tee -a "$LOG"
echo "===== 9. Uninstall =====" | tee -a "$LOG"
run "helm uninstall $REL -n $NS --wait"
run "helm list -n $NS"
run "kubectl -n $NS get all"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

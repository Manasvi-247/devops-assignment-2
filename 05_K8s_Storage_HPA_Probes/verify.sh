#!/usr/bin/env bash
# Storage, HPA and probes. Writes the real output to output.log.
#
#   chmod +x verify.sh && ./verify.sh
#
# Needs metrics-server for the HPA section:
#   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
#   kubectl -n kube-system patch deployment metrics-server --type=json \
#     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
#
set -u
NS=storage-lab
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

echo "" | tee -a "$LOG"
echo "===== 1. emptyDir: shared between containers, dies with the pod =====" | tee -a "$LOG"
run "kubectl apply -f $M/01-emptydir.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/vol-emptydir --timeout=120s"
note "the reader sees what the writer wrote:"
run "kubectl -n $NS exec vol-emptydir -c reader -- cat /scratch/note.txt"
note "delete the pod and the data is gone with it"
run "kubectl -n $NS delete pod vol-emptydir"

echo "" | tee -a "$LOG"
echo "===== 2. Static PV and PVC: the binding =====" | tee -a "$LOG"
run "kubectl apply -f $M/02-pv.yaml"
note "Available, because no claim has bound to it yet:"
run "kubectl get pv static-pv"
run "kubectl apply -f $M/03-pvc.yaml"
sleep 4
note "now Bound, and the PV records which claim took it:"
run "kubectl get pv static-pv"
run "kubectl -n $NS get pvc static-pvc"

echo "" | tee -a "$LOG"
echo "===== 3. Data outlives the pod =====" | tee -a "$LOG"
note "clearing the host directory first, so this run starts from empty"
for n in svc-lab-worker svc-lab-worker2; do docker exec "$n" rm -rf /mnt/static-pv >/dev/null 2>&1; done
run "kubectl apply -f $M/04-pod-static.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/static-writer --timeout=120s"
run "kubectl -n $NS exec static-writer -- cat /data/log.txt"
note "delete the pod, recreate it, and read the file again"
run "kubectl -n $NS delete pod static-writer"
run "kubectl apply -f $M/04-pod-static.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/static-writer --timeout=120s"
note "the earlier line is still there, plus a new one from the replacement pod"
run "kubectl -n $NS exec static-writer -- cat /data/log.txt"
note "both pods landed on the same node, because the PV declares nodeAffinity."
note "a hostPath volume exists on one node only, so without that the"
note "replacement could be scheduled elsewhere and find an empty directory."
run "kubectl -n $NS get pod static-writer -o jsonpath='scheduled on: {.spec.nodeName}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 4. StorageClass: dynamic provisioning =====" | tee -a "$LOG"
run "kubectl get storageclass"
run "kubectl apply -f $M/05-dynamic-pvc.yaml"
sleep 5
note "VOLUMEBINDINGMODE above is WaitForFirstConsumer, so the claim stays"
note "Pending until something actually mounts it. no PV exists yet:"
run "kubectl -n $NS get pvc dynamic-pvc"
note "now a pod asks for it"
run "kubectl apply -f $M/05b-dynamic-consumer.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/dynamic-user --timeout=180s"
note "bound, and a PV was created automatically. nobody wrote that PV by hand:"
run "kubectl -n $NS get pvc dynamic-pvc"
run "kubectl get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName | grep -E 'NAME|dynamic'"
run "kubectl -n $NS exec dynamic-user -- cat /data/hello.txt"

echo "" | tee -a "$LOG"
echo "===== 5. HPA: scaling on real CPU load =====" | tee -a "$LOG"
run "kubectl apply -f $M/06-hpa-app.yaml"
run "kubectl -n $NS rollout status deployment/hpa-demo --timeout=180s"
note "baseline: 1 replica, no load"
for i in 1 2 3; do
  sleep 20
  run "kubectl -n $NS get hpa hpa-demo --no-headers"
done

note "starting the load generator"
run "kubectl apply -f $M/08-load-generator.yaml"
note "watching the HPA react. TARGETS is current vs target CPU utilisation."
for i in $(seq 1 12); do
  sleep 25
  run "kubectl -n $NS get hpa hpa-demo --no-headers"
  REP=$(kubectl -n $NS get deploy hpa-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${REP:-0}" -ge 3 ] && break
done
run "kubectl -n $NS get pods -l app=hpa-demo --no-headers"
run "kubectl -n $NS top pods -l app=hpa-demo"
run "kubectl -n $NS describe hpa hpa-demo | awk '/Events:/,0'"

note "stopping the load and watching it scale back down"
run "kubectl -n $NS delete pod load-generator"
for i in $(seq 1 14); do
  sleep 30
  run "kubectl -n $NS get hpa hpa-demo --no-headers"
  REP=$(kubectl -n $NS get deploy hpa-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 9)
  [ "${REP:-9}" -le 1 ] && break
done

echo "" | tee -a "$LOG"
echo "===== 6. Mini project: PVC, three probes and an HPA together =====" | tee -a "$LOG"
run "kubectl apply -f $M/07-mini-project.yaml"
run "kubectl -n $NS rollout status deployment/web-app --timeout=180s"
run "kubectl -n $NS get pvc web-data"
run "kubectl -n $NS get deploy,svc,hpa -l app=web-app"
run "kubectl -n $NS get hpa web-app --no-headers"
note "all three probes on the running pod:"
run "kubectl -n $NS get deploy web-app -o jsonpath='{range .spec.template.spec.containers[0]}startup={.startupProbe.httpGet.path} readiness={.readinessProbe.httpGet.path} liveness={.livenessProbe.httpGet.path}{\"\n\"}{end}'"
run "kubectl -n $NS describe pod -l app=web-app | grep -E 'Startup:|Readiness:|Liveness:' | head -3"
note "the PVC is mounted and writable from the app:"
POD=$(kubectl -n $NS get pods -l app=web-app -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n $NS exec $POD -- sh -c 'echo persisted > /data/app.txt; cat /data/app.txt'"
run "kubectl -n $NS exec $POD -- df -h /data"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

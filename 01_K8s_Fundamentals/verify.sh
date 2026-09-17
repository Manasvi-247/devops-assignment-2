#!/usr/bin/env bash
# Runs every check for the Kubernetes fundamentals exercise and writes the real
# output to output.log.
#
#   chmod +x verify.sh && ./verify.sh
#
set -u
NS=k8s-basics
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}

echo "===== 1. The cluster and its nodes =====" | tee -a "$LOG"
run "kubectl cluster-info"
run "kubectl get nodes -o wide"
run "kubectl version"

echo "" | tee -a "$LOG"
echo "===== 2. Control plane: the components are themselves pods =====" | tee -a "$LOG"
run "kubectl -n kube-system get pods -o wide --sort-by=.spec.nodeName"
run "kubectl -n kube-system get pods -l tier=control-plane -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,OWNER:.metadata.ownerReferences[0].kind"

echo "" | tee -a "$LOG"
echo "===== 3. Static pods: who owns the control plane pods =====" | tee -a "$LOG"
run "docker exec svc-lab-control-plane ls -1 /etc/kubernetes/manifests/"
run "kubectl -n kube-system get pod kube-apiserver-svc-lab-control-plane -o jsonpath='{.metadata.ownerReferences[0].kind}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 4. Namespaces =====" | tee -a "$LOG"
run "kubectl get namespaces"
run "kubectl apply -f manifests/00-namespace.yaml"

echo "" | tee -a "$LOG"
echo "===== 5. First pod =====" | tee -a "$LOG"
run "kubectl apply -f manifests/01-first-pod.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/first-pod --timeout=120s"
run "kubectl -n $NS get pod first-pod -o wide"
run "kubectl -n $NS describe pod first-pod | sed -n '1,25p'"

echo "" | tee -a "$LOG"
echo "===== 6. Talking to the pod, logs and exec =====" | tee -a "$LOG"
run "kubectl -n $NS exec first-pod -- curl -s http://localhost:8080"
run "kubectl -n $NS logs first-pod --tail=5"

echo "" | tee -a "$LOG"
echo "===== 7. A pod is the unit: two containers sharing network and storage =====" | tee -a "$LOG"
run "kubectl apply -f manifests/02-two-container-pod.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/shared-pod --timeout=120s"
run "kubectl -n $NS get pod shared-pod -o jsonpath='{range .spec.containers[*]}{.name}{\"\n\"}{end}'"
echo "# the reader sees what the writer wrote, through the shared emptyDir:" | tee -a "$LOG"
run "kubectl -n $NS exec shared-pod -c reader -- sh -c 'sleep 5; tail -3 /data/log.txt'"
echo "# both containers report the same pod IP, they share one network namespace:" | tee -a "$LOG"
run "kubectl -n $NS exec shared-pod -c writer -- hostname -i"
run "kubectl -n $NS exec shared-pod -c reader -- hostname -i"

echo "" | tee -a "$LOG"
echo "===== 8. Self healing: delete the container, kubelet restarts it =====" | tee -a "$LOG"
run "kubectl -n $NS get pod first-pod -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount"
CID=$(kubectl -n $NS get pod first-pod -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
NODE=$(kubectl -n $NS get pod first-pod -o jsonpath='{.spec.nodeName}')
run "docker exec $NODE crictl stop $CID"
sleep 12
run "kubectl -n $NS get pod first-pod -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATUS:.status.phase"

echo "" | tee -a "$LOG"
echo "===== 9. A bare pod is NOT self healing: delete it and nothing brings it back =====" | tee -a "$LOG"
run "kubectl -n $NS delete pod shared-pod"
run "kubectl -n $NS get pods"

echo "" | tee -a "$LOG"
echo "===== 10. What the API server actually stores =====" | tee -a "$LOG"
run "kubectl -n $NS get pod first-pod -o yaml | sed -n '1,12p'"
run "kubectl api-resources --namespaced=true -o name | head -20"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

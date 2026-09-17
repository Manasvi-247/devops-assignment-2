#!/usr/bin/env bash
# Runs every check for the ingress / configmaps / secrets exercise and writes
# the real output to output.log.
#
# Needs an ingress controller. On kind:
#   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
#   kubectl label node <a-worker> ingress-ready=true
#
set -u
NS=app-config
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}

run "kubectl apply -f manifests/00-namespace.yaml"

echo "" | tee -a "$LOG"
echo "===== 1. ConfigMap and Secret: what actually gets stored =====" | tee -a "$LOG"
run "kubectl apply -f manifests/01-configmap.yaml -f manifests/02-secret.yaml"
run "kubectl -n $NS get configmap app-settings -o yaml | sed -n '1,20p'"
echo "# the secret was written as stringData, the API server stores it base64 encoded:" | tee -a "$LOG"
run "kubectl -n $NS get secret db-credentials -o jsonpath='{.data}{\"\n\"}'"
echo "# base64 is encoding, not encryption. anyone with get on secrets can decode it:" | tee -a "$LOG"
run "kubectl -n $NS get secret db-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo"
echo "# kubectl describe hides secret values but shows configmap values in full:" | tee -a "$LOG"
run "kubectl -n $NS describe secret db-credentials"

echo "" | tee -a "$LOG"
echo "===== 2. Consuming both, as env vars and as mounted files =====" | tee -a "$LOG"
run "kubectl apply -f manifests/03-consumer-pod.yaml"
run "kubectl -n $NS wait --for=condition=Ready pod/config-consumer --timeout=120s"
echo "# env vars, from the configmap and from the secret:" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- sh -c 'echo APP_NAME=\$APP_NAME; echo LOG_LEVEL=\$LOG_LEVEL; echo DB_PASSWORD=\$DB_PASSWORD'"
echo "# the configmap mounted as a directory of files:" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- ls -l /etc/app"
run "kubectl -n $NS exec config-consumer -- cat /etc/app/app.properties"
echo "# the secret mounted as files, decoded automatically, on a tmpfs:" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- ls -l /etc/creds"
run "kubectl -n $NS exec config-consumer -- cat /etc/creds/DB_PASSWORD; echo"
run "kubectl -n $NS exec config-consumer -- df -h /etc/creds"

echo "" | tee -a "$LOG"
echo "===== 3. Updating config: mounted files refresh, env vars do NOT =====" | tee -a "$LOG"
run "kubectl -n $NS patch configmap app-settings --type merge -p '{\"data\":{\"LOG_LEVEL\":\"debug\",\"app.properties\":\"feature.newCheckout=true\\nfeature.darkMode=TRUE-UPDATED\\ncache.ttlSeconds=900\\n\"}}'"
echo "# waiting for the kubelet to sync the projected volume (up to ~60s)" | tee -a "$LOG"
for i in $(seq 1 24); do
  if kubectl -n $NS exec config-consumer -- grep -q 'TRUE-UPDATED' /etc/app/app.properties 2>/dev/null; then break; fi
  sleep 5
done
echo "# the mounted file picked up the change:" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- cat /etc/app/app.properties"
echo "# but the env var is still the OLD value, because env is set once at start:" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- sh -c 'echo LOG_LEVEL=\$LOG_LEVEL'"
run "kubectl -n $NS get configmap app-settings -o jsonpath='{.data.LOG_LEVEL}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 4. Two apps behind an Ingress =====" | tee -a "$LOG"
run "kubectl apply -f manifests/04-apps.yaml"
run "kubectl -n $NS rollout status deployment/shop --timeout=180s"
run "kubectl -n $NS rollout status deployment/admin --timeout=180s"
run "kubectl -n $NS get svc shop admin"
run "kubectl apply -f manifests/05-ingress.yaml"
sleep 8
run "kubectl -n $NS get ingress site"
run "kubectl -n $NS describe ingress site | sed -n '1,25p'"

echo "" | tee -a "$LOG"
echo "===== 5. Host based routing: same IP, two hosts, two apps =====" | tee -a "$LOG"
ICIP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
echo "# ingress controller ClusterIP: $ICIP" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- wget -qO- --header='Host: shop.local' http://$ICIP/"
run "kubectl -n $NS exec config-consumer -- wget -qO- --header='Host: admin.local' http://$ICIP/"
echo "# no Host header at all: nothing matches, the default backend answers 404" | tee -a "$LOG"
run "kubectl -n $NS exec config-consumer -- wget -S -qO- http://$ICIP/ 2>&1 | head -5 || true"

echo "" | tee -a "$LOG"
echo "===== 6. One Ingress, one IP, many services =====" | tee -a "$LOG"
run "kubectl -n ingress-nginx get svc ingress-nginx-controller"
echo "# the ingress controller is itself just a deployment of nginx pods:" | tee -a "$LOG"
run "kubectl -n ingress-nginx get pods -o wide"
echo "# it turns Ingress objects into nginx server blocks. proof, from its own config:" | tee -a "$LOG"
POD=$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
run "kubectl -n ingress-nginx exec $POD -- cat /etc/nginx/nginx.conf | grep -A2 'server_name shop.local'"

echo "" | tee -a "$LOG"
echo "===== 7. A broken Ingress: backend service does not exist =====" | tee -a "$LOG"
run "kubectl apply -f manifests/06-broken-ingress.yaml"
sleep 8
run "kubectl -n $NS get ingress"
run "kubectl -n $NS exec config-consumer -- wget -S -qO- --header='Host: broken.local' http://$ICIP/ 2>&1 | head -5 || true"
echo "# the endpoints are what is missing. the Ingress object itself looks fine:" | tee -a "$LOG"
run "kubectl -n $NS describe ingress broken | sed -n '1,20p'"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

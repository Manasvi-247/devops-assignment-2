#!/usr/bin/env bash
# The remaining session 12 tasks: bulk env injection, rollout restart, the
# base64 newline bug, path based routing, hybrid routing and TLS termination.
# Writes the real output to output-full.log.
#
set -u
NS=app-config
M=manifests/full-demo
LOG=output-full.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

echo "===== 1. The base64 trailing newline bug =====" | tee -a "$LOG"
note "this is a shell level gotcha, no cluster involved"
run "echo 'secretpassword' | xxd | tail -2"
run "echo -n 'secretpassword' | xxd | tail -2"
note "the first ends 0a, which is a newline. the encodings differ:"
run "echo 'secretpassword' | base64"
run "echo -n 'secretpassword' | base64"
note "decoding both back, piped to xxd so the difference is visible:"
run "echo 'c2VjcmV0cGFzc3dvcmRL' >/dev/null; echo 'secretpassword' | base64 | base64 -d | xxd | tail -1"
run "echo -n 'secretpassword' | base64 | base64 -d | xxd | tail -1"

echo "" | tee -a "$LOG"
echo "===== 2. Full stack via run-demo.sh =====" | tee -a "$LOG"
run "bash $M/run-demo.sh"

echo "" | tee -a "$LOG"
echo "===== 3. Bulk envFrom plus granular secretKeyRef =====" | tee -a "$LOG"
note "envFrom pulled in all five configmap keys at once, the secret two by name"
run "kubectl -n $NS exec deploy/yatri-backend -- env | grep -E 'ENVIRONMENT|LOG_LEVEL|PORT|DEFAULT_CURRENCY|MAX_BOOKING_DAYS|POSTGRES' | sort"

echo "" | tee -a "$LOG"
echo "===== 4. ConfigMap update needs a rollout restart =====" | tee -a "$LOG"
run "kubectl -n $NS patch configmap yatri-app-config --type merge -p '{\"data\":{\"ENVIRONMENT\":\"staging\"}}'"
run "kubectl -n $NS get configmap yatri-app-config -o jsonpath='configmap now says: {.data.ENVIRONMENT}{\"\n\"}'"
note "the running pod still has the OLD value:"
run "kubectl -n $NS exec deploy/yatri-backend -- env | grep ENVIRONMENT"
run "kubectl -n $NS rollout restart deployment/yatri-backend"
run "kubectl -n $NS rollout status deployment/yatri-backend --timeout=180s"
note "after the restart the new pods pick it up:"
run "kubectl -n $NS exec deploy/yatri-backend -- env | grep ENVIRONMENT"
note "putting it back for the rest of the run"
run "kubectl -n $NS patch configmap yatri-app-config --type merge -p '{\"data\":{\"ENVIRONMENT\":\"production\"}}'"
run "kubectl -n $NS rollout restart deployment/yatri-backend"
run "kubectl -n $NS rollout status deployment/yatri-backend --timeout=180s"

ICIP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
echo "" | tee -a "$LOG"
echo "===== 5. Path based routing with rewrite =====" | tee -a "$LOG"
note "ingress controller ClusterIP: $ICIP"
run "kubectl -n $NS get ingress yatri-ingress"
run "kubectl -n $NS describe ingress yatri-ingress | sed -n '/Rules:/,/Annotations/p'"
note "/ goes to the frontend:"
run "kubectl -n $NS exec probe -- curl -s -H 'Host: yatri.local' http://$ICIP/"
note "/api/ goes to the backend, with the /api prefix rewritten away:"
run "kubectl -n $NS exec probe -- curl -s -H 'Host: yatri.local' http://$ICIP/api/"
run "kubectl -n $NS exec probe -- curl -s -H 'Host: yatri.local' http://$ICIP/api/bookings"

echo "" | tee -a "$LOG"
echo "===== 6. Hybrid routing: two hosts, and paths within one of them =====" | tee -a "$LOG"
run "kubectl -n $NS get ingress campus-ingress-tls"
run "kubectl -n $NS describe ingress campus-ingress-tls | sed -n '/Rules:/,/Annotations/p'"
note "portal.campus.local -> frontend"
run "kubectl -n $NS exec probe -- curl -s -H 'Host: portal.campus.local' http://$ICIP/"
note "api.campus.local/ -> frontend, but api.campus.local/api/ -> backend"
run "kubectl -n $NS exec probe -- curl -s -H 'Host: api.campus.local' http://$ICIP/"
run "kubectl -n $NS exec probe -- curl -s -H 'Host: api.campus.local' http://$ICIP/api/"

echo "" | tee -a "$LOG"
echo "===== 7. TLS termination on 443 =====" | tee -a "$LOG"
run "kubectl -n $NS get secret campus-tls-cert"
run "kubectl -n $NS get secret campus-tls-cert -o jsonpath='type={.type}{\"\n\"}'"
note "the certificate the ingress is serving, read back out of the secret:"
run "kubectl -n $NS get secret campus-tls-cert -o jsonpath='{.data.tls\\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates"
note "an HTTPS request through the controller, -k because it is self signed:"
run "kubectl -n $NS exec probe -- curl -sk -H 'Host: portal.campus.local' https://$ICIP/ || true"
note "and with curl from a pod that has it, showing the handshake:"
run "kubectl -n $NS exec probe -- curl -sk -v --resolve portal.campus.local:443:$ICIP https://portal.campus.local/ 2>&1 | grep -E 'subject|issuer|SSL connection|HTTP/|^< HTTP' | head -8"

echo "" | tee -a "$LOG"
echo "===== 8. Teardown via cleanup.sh =====" | tee -a "$LOG"
run "bash $M/cleanup.sh"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

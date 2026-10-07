#!/usr/bin/env bash
# Brings up the whole stack: config, secret, both tiers, and the ingress.
set -euo pipefail
NS=app-config
D="$(cd "$(dirname "$0")" && pwd)"

echo "==> namespace"
kubectl get namespace $NS >/dev/null 2>&1 || kubectl create namespace $NS

echo "==> config and secret"
kubectl apply -f "$D/01-configmap.yaml" -f "$D/02-secret.yaml"

echo "==> workloads"
kubectl apply -f "$D/00-client.yaml" -f "$D/03-backend.yaml" -f "$D/04-frontend.yaml"
kubectl -n $NS rollout status deployment/yatri-backend  --timeout=180s
kubectl -n $NS rollout status deployment/yatri-frontend --timeout=180s
kubectl -n $NS wait --for=condition=Ready pod/probe --timeout=180s

echo "==> tls certificate"
if ! kubectl -n $NS get secret campus-tls-cert >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
    -subj "/CN=campus.local/O=CampusDevOps" \
    -addext "subjectAltName=DNS:portal.campus.local,DNS:api.campus.local" 2>/dev/null
  kubectl -n $NS create secret tls campus-tls-cert --cert="$TMP/tls.crt" --key="$TMP/tls.key"
  rm -rf "$TMP"
fi

echo "==> ingress"
kubectl apply -f "$D/05-ingress-paths.yaml" -f "$D/06-ingress-hybrid-tls.yaml"

echo "==> done"
kubectl -n $NS get configmap,secret,deploy,svc,ingress -l app=yatri-app 2>/dev/null || true
kubectl -n $NS get ingress

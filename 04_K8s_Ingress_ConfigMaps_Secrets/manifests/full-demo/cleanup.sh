#!/usr/bin/env bash
# Removes everything run-demo.sh created, leaving the namespace in place.
set -uo pipefail
NS=app-config
D="$(cd "$(dirname "$0")" && pwd)"

kubectl delete -f "$D/06-ingress-hybrid-tls.yaml" --ignore-not-found
kubectl delete -f "$D/05-ingress-paths.yaml" --ignore-not-found
kubectl delete -f "$D/04-frontend.yaml" --ignore-not-found
kubectl delete -f "$D/03-backend.yaml" --ignore-not-found
kubectl delete -f "$D/00-client.yaml" --ignore-not-found
kubectl delete -f "$D/02-secret.yaml" --ignore-not-found
kubectl delete -f "$D/01-configmap.yaml" --ignore-not-found
kubectl -n $NS delete secret campus-tls-cert --ignore-not-found

echo "==> remaining in $NS:"
kubectl -n $NS get deploy,svc,ingress 2>&1 | head -5

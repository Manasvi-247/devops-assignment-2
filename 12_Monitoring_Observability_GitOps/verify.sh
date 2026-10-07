#!/usr/bin/env bash
# Prometheus and Grafana via compose, then Argo CD reconciling this repo onto
# the cluster. Writes the real output to output.log.
#
set -u
LOG=$(pwd)/output.log
PG=prometheus-grafana
NS=gitops-demo
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

echo "===== 1. The monitoring stack =====" | tee -a "$LOG"
run "cat $PG/prometheus.yml"
run "cd $PG && docker compose up -d --quiet-pull && cd .."
note "waiting for prometheus to report ready"
for i in $(seq 1 40); do curl -sf -m 3 http://localhost:9090/-/ready >/dev/null 2>&1 && break; sleep 3; done
run "cd $PG && docker compose ps --format 'table {{.Service}}\\t{{.Status}}\\t{{.Ports}}' && cd .."

echo "" | tee -a "$LOG"
echo "===== 2. Targets: what prometheus is scraping =====" | tee -a "$LOG"
note "giving the scrapers one interval to report"
sleep 15
run "curl -s 'http://localhost:9090/api/v1/targets' | python3 -c \"
import json,sys
d=json.load(sys.stdin)
print(f'{\\\"JOB\\\":16} {\\\"HEALTH\\\":8} ENDPOINT')
for t in d['data']['activeTargets']:
    print(f\\\"{t['labels']['job']:16} {t['health']:8} {t['scrapeUrl']}\\\")\""

echo "" | tee -a "$LOG"
echo "===== 3. Querying with PromQL =====" | tee -a "$LOG"
note "up is 1 for a target that was scraped successfully, 0 if the scrape failed"
run "curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -c \"
import json,sys
for r in json.load(sys.stdin)['data']['result']:
    print(f\\\"up{{job={r['metric']['job']}}} = {r['value'][1]}\\\")\""

note "a real metric: how many cpu cores the host reports"
run "curl -s --get 'http://localhost:9090/api/v1/query' --data-urlencode 'query=count(node_cpu_seconds_total{mode=\"idle\"})' | python3 -c \"
import json,sys
r=json.load(sys.stdin)['data']['result']
print('cpu cores:', r[0]['value'][1] if r else 'no data')\""

note "a rate over time, which is what most dashboards actually plot"
note "generating some traffic first so the rate is not flat zero"
for i in $(seq 1 60); do curl -s -o /dev/null "http://localhost:9090/api/v1/query?query=up"; done
sleep 20
run "curl -s --get 'http://localhost:9090/api/v1/query' --data-urlencode 'query=topk(5, rate(prometheus_http_requests_total[1m]))' | python3 -c \"
import json,sys
for r in json.load(sys.stdin)['data']['result']:
    print(f\\\"{r['metric'].get('handler','?'):34} {float(r['value'][1]):.4f} req/s\\\")\""

echo "" | tee -a "$LOG"
echo "===== 4. Grafana =====" | tee -a "$LOG"
for i in $(seq 1 40); do curl -sf -m 3 http://localhost:3001/api/health >/dev/null 2>&1 && break; sleep 3; done
run "curl -s http://localhost:3001/api/health; echo"
note "the prometheus datasource was provisioned from a file, not clicked in:"
run "curl -s -u admin:admin http://localhost:3001/api/datasources | python3 -c \"
import json,sys
for d in json.load(sys.stdin):
    print(f\\\"{d['name']:12} {d['type']:12} {d['url']}  default={d['isDefault']}\\\")\""
note "and grafana can actually reach it:"
run "curl -s -u admin:admin 'http://localhost:3001/api/datasources/proxy/1/api/v1/query?query=up' | python3 -c \"
import json,sys
d=json.load(sys.stdin)
print('status:', d['status'], ' series returned:', len(d['data']['result']))\""

echo "" | tee -a "$LOG"
echo "===== 5. GitOps: Argo CD =====" | tee -a "$LOG"
run "kubectl -n argocd get pods --no-headers"
run "kubectl -n argocd get crd | grep argoproj"

echo "" | tee -a "$LOG"
echo "===== 6. An Application pointing at this repository =====" | tee -a "$LOG"
run "cat gitops/argocd-application.yaml"
run "kubectl apply -f gitops/argocd-application.yaml"
note "argo clones the repo, reads the path, and creates what it finds there."
note "nothing below was applied by hand."
for i in $(seq 1 40); do
  SYNC=$(kubectl -n argocd get application gitops-demo -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  HLTH=$(kubectl -n argocd get application gitops-demo -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  [ "${SYNC:-}" = "Synced" ] && [ "${HLTH:-}" = "Healthy" ] && break
  sleep 10
done
run "kubectl -n argocd get application gitops-demo -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision"
run "kubectl -n $NS rollout status deployment/gitops-demo --timeout=120s"
run "kubectl -n $NS get deploy,svc,pods --no-headers"
note "argo claims these objects as its own, so they came from git, not from kubectl apply"
run "kubectl -n argocd get application gitops-demo -o jsonpath='{range .status.resources[*]}{.kind}/{.name} {.status}{\"\n\"}{end}'"
run "kubectl -n $NS get deploy gitops-demo -o jsonpath='field manager: {.metadata.managedFields[0].manager}{\"\n\"}'"

echo "" | tee -a "$LOG"
echo "===== 7. Self healing: delete something argo manages =====" | tee -a "$LOG"
note "selfHeal is on, so argo should put this back without anyone asking"
run "kubectl -n $NS get deploy gitops-demo -o jsonpath='replicas before: {.spec.replicas}{\"\n\"}'"
run "kubectl -n $NS scale deployment gitops-demo --replicas=5"
run "kubectl -n $NS get deploy gitops-demo -o jsonpath='replicas after manual edit: {.spec.replicas}{\"\n\"}'"
note "waiting for argo to notice the drift and reconcile"
T0=$(date +%s)
for i in $(seq 1 60); do
  R=$(kubectl -n $NS get deploy gitops-demo -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [ "${R:-}" = "2" ] && break
  sleep 5
done
note "argo reverted it after $(( $(date +%s) - T0 ))s without anyone running kubectl"
run "kubectl -n $NS get deploy gitops-demo -o jsonpath='replicas after argo reconciled: {.spec.replicas}{\"\n\"}'"
run "kubectl -n argocd get application gitops-demo -o jsonpath='app sync status: {.status.sync.status}  health: {.status.health.status}{\"\n\"}'"
note "git said 2, so it is 2 again. the cluster was corrected, not the repo."

echo "" | tee -a "$LOG"
echo "===== 8. Teardown =====" | tee -a "$LOG"
run "kubectl delete -f gitops/argocd-application.yaml"
run "cd $PG && docker compose down && cd .."

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

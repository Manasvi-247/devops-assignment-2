#!/usr/bin/env bash
# Builds and runs the TaskBoard stack with Docker Compose, then exercises the
# frontend and every backend API endpoint. Writes the real output to output.log.
#
#   chmod +x verify.sh && ./verify.sh
#
set -u
LOG=output.log
API=http://localhost:18000
WEB=http://localhost:13000
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

echo "===== 1. The stack definition =====" | tee -a "$LOG"
run "docker compose config --services"
note "an override file moves the host ports, see docker-compose.override.yml"
run "docker compose config | grep -A3 published || true"
run "cat docker-compose.yml"

echo "" | tee -a "$LOG"
echo "===== 2. Build and start =====" | tee -a "$LOG"
note "pre-pulling base images. a transient ipv6 route failure to the registry"
note "broke an earlier run, so this retries rather than failing the build"
for img in python:3.12-slim node:22-alpine nginx:1.27-alpine postgres:16-alpine; do
  for attempt in 1 2 3; do docker pull -q "$img" >/dev/null 2>&1 && break; sleep 5; done
done
run "docker compose up -d --build --quiet-pull"

note "waiting for the backend to answer its health endpoint"
for i in $(seq 1 60); do
  curl -sf -m 3 "$API/health" >/dev/null 2>&1 && break
  sleep 5
done

run "docker compose ps"

echo "" | tee -a "$LOG"
echo "===== 3. Container images that were built =====" | tee -a "$LOG"
run "docker compose images"

echo "" | tee -a "$LOG"
echo "===== 4. Database: migrations applied by the backend on startup =====" | tee -a "$LOG"
run "docker compose logs backend --tail=12"
note "the tasks table exists, created by the alembic migration"
run "docker compose exec -T postgres psql -U taskboard -d taskboard -c '\\dt'"
run "docker compose exec -T postgres psql -U taskboard -d taskboard -c '\\d tasks'"

echo "" | tee -a "$LOG"
echo "===== 5. Backend API: health and readiness =====" | tee -a "$LOG"
run "curl -s $API/ | python3 -m json.tool"
run "curl -s $API/health | python3 -m json.tool"
run "curl -s $API/ready | python3 -m json.tool"

echo "" | tee -a "$LOG"
echo "===== 6. Backend API: full CRUD cycle =====" | tee -a "$LOG"
note "GET on an empty board"
run "curl -s $API/api/tasks | python3 -m json.tool"

note "POST three tasks"
run "curl -s -X POST $API/api/tasks -H 'Content-Type: application/json' -d '{\"title\":\"Write the Dockerfile\",\"description\":\"multi stage build for the frontend\",\"priority\":\"HIGH\",\"assignee\":\"Manasvi\"}' | python3 -m json.tool"
run "curl -s -X POST $API/api/tasks -H 'Content-Type: application/json' -d '{\"title\":\"Run docker compose up\",\"priority\":\"MEDIUM\",\"assignee\":\"Manasvi\"}' | python3 -m json.tool"
run "curl -s -X POST $API/api/tasks -H 'Content-Type: application/json' -d '{\"title\":\"Test the API endpoints\",\"priority\":\"LOW\",\"assignee\":\"Manasvi\"}' | python3 -m json.tool"

note "GET the list again, now with three rows"
run "curl -s $API/api/tasks | python3 -m json.tool"

note "GET one task by id"
run "curl -s $API/api/tasks/1 | python3 -m json.tool"

note "PUT to update task 1"
run "curl -s -X PUT $API/api/tasks/1 -H 'Content-Type: application/json' -d '{\"title\":\"Write the Dockerfile\",\"status\":\"DONE\",\"priority\":\"HIGH\",\"assignee\":\"Manasvi\"}' | python3 -m json.tool"

note "the stats endpoint reflects the change"
run "curl -s $API/api/tasks/stats | python3 -m json.tool"

note "DELETE task 3, which returns 204 with no body"
run "curl -s -o /dev/null -w 'HTTP %{http_code}\\n' -X DELETE $API/api/tasks/3"
run "curl -s $API/api/tasks | python3 -m json.tool"

echo "" | tee -a "$LOG"
echo "===== 7. Error handling =====" | tee -a "$LOG"
note "a task that does not exist"
run "curl -s -w '\\nHTTP %{http_code}\\n' $API/api/tasks/999"
note "a POST missing the required title"
run "curl -s -w '\\nHTTP %{http_code}\\n' -X POST $API/api/tasks -H 'Content-Type: application/json' -d '{\"priority\":\"HIGH\"}'"

echo "" | tee -a "$LOG"
echo "===== 8. Frontend =====" | tee -a "$LOG"
run "curl -s -o /dev/null -w 'HTTP %{http_code}\\n' $WEB/"
run "curl -s $WEB/ | head -20"
note "nginx proxies /api to the backend container, so the SPA calls work"
run "curl -s $WEB/api/tasks | python3 -m json.tool"

echo "" | tee -a "$LOG"
echo "===== 9. Prometheus metrics endpoint =====" | tee -a "$LOG"
note "the backend exposes /metrics, which is what session 20 scrapes"
run "curl -s $API/metrics | grep -E '^http_requests_total|^http_request_duration' | head -6"

echo "" | tee -a "$LOG"
echo "===== 10. Pytest inside the backend image =====" | tee -a "$LOG"
note "pytest ships in the image. it runs against a throwaway sqlite file in /tmp"
note "so the live postgres data is left alone"
run "docker compose exec -T -w /tmp -e DATABASE_URL=sqlite:////tmp/test.db backend python -m pytest -v /app/tests"

echo "" | tee -a "$LOG"
echo "===== 11. Persistence: data survives a restart =====" | tee -a "$LOG"
run "docker compose restart backend postgres"
for i in $(seq 1 40); do
  curl -sf -m 3 "$API/health" >/dev/null 2>&1 && break
  sleep 5
done
note "the tasks are still there, because the postgres volume persisted"
run "curl -s $API/api/tasks | python3 -m json.tool"
run "docker volume ls | grep -i taskboard || docker volume ls | head -5"

echo "" | tee -a "$LOG"
echo "===== 12. Teardown =====" | tee -a "$LOG"
run "docker compose down"
run "docker compose ps"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

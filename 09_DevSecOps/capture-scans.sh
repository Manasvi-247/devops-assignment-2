#!/usr/bin/env bash
# Runs the same scanners the pipeline runs, locally, so the write-up quotes
# real findings. Writes the real output to output.log.
set -u
APP=../13_Final_Project_TaskBoard/backend
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

echo "===== 1. SAST: scanning our own source =====" | tee -a "$LOG"
note "bandit reads the python we wrote, looking for insecure patterns"
run "docker run --rm -v \"\$PWD/$APP:/src\" -w /src python:3.12-slim sh -c 'pip install -q bandit 2>/dev/null; bandit -r app -f txt' | tail -22"

echo "" | tee -a "$LOG"
echo "===== 2. SCA: scanning what we depend on =====" | tee -a "$LOG"
note "pip-audit checks the declared dependencies against advisory databases"
run "docker run --rm -v \"\$PWD/$APP:/src\" -w /src python:3.12-slim sh -c 'pip install -q pip-audit 2>/dev/null; pip-audit -r requirements.txt --format columns' | tail -20"

echo "" | tee -a "$LOG"
echo "===== 3. Secret scanning =====" | tee -a "$LOG"
note "gitleaks reads the whole git history, not just the working tree,"
note "because a secret removed in a later commit is still in the history"
run "docker run --rm -v \"\$PWD/..:/repo\" zricethezav/gitleaks:v8.21.2 detect --source=/repo --no-banner --redact -v 2>&1 | tail -12"

echo "" | tee -a "$LOG"
echo "===== 4. Container image scanning =====" | tee -a "$LOG"
run "docker build -q -t taskboard-backend:scan $APP"
note "every severity, to see the whole picture first"
run "docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \"\$HOME/.cache/trivy:/root/.cache/trivy\" aquasec/trivy:0.58.1 image --severity HIGH,CRITICAL --format table taskboard-backend:scan 2>/dev/null | grep -E 'Total:|^.aquasec|starlette|Library' | head -12"

echo "" | tee -a "$LOG"
echo "===== 5. The gate, before the fix =====" | tee -a "$LOG"
note "this is what the pipeline saw on the first run: fastapi 0.115.6 pulled"
note "starlette 0.41.3, which carries three HIGH findings"
run "cat $APP/.trivyignore | head -22"

echo "" | tee -a "$LOG"
echo "===== 6. The gate, after the fix =====" | tee -a "$LOG"
note "fastapi bumped to 0.142.2, and the two unfixable findings accepted"
note "in writing. exit code 0 means the pipeline may continue."
run "docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \"\$HOME/.cache/trivy:/root/.cache/trivy\" -v \"\$PWD/$APP/.trivyignore:/.trivyignore\" aquasec/trivy:0.58.1 image --severity HIGH,CRITICAL --ignore-unfixed --ignorefile /.trivyignore --exit-code 1 --format table taskboard-backend:scan 2>/dev/null | tail -6; echo \"gate exit code: \$?\""

echo "" | tee -a "$LOG"
echo "===== 7. The pipeline jobs =====" | tee -a "$LOG"
run "gh run list --repo Manasvi-247/devops-assignment-2 --workflow=security.yml --limit 4"
SEC=$(gh run list --repo Manasvi-247/devops-assignment-2 --workflow=security.yml --limit 1 --json databaseId --jq '.[0].databaseId')
run "gh run view $SEC --repo Manasvi-247/devops-assignment-2 --json jobs --jq '.jobs[] | \"\\(.conclusion)\\t\\(.name)\"'"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

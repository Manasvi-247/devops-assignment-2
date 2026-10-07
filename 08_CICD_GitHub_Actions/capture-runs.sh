#!/usr/bin/env bash
# Pulls the real run history and job results from GitHub into output.log, so
# the write-up quotes actual runs rather than describing them.
set -u
REPO=Manasvi-247/devops-assignment-2
LOG=output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

echo "===== 1. Every run so far, including the ones that failed =====" | tee -a "$LOG"
run "gh run list --repo $REPO --limit 10"

CI=$(gh run list --repo $REPO --workflow=ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')

echo "" | tee -a "$LOG"
echo "===== 2. The jobs in the latest CI run =====" | tee -a "$LOG"
note "run id $CI"
run "gh run view $CI --repo $REPO --json jobs --jq '.jobs[] | \"\\(.conclusion)\\t\\(.name)\"'"

echo "" | tee -a "$LOG"
echo "===== 3. The matrix: the same tests on two python versions =====" | tee -a "$LOG"
run "gh run view $CI --repo $REPO --log | grep -E 'collected|passed' | sed 's/\\t/  /g' | cut -c1-120 | head -6"

echo "" | tee -a "$LOG"
echo "===== 4. Artifacts the run produced =====" | tee -a "$LOG"
run "gh api repos/$REPO/actions/runs/$CI/artifacts --jq '.artifacts[] | \"\\(.name)  \\(.size_in_bytes) bytes\"'"

echo "" | tee -a "$LOG"
echo "===== 5. Job dependencies: build waited for test =====" | tee -a "$LOG"
note "startedAt and completedAt show build beginning only after both test jobs ended"
run "gh run view $CI --repo $REPO --json jobs --jq '.jobs[] | \"\\(.name)\\tstart \\(.startedAt)\\tend \\(.completedAt)\"'"

echo "" | tee -a "$LOG"
echo "===== 6. The security workflow =====" | tee -a "$LOG"
SEC=$(gh run list --repo $REPO --workflow=security.yml --limit 1 --json databaseId --jq '.[0].databaseId')
note "run id $SEC"
run "gh run view $SEC --repo $REPO --json jobs --jq '.jobs[] | \"\\(.conclusion)\\t\\(.name)\"'"

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

#!/usr/bin/env bash
# Terraform: the full init, plan, apply, state, destroy lifecycle against the
# local providers, then the AWS configuration validated without applying.
# Writes the real output to output.log.
#
set -u
LOG=$(pwd)/output.log
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

run "terraform version"

echo "" | tee -a "$LOG"
echo "===== 1. The configuration =====" | tee -a "$LOG"
cd local-demo
run "ls"
run "cat terraform.tf"
run "cat main.tf"

echo "" | tee -a "$LOG"
echo "===== 2. init: download providers and set up the backend =====" | tee -a "$LOG"
run "terraform init -no-color"
note "init created a lock file pinning exact provider versions:"
run "cat .terraform.lock.hcl | head -20"

echo "" | tee -a "$LOG"
echo "===== 3. validate and fmt =====" | tee -a "$LOG"
run "terraform validate -no-color"
run "terraform fmt -check -no-color && echo 'formatting is already canonical'"

echo "" | tee -a "$LOG"
echo "===== 4. plan: what would change =====" | tee -a "$LOG"
run "terraform plan -no-color -out=tfplan"
note "the plan is a real file, and can be inspected without re-planning:"
run "terraform show -no-color tfplan | head -25"

echo "" | tee -a "$LOG"
echo "===== 5. apply =====" | tee -a "$LOG"
run "terraform apply -no-color -auto-approve tfplan"
note "the resources it created really exist on disk:"
run "ls -l generated/"
run "cat generated/node-0.conf"
run "terraform output -no-color"
note "a sensitive output is redacted unless asked for explicitly:"
run "terraform output -no-color -raw api_key | head -c 8; echo '... (truncated)'"

echo "" | tee -a "$LOG"
echo "===== 6. State =====" | tee -a "$LOG"
run "terraform state list"
run "terraform state show random_pet.suffix"
note "state records the mapping from configuration to real objects:"
run "terraform show -no-color -json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"resources in state:\", len(d[\"values\"][\"root_module\"][\"resources\"]))'"

echo "" | tee -a "$LOG"
echo "===== 7. Idempotency: a second plan should be empty =====" | tee -a "$LOG"
run "terraform plan -no-color | tail -5"

echo "" | tee -a "$LOG"
echo "===== 8. Drift: change a managed file by hand =====" | tee -a "$LOG"
run "echo 'edited outside terraform' >> generated/node-0.conf"
run "cat generated/node-0.conf"
note "terraform notices and plans to put it back"
run "terraform plan -no-color | tail -12"

echo "" | tee -a "$LOG"
echo "===== 9. Changing a variable =====" | tee -a "$LOG"
run "terraform plan -no-color -var='instance_count=5' | tail -8"

echo "" | tee -a "$LOG"
echo "===== 10. destroy =====" | tee -a "$LOG"
run "terraform destroy -no-color -auto-approve"
run "ls generated/ 2>&1 || echo 'the generated directory is gone'"
run "terraform state list 2>&1 || echo 'state is empty'"

cd ..

echo "" | tee -a "$LOG"
echo "===== 11. The AWS configuration =====" | tee -a "$LOG"
cd aws-s3-demo
run "cat main.tf"
run "terraform init -no-color"
run "terraform validate -no-color"
run "terraform fmt -check -no-color && echo 'formatting is already canonical'"
note "apply is NOT run here. this account is on the AWS free plan, whose"
note "service control policy explicitly denies s3, so the credentials cannot"
note "create a bucket no matter which IAM policy is attached:"
run "aws s3api list-buckets 2>&1 | tail -2 || true"
cd ..

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

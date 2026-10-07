#!/usr/bin/env bash
# Builds the VPC with terraform against LocalStack, then inspects the result
# with the AWS CLI. Writes the real output to output.log.
#
# Needs LocalStack:
#   docker run -d --name localstack-tf -p 4566:4566 -e SERVICES=s3,ec2 localstack/localstack:3.8
#
set -u
LOG=$(pwd)/output.log
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-south-1
AWSL="aws --endpoint-url=http://localhost:4566"
: > "$LOG"

run() {
  echo ""      | tee -a "$LOG"
  echo "\$ $*" | tee -a "$LOG"
  eval "$@" 2>&1 | tee -a "$LOG"
}
note() { echo "# $*" | tee -a "$LOG"; }

echo "===== 1. The target =====" | tee -a "$LOG"
note "LocalStack provides real AWS APIs locally, so apply actually runs."
note "the same configuration targets real AWS with -var use_localstack=false"
run "curl -s http://localhost:4566/_localstack/health | python3 -c \"
import json,sys
d=json.load(sys.stdin)['services']
for k in ('ec2','s3'):
    print(f'{k}: {d.get(k)}')\""

echo "" | tee -a "$LOG"
echo "===== 2. The configuration =====" | tee -a "$LOG"
cd vpc
run "ls"
run "cat main.tf"

echo "" | tee -a "$LOG"
echo "===== 3. init, validate, fmt =====" | tee -a "$LOG"
run "terraform init -no-color | tail -6"
run "terraform validate -no-color"
run "terraform fmt -check -no-color && echo 'formatting is already canonical'"

echo "" | tee -a "$LOG"
echo "===== 4. plan =====" | tee -a "$LOG"
run "terraform plan -no-color | tail -12"

echo "" | tee -a "$LOG"
echo "===== 5. apply =====" | tee -a "$LOG"
run "terraform apply -auto-approve -no-color | tail -22"

echo "" | tee -a "$LOG"
echo "===== 6. What terraform tracks =====" | tee -a "$LOG"
run "terraform state list"
run "terraform output -no-color"

echo "" | tee -a "$LOG"
echo "===== 7. Verified independently with the aws cli =====" | tee -a "$LOG"
note "terraform could be lying. these queries go straight to the api."
run "$AWSL ec2 describe-vpcs --filters Name=tag:Name,Values=devops-course-vpc --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,State:State,DnsHostnames:EnableDnsHostnames}' --output table"
run "$AWSL ec2 describe-subnets --filters Name=tag:Tier,Values=public --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,AutoPublicIP:MapPublicIpOnLaunch}' --output table"
run "$AWSL ec2 describe-internet-gateways --query 'InternetGateways[].{ID:InternetGatewayId,AttachedTo:Attachments[0].VpcId,State:Attachments[0].State}' --output table"
note "the route that makes those subnets public:"
run "$AWSL ec2 describe-route-tables --query 'RouteTables[?Tags[?Value==\`devops-course-public-rt\`]].Routes[]' --output table"
run "$AWSL ec2 describe-security-groups --filters Name=group-name,Values=devops-course-web --query 'SecurityGroups[].IpPermissions[].{From:FromPort,To:ToPort,Proto:IpProtocol,Cidr:IpRanges[0].CidrIp}' --output table"
note "the instance, placed in the first public subnet and carrying that group:"
run "$AWSL ec2 describe-instances --filters Name=tag:Name,Values=devops-course-web --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,Subnet:SubnetId,PrivateIP:PrivateIpAddress}' --output table"
note "and the bucket, with public access blocked:"
run "$AWSL s3 ls"
run "$AWSL s3api get-public-access-block --bucket devops-course-24bcs10406-assets --output table"

echo "" | tee -a "$LOG"
echo "===== 8. Idempotency =====" | tee -a "$LOG"
run "terraform plan -no-color | tail -4"

echo "" | tee -a "$LOG"
echo "===== 9. destroy =====" | tee -a "$LOG"
run "terraform destroy -auto-approve -no-color | tail -6"
run "$AWSL ec2 describe-vpcs --filters Name=tag:Name,Values=devops-course-vpc --query 'length(Vpcs)' --output text"
cd ..

echo "" | tee -a "$LOG"
echo "===== Done. Output saved to $LOG =====" | tee -a "$LOG"

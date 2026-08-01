#!/usr/bin/env bash
# 一鍵部署語音 Agent server 到 AWS ECS Fargate（透過 ECR image + ALB）。
#
# 前提：
#   1. 已安裝 aws CLI 並設好 credentials
#   2. 已安裝 docker
#   3. ECR image 已 push 完成（本腳本會自動處理）
#
# 用法：
#   export LLM_API_KEY=sk-bf-...          # 必填，見下方「機密」
#   export SUPABASE_SECRET_KEY=sb_secret_...   # 選填，不給則 dispatch=dryrun
#   bash deploy/aws/deploy-server.sh
#
# 可用環境變數覆蓋預設：
#   AWS_REGION        預設 us-west-2
#   ECR_REPO          預設 jinsun-voice-server
#   SERVICE_NAME      預設 jinsun-voice-server
#   CLUSTER_NAME      預設 jinsun-cluster
#   IMAGE_TAG         預設 latest
#   PROGRESS_WORKER   off＝本台不參與進度播報（見下方）
#
# ⚠️ 機密一律由環境變數帶入，**絕對不要寫死在這個檔案裡**。
#    本檔第一版把 XCC Gateway 的 `sk-bf-` 金鑰直接寫在 task definition 的 JSON 裡，
#    隨著 commit 515b9e7 推上了**公開的** GitHub repo。公開過的金鑰只能作廢重簽，
#    清 git 歷史沒有用（快取／fork／掃描器都可能已經取得）。
#    ECS task definition 的環境變數對任何有帳號讀取權的人都是明文可見的，
#    正式使用請改走 Secrets Manager（`secrets` 欄位而非 `environment`）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ─── 設定 ───────────────────────────────────────────────────────────
REGION="${AWS_REGION:-us-west-2}"
REPO_NAME="${ECR_REPO:-jinsun-voice-server}"
SERVICE="${SERVICE_NAME:-jinsun-voice-server}"
CLUSTER="${CLUSTER_NAME:-jinsun-cluster}"
TAG="${IMAGE_TAG:-latest}"
CONTAINER_PORT=8787

# ─── 機密（必須由環境變數提供）───────────────────────────────────────
: "${LLM_API_KEY:?請先 export LLM_API_KEY（XCC Gateway PAT）——不要寫死在腳本裡}"
SUPABASE_SECRET_KEY="${SUPABASE_SECRET_KEY:-}"
if [ -z "${SUPABASE_SECRET_KEY}" ]; then
  echo "⚠️  未提供 SUPABASE_SECRET_KEY → 這台會是 dispatch=dryrun（不會寫任何資料）。"
fi
# 進度播報同一個資料庫只能有一台在做。這台若與 Render 那台連同一個 Supabase，
# 兩邊都會反應同一筆 dispatch_tasks 變化、各自往自己的 broker 發（見 handoff §6.2）。
PROGRESS_WORKER="${PROGRESS_WORKER:-}"

# 取得 AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

echo "═══════════════════════════════════════════════════"
echo "  金孫語音 Server → ECS Fargate 部署"
echo "═══════════════════════════════════════════════════"
echo "▶ Account: ${ACCOUNT_ID}"
echo "▶ Region:  ${REGION}"
echo "▶ ECR:     ${ECR_URI}:${TAG}"
echo ""

# ─── Step 1: 確保 ECR repo 存在 ──────────────────────────────────────
echo "① 確認 ECR repository..."
if ! aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" > /dev/null 2>&1; then
  echo "   建立 ECR repo: ${REPO_NAME}"
  aws ecr create-repository \
    --repository-name "${REPO_NAME}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --output text > /dev/null
else
  echo "   ECR repo 已存在 ✓"
fi

# ─── Step 2: Docker build & push ─────────────────────────────────────
echo ""
echo "② Docker build..."
# Fargate 支持 ARM64（graviton）：M1/M2 Mac 直接 build 不用 cross-compile，快很多。
docker build --platform linux/arm64 -t "${REPO_NAME}:${TAG}" "${ROOT}/cloud/prototype"

echo ""
echo "③ ECR login & push..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker tag "${REPO_NAME}:${TAG}" "${ECR_URI}:${TAG}"
docker push "${ECR_URI}:${TAG}"
echo "   Push 完成 ✓"

# ─── Step 3: ECS Cluster ─────────────────────────────────────────────
echo ""
echo "④ 確認 ECS Cluster..."
EXISTING_CLUSTER=$(aws ecs describe-clusters --clusters "${CLUSTER}" --region "${REGION}" \
  --query "clusters[?status=='ACTIVE'].clusterName" --output text 2>/dev/null || true)

if [ -z "${EXISTING_CLUSTER}" ]; then
  echo "   建立 ECS Cluster: ${CLUSTER}"
  aws ecs create-cluster --cluster-name "${CLUSTER}" --region "${REGION}" --output text > /dev/null
else
  echo "   Cluster 已存在 ✓"
fi

# ─── Step 4: IAM Roles ───────────────────────────────────────────────
echo ""
echo "⑤ 確認 IAM Roles..."

# Task Execution Role（讓 ECS 拉 ECR image + 寫 CloudWatch logs）
EXEC_ROLE_NAME="ecsTaskExecutionRole"
if ! aws iam get-role --role-name "${EXEC_ROLE_NAME}" > /dev/null 2>&1; then
  echo "   建立 ${EXEC_ROLE_NAME}..."
  aws iam create-role \
    --role-name "${EXEC_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ecs-tasks.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' --output text > /dev/null

  aws iam attach-role-policy \
    --role-name "${EXEC_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  sleep 5
else
  echo "   ${EXEC_ROLE_NAME} 已存在 ✓"
fi
EXEC_ROLE_ARN=$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" --query 'Role.Arn' --output text)

# ─── Step 5: CloudWatch Log Group ────────────────────────────────────
LOG_GROUP="/ecs/${SERVICE}"
echo ""
echo "⑥ 確認 CloudWatch Log Group..."
if ! aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --region "${REGION}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}']" --output text 2>/dev/null | grep -q "${LOG_GROUP}"; then
  aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" 2>/dev/null || true
  echo "   建立 log group: ${LOG_GROUP}"
else
  echo "   Log group 已存在 ✓"
fi

# ─── Step 6: Security Group（ALB + Task）──────────────────────────────
echo ""
echo "⑦ 確認 Security Group..."
VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --query 'Vpcs[0].VpcId' --output text)

# ALB Security Group（允許 80 inbound）
ALB_SG_NAME="jinsun-alb-sg"
ALB_SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [ "${ALB_SG_ID}" = "None" ] || [ -z "${ALB_SG_ID}" ]; then
  echo "   建立 ALB Security Group..."
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${ALB_SG_NAME}" \
    --description "ALB for jinsun voice server" \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" \
    --query 'GroupId' --output text)
  # 允許 HTTP 80 from anywhere
  aws ec2 authorize-security-group-ingress \
    --group-id "${ALB_SG_ID}" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "${REGION}" > /dev/null
else
  echo "   ALB SG 已存在: ${ALB_SG_ID} ✓"
fi

# Task Security Group（只允許來自 ALB 的流量）
TASK_SG_NAME="jinsun-task-sg"
TASK_SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${TASK_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [ "${TASK_SG_ID}" = "None" ] || [ -z "${TASK_SG_ID}" ]; then
  echo "   建立 Task Security Group..."
  TASK_SG_ID=$(aws ec2 create-security-group \
    --group-name "${TASK_SG_NAME}" \
    --description "ECS tasks for jinsun voice server" \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" \
    --query 'GroupId' --output text)
  # 允許來自 ALB SG 的流量
  aws ec2 authorize-security-group-ingress \
    --group-id "${TASK_SG_ID}" \
    --protocol tcp --port ${CONTAINER_PORT} \
    --source-group "${ALB_SG_ID}" \
    --region "${REGION}" > /dev/null
else
  echo "   Task SG 已存在: ${TASK_SG_ID} ✓"
fi

# ─── Step 7: ALB + Target Group ───────────────────────────────────────
echo ""
echo "⑧ 確認 ALB..."
ALB_NAME="jinsun-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --region "${REGION}" \
  --names "${ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)

# 取得所有公開子網
SUBNETS=$(aws ec2 describe-subnets --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].SubnetId' --output text)
# 轉成空格分隔
SUBNET_ARGS=$(echo ${SUBNETS} | tr '\t' ' ')

if [ "${ALB_ARN}" = "None" ] || [ -z "${ALB_ARN}" ]; then
  echo "   建立 ALB: ${ALB_NAME}..."
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --subnets ${SUBNET_ARGS} \
    --security-groups "${ALB_SG_ID}" \
    --scheme internet-facing \
    --type application \
    --region "${REGION}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  echo "   ALB 建立中..."
else
  echo "   ALB 已存在 ✓"
fi

# Target Group
TG_NAME="jinsun-voice-tg"
TG_ARN=$(aws elbv2 describe-target-groups --region "${REGION}" \
  --names "${TG_NAME}" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

if [ "${TG_ARN}" = "None" ] || [ -z "${TG_ARN}" ]; then
  echo "   建立 Target Group..."
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port ${CONTAINER_PORT} \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path "/health" \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "${REGION}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
else
  echo "   Target Group 已存在 ✓"
fi

# Listener（HTTP:80 → TG）
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" --region "${REGION}" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)

if [ "${LISTENER_ARN}" = "None" ] || [ -z "${LISTENER_ARN}" ]; then
  echo "   建立 Listener (HTTP:80)..."
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "${REGION}" --output text > /dev/null
else
  echo "   Listener 已存在 ✓"
fi

# ─── Step 8: Task Definition ─────────────────────────────────────────
echo ""
echo "⑨ 註冊 Task Definition..."

TASK_DEF_JSON=$(cat <<EOF
{
  "family": "${SERVICE}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "${SERVICE}",
    "image": "${ECR_URI}:${TAG}",
    "portMappings": [{
      "containerPort": ${CONTAINER_PORT},
      "protocol": "tcp"
    }],
    "essential": true,
    "environment": [
      {"name": "LLM_PROVIDER", "value": "apikey"},
      {"name": "LLM_API_BASE", "value": "https://llm-gateway.xcc.tw/v1"},
      {"name": "LLM_API_AUTH", "value": "x-bf-vk"},
      {"name": "LLM_API_MODEL", "value": "gpt-5.6-luna"},
      {"name": "LLM_API_FAST_MODEL", "value": "gpt-5.6-luna"},
      {"name": "LLM_API_KEY", "value": "${LLM_API_KEY}"},
      {"name": "SUPABASE_URL", "value": "https://ykfxmoubynnbhnburawl.supabase.co"},
      {"name": "SUPABASE_SECRET_KEY", "value": "${SUPABASE_SECRET_KEY}"},
      {"name": "PROGRESS_WORKER", "value": "${PROGRESS_WORKER}"},
      {"name": "MQTT_URL", "value": "mqtts://mqttgo.io:8883"},
      {"name": "TRAVEL_STEPS", "value": "20"},
      {"name": "TRAVEL_STEP_MS", "value": "3000"},
      {"name": "PORT", "value": "8787"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${LOG_GROUP}",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }]
}
EOF
)

echo "${TASK_DEF_JSON}" > /tmp/task-def.json
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-def.json \
  --region "${REGION}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "   Task Definition: ${TASK_DEF_ARN}"

# ─── Step 9: ECS Service ─────────────────────────────────────────────
echo ""
echo "⑩ 部署 ECS Service..."

EXISTING_SERVICE=$(aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
  --region "${REGION}" --query "services[?status=='ACTIVE'].serviceName" --output text 2>/dev/null || true)

if [ -z "${EXISTING_SERVICE}" ]; then
  echo "   建立 ECS Service..."
  aws ecs create-service \
    --cluster "${CLUSTER}" \
    --service-name "${SERVICE}" \
    --task-definition "${TASK_DEF_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "{
      \"awsvpcConfiguration\": {
        \"subnets\": [$(echo ${SUBNET_ARGS} | sed 's/ /","/g' | sed 's/^/"/;s/$/"/;s/ //g')],
        \"securityGroups\": [\"${TASK_SG_ID}\"],
        \"assignPublicIp\": \"ENABLED\"
      }
    }" \
    --load-balancers "[{
      \"targetGroupArn\": \"${TG_ARN}\",
      \"containerName\": \"${SERVICE}\",
      \"containerPort\": ${CONTAINER_PORT}
    }]" \
    --region "${REGION}" \
    --output text > /dev/null
else
  echo "   Service 已存在，更新 task definition..."
  aws ecs update-service \
    --cluster "${CLUSTER}" \
    --service "${SERVICE}" \
    --task-definition "${TASK_DEF_ARN}" \
    --force-new-deployment \
    --region "${REGION}" \
    --output text > /dev/null
fi

# ─── 取得 ALB DNS ─────────────────────────────────────────────────────
ALB_DNS=$(aws elbv2 describe-load-balancers --region "${REGION}" \
  --names "${ALB_NAME}" --query 'LoadBalancers[0].DNSName' --output text)

echo ""
echo "═══════════════════════════════════════════════════"
echo "✅ ECS Fargate 部署完成！"
echo ""
echo "ALB URL: http://${ALB_DNS}"
echo ""
echo "服務啟動需 2-3 分鐘，可用以下指令追蹤："
echo "  aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE} --region ${REGION} --query 'services[0].deployments'"
echo ""
echo "健康檢查："
echo "  curl http://${ALB_DNS}/health"
echo ""
echo "查看 logs："
echo "  aws logs tail ${LOG_GROUP} --region ${REGION} --follow"
echo "═══════════════════════════════════════════════════"

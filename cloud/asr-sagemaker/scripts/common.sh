#!/usr/bin/env bash
# 共用設定：由各 script source。憑證走標準 AWS 來源（~/.aws、環境變數、IAM 角色）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

: "${AWS_DEFAULT_REGION:=${AWS_REGION:-ap-northeast-1}}"
export AWS_DEFAULT_REGION

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# SageMaker 執行角色：只有部署需要，測試腳本不需要，所以做成函式讓 deploy 自己呼叫。
require_role() {
  if [ -z "${SAGEMAKER_ROLE_ARN:-}" ]; then
    echo "SAGEMAKER_ROLE_ARN 未設定。可用下列指令找出帳號內既有的角色：" >&2
    echo "  aws iam list-roles --query \"Roles[?contains(RoleName,'SageMaker')].Arn\" --output text" >&2
    exit 1
  fi
}

: "${BUCKET:=sagemaker-${AWS_DEFAULT_REGION}-${ACCOUNT_ID}}"
: "${PREFIX:=breeze-asr-26}"
: "${ENDPOINT_NAME:=breeze-asr-26}"
: "${INSTANCE_TYPE:=ml.g4dn.xlarge}"
: "${ASR_COMPUTE_TYPE:=float16}"
: "${ASR_DEVICE:=cuda}"

# AWS Deep Learning Container。763104351884 是 AWS 公用 DLC registry（中國區／GovCloud 除外）。
: "${DLC_IMAGE:=763104351884.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/huggingface-pytorch-inference:2.6.0-transformers4.51.3-gpu-py312-cu124-ubuntu22.04}"

HF_REPO="paulpengtw/faster-whisper-Breeze-ASR-26"
MODEL_BIN_BYTES=3086913037   # 用來擋 HuggingFace 下載被截斷（curl 截斷仍會 exit 0）

container_json() {
  # $1 = 模型在 S3 的 prefix uri
  cat <<JSON
{
  "Image": "$DLC_IMAGE",
  "ModelDataSource": {"S3DataSource": {
    "S3Uri": "$1", "S3DataType": "S3Prefix", "CompressionType": "None"}},
  "Environment": {
    "SAGEMAKER_PROGRAM": "inference.py",
    "SAGEMAKER_SUBMIT_DIRECTORY": "/opt/ml/model/code",
    "SAGEMAKER_CONTAINER_LOG_LEVEL": "20",
    "SAGEMAKER_REGION": "$AWS_DEFAULT_REGION",
    "ASR_DEVICE": "$ASR_DEVICE",
    "ASR_COMPUTE_TYPE": "$ASR_COMPUTE_TYPE",
    "MMS_DEFAULT_RESPONSE_TIMEOUT": "300",
    "SAGEMAKER_MODEL_SERVER_TIMEOUT": "300"
  }
}
JSON
}

variant_json() {
  # $1 = model name
  cat <<JSON
[{
  "VariantName": "AllTraffic", "ModelName": "$1",
  "InitialInstanceCount": 1, "InstanceType": "$INSTANCE_TYPE",
  "InitialVariantWeight": 1.0,
  "ModelDataDownloadTimeoutInSeconds": 1200,
  "ContainerStartupHealthCheckTimeoutInSeconds": 1800
}]
JSON
}

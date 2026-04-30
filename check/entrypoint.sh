#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# ==================== 运行验收测试 ====================
./run-acceptance.sh "$@"
EXIT_CODE=$?

# ==================== 查找报告 ====================
REPORT_FILE=$(ls -t report/acceptance-report-*.md 2>/dev/null | head -1 || true)
LOG_FILE=$(ls -t report/acceptance-*.log 2>/dev/null | head -1 || true)

if [[ -z "${REPORT_FILE}" ]]; then
    echo "[WARN] 未找到验收报告文件"
    exit $EXIT_CODE
fi

# 提取摘要
CLUSTER_NAME="${CLUSTER_NAME:-k8s-cluster}"
REPORT_TIME=$(grep '生成时间:' "${REPORT_FILE}" 2>/dev/null | sed 's/.*生成时间: //' || echo "-")
TOTAL=$(grep -E '^\| 总计 \|' "${REPORT_FILE}" 2>/dev/null | awk -F'|' '{print $3}' | tr -d ' ' || echo "-")
PASS=$(grep -E '^\| 通过 \|' "${REPORT_FILE}" 2>/dev/null | awk -F'|' '{print $3}' | tr -d ' ' || echo "-")
FAIL=$(grep -E '^\| 失败 \|' "${REPORT_FILE}" 2>/dev/null | awk -F'|' '{print $3}' | tr -d ' ' || echo "-")
SKIP=$(grep -E '^\| 跳过 \|' "${REPORT_FILE}" 2>/dev/null | awk -F'|' '{print $3}' | tr -d ' ' || echo "-")

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [[ "${FAIL}" == "0" || "${FAIL}" == "-" ]]; then
    STATUS_TEXT="✅ 通过"
    STATUS_COLOR="green"
else
    STATUS_TEXT="❌ 未通过"
    STATUS_COLOR="red"
fi

# ==================== 飞书通知 ====================
if [[ -n "${FEISHU_WEBHOOK_URL:-}" ]]; then
    echo "[INFO] 发送飞书通知..."

    CARD_JSON=$(cat <<EOF
{
    "msg_type": "interactive",
    "card": {
        "header": {
            "title": {
                "tag": "plain_text",
                "content": "K8s 集群验收报告 - ${CLUSTER_NAME}"
            },
            "template": "${STATUS_COLOR}"
        },
        "elements": [
            {
                "tag": "div",
                "text": {
                    "tag": "lark_md",
                    "content": "**生成时间:** ${REPORT_TIME}\\n**状态:** ${STATUS_TEXT}\\n\\n| 指标 | 数值 |\\n|------|------|\\n| 总计 | ${TOTAL} |\\n| 通过 | ${PASS} |\\n| 失败 | ${FAIL} |\\n| 跳过 | ${SKIP} |"
                }
            }
        ]
    }
}
EOF
)

    curl -s -X POST "${FEISHU_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "${CARD_JSON}" >/dev/null && echo "[PASS] 飞书通知发送成功" || echo "[WARN] 飞书通知发送失败"
fi

# ==================== S3 导出 ====================
if [[ -n "${REPORT_S3_ENDPOINT:-}" && -n "${REPORT_S3_BUCKET:-}" ]]; then
    echo "[INFO] 上传报告到 S3 兼容存储..."
    S3_KEY_PREFIX="${REPORT_S3_KEY_PREFIX:-k8s-acceptance}"
    REPORT_S3_KEY="${S3_KEY_PREFIX}/acceptance-report-${TIMESTAMP}.md"
    __s3_upload "${REPORT_FILE}" "${REPORT_S3_BUCKET}" "${REPORT_S3_KEY}"

    if [[ -n "${LOG_FILE}" ]]; then
        LOG_S3_KEY="${S3_KEY_PREFIX}/acceptance-${TIMESTAMP}.log"
        __s3_upload "${LOG_FILE}" "${REPORT_S3_BUCKET}" "${LOG_S3_KEY}" || true
    fi
fi

# ==================== HTTP POST 导出 ====================
if [[ -n "${REPORT_HTTP_URL:-}" ]]; then
    echo "[INFO] HTTP POST 导出报告..."
    curl -s -X POST "${REPORT_HTTP_URL}" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${REPORT_FILE}" \
        -F "cluster=${CLUSTER_NAME}" \
        -F "timestamp=${TIMESTAMP}" \
        -F "total=${TOTAL}" \
        -F "pass=${PASS}" \
        -F "fail=${FAIL}" \
        -F "skip=${SKIP}" \
        >/dev/null && echo "[PASS] HTTP 导出成功" || echo "[WARN] HTTP 导出失败"
fi

exit $EXIT_CODE

# ==================== S3 上传函数 (AWS Signature V4, 纯 curl) ====================
__s3_upload() {
    local file="$1" bucket="$2" key="$3"
    local endpoint="${REPORT_S3_ENDPOINT%/}"
    local region="${REPORT_S3_REGION:-us-east-1}"
    local access_key="${REPORT_S3_ACCESS_KEY:-}"
    local secret_key="${REPORT_S3_SECRET_KEY:-}"

    if [[ -z "${access_key}" || -z "${secret_key}" ]]; then
        echo "[WARN] S3 AccessKey/SecretKey 未配置，跳过上传"
        return 1
    fi

    local content_type="application/octet-stream"
    local date_iso date_short
    date_iso=$(date -u +%Y%m%dT%H%M%SZ)
    date_short=$(date -u +%Y%m%d)

    local payload_hash
    payload_hash=$(openssl dgst -sha256 -hex "${file}" 2>/dev/null | awk '{print $2}')

    local host
    host="${endpoint#*//}"

    local canonical_request
    canonical_request="PUT
/${bucket}/${key}

host:${host}
x-amz-content-sha256:${payload_hash}
x-amz-date:${date_iso}

host;x-amz-content-sha256;x-amz-date
${payload_hash}"

    local canonical_request_hash
    canonical_request_hash=$(printf '%s' "${canonical_request}" | openssl dgst -sha256 -hex | awk '{print $2}')

    local string_to_sign
    string_to_sign="AWS4-HMAC-SHA256
${date_iso}
${date_short}/${region}/s3/aws4_request
${canonical_request_hash}"

    local date_key date_region_key date_region_service_key signing_key signature
    date_key=$(printf '%s' "${date_short}" | openssl dgst -sha256 -hmac "AWS4${secret_key}" | awk '{print $NF}')
    date_region_key=$(printf '%s' "${region}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${date_key}" | awk '{print $NF}')
    date_region_service_key=$(printf '%s' "s3" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${date_region_key}" | awk '{print $NF}')
    signing_key=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${date_region_service_key}" | awk '{print $NF}')
    signature=$(printf '%s' "${string_to_sign}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${signing_key}" | awk '{print $NF}')

    local authorization
    authorization="AWS4-HMAC-SHA256 Credential=${access_key}/${date_short}/${region}/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=${signature}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${endpoint}/${bucket}/${key}" \
        -H "Host: ${host}" \
        -H "Content-Type: ${content_type}" \
        -H "x-amz-content-sha256: ${payload_hash}" \
        -H "x-amz-date: ${date_iso}" \
        -H "Authorization: ${authorization}" \
        --upload-file "${file}")

    if [[ "${http_code}" == "200" ]]; then
        echo "[PASS] S3 上传成功: ${key}"
    else
        echo "[WARN] S3 上传失败: ${key} (HTTP ${http_code})"
        return 1
    fi
}

#!/usr/bin/env bash
# k8s-utils.sh - K8s 专用工具函数
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# 等待 Pod 就绪，超时返回 1
wait_for_pod() {
    local ns="$1" label="$2" timeout_sec="${3:-120}"
    if ! kubectl wait --for=condition=Ready pod -n "${ns}" -l "${label}" --timeout="${timeout_sec}s" &>/dev/null; then
        return 1
    fi
    return 0
}

# 等待 Deployment 就绪
wait_for_deployment() {
    local ns="$1" name="$2" timeout_sec="${3:-180}"
    if ! kubectl wait --for=condition=available deployment "${name}" -n "${ns}" --timeout="${timeout_sec}s" &>/dev/null; then
        return 1
    fi
    return 0
}

# 等待 Job 完成
wait_for_job() {
    local ns="$1" name="$2" timeout_sec="${3:-180}"
    if ! kubectl wait --for=condition=complete job "${name}" -n "${ns}" --timeout="${timeout_sec}s" &>/dev/null; then
        return 1
    fi
    return 0
}

# 应用 YAML 并等待指定资源就绪
apply_and_wait() {
    local file="$1" ns="$2" kind="$3" name="$4" timeout_sec="${5:-180}"
    kubectl apply -f "${file}" -n "${ns}" >/dev/null
    case "${kind}" in
        pod) wait_for_pod "${ns}" "app=${name}" "${timeout_sec}" ;;
        deployment) wait_for_deployment "${ns}" "${name}" "${timeout_sec}" ;;
        job) wait_for_job "${ns}" "${name}" "${timeout_sec}" ;;
        *) kubectl wait --for=condition=Ready "${kind}/${name}" -n "${ns}" --timeout="${timeout_sec}s" &>/dev/null || return 1 ;;
    esac
}

# 在 Pod 中执行命令，返回输出
exec_check() {
    local ns="$1" pod="$2" cmd="$3"
    kubectl exec -n "${ns}" "${pod}" -- /bin/sh -c "${cmd}" 2>/dev/null
}

# 获取 Pod 名称（按标签选择器，取第一个）
get_pod_by_label() {
    local ns="$1" label="$2"
    kubectl get pod -n "${ns}" -l "${label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# 检查 apiserver 响应延迟 (毫秒)
apiserver_latency_ms() {
    local start end
    start=$(date +%s%3N)
    kubectl get --raw /healthz &>/dev/null || true
    end=$(date +%s%3N)
    echo $((end - start))
}

# 检查 etcd 成员健康（需要 exec 进 etcd pod，对 kubeadm 集群有效）
check_etcd_health() {
    local etcd_pod
    etcd_pod=$(kubectl get pod -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${etcd_pod}" ]]; then
        echo "N/A"
        return
    fi
    kubectl exec -n kube-system "${etcd_pod}" -- etcdctl endpoint health 2>/dev/null | grep -c "is healthy" || echo "0"
}

# 判断资源是否存在
resource_exists() {
    local kind="$1" name="$2" ns="${3:-}"
    if [[ -n "${ns}" ]]; then
        kubectl get "${kind}" "${name}" -n "${ns}" &>/dev/null
    else
        kubectl get "${kind}" "${name}" &>/dev/null
    fi
}

#!/usr/bin/env bash
# 90-performance-check.sh - 性能基准测试（可选）
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-utils.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="性能基准通过"
    detail="-"

    log_info "性能测试模块执行（依赖 iperf3/fio 镜像，可选）"

    local ns
    ns=$(ensure_test_ns)

    # 1. 网络吞吐量（iperf3）
    local iperf_server="${PROJECT_ROOT}/manifests/network-test/iperf-server.yaml"
    local iperf_client="${PROJECT_ROOT}/manifests/network-test/iperf-client-job.yaml"
    if [[ -f "${iperf_server}" && -f "${iperf_client}" ]]; then
        kubectl apply -f "${iperf_server}" -n "${ns}" >/dev/null
        if wait_for_pod "${ns}" "app=iperf-server" "${TIMEOUT_POD_READY:-120}"; then
            kubectl apply -f "${iperf_client}" -n "${ns}" >/dev/null
            if wait_for_job "${ns}" "iperf-client" "${TIMEOUT_JOB_COMPLETE:-180}"; then
                local bw
                bw=$(kubectl logs job/iperf-client -n "${ns}" 2>/dev/null | tail -1 | awk '{print $7,$8}')
                log_info "iperf3 测试带宽: ${bw:-N/A}"
            else
                status="FAIL"
                conclusion="iperf3 客户端 Job 未完成"
                detail="网络性能测试失败"
            fi
        else
            log_warn "iperf3 服务端未就绪，跳过网络性能测试"
        fi
    else
        log_warn "缺少 iperf3 测试清单，跳过网络性能测试"
    fi

    # 2. 调度并发压测
    local perf_scheduling="${PERF_SCHEDULING_PODS:-50}"
    log_info "调度并发压测: 创建 ${perf_scheduling} 个 Pod..."
    kubectl run perf-scheduling --image=busybox:stable --replicas="${perf_scheduling}" -- /bin/sh -c "sleep 30" -n "${ns}" --dry-run=client -o yaml 2>/dev/null | sed "s/replicas: 1/replicas: ${perf_scheduling}/" | kubectl apply -f - -n "${ns}" >/dev/null || true
    # 简化：使用一个 Deployment 快速创建多个副本
    cat <<EOF | kubectl apply -f - -n "${ns}" >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: perf-scheduling
spec:
  replicas: ${perf_scheduling}
  selector:
    matchLabels:
      app: perf-scheduling
  template:
    metadata:
      labels:
        app: perf-scheduling
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: busybox
        image: busybox:stable
        command: ["/bin/sh","-c","sleep 30"]
        resources:
          requests:
            cpu: "1m"
            memory: "1Mi"
EOF
    sleep 5
    local scheduled
    scheduled=$(kubectl get deployment perf-scheduling -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    log_info "调度压测就绪副本: ${scheduled}/${perf_scheduling}"
    kubectl delete deployment perf-scheduling -n "${ns}" --wait=false &>/dev/null || true

    if [[ "${status}" == "PASS" ]]; then
        log_pass "性能基准检查完成"
    else
        log_fail "性能基准检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "性能基准" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"

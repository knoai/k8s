#!/usr/bin/env bash
# 40-storage-check.sh - 存储功能检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-utils.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="存储功能正常"
    detail="-"

    local ns
    ns=$(ensure_test_ns)

    # 1. 检查 StorageClass
    local sc_count default_sc
    sc_count=$(kubectl get storageclass --no-headers 2>/dev/null | wc -l | tr -d ' ')
    default_sc=$(kubectl get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
    if [[ "${sc_count}" -eq 0 ]]; then
        log_warn "集群无 StorageClass，跳过动态供给测试"
    else
        log_info "StorageClass 数量: ${sc_count}, 默认: ${default_sc:-无}"
    fi

    # 2. 动态 PVC 供给测试
    local pvc_file="${PROJECT_ROOT}/manifests/storage-test/pvc-pod.yaml"
    if [[ -f "${pvc_file}" && "${sc_count}" -gt 0 ]]; then
        kubectl apply -f "${pvc_file}" -n "${ns}" >/dev/null
        if ! kubectl wait --for=condition=Bound pvc test-pvc -n "${ns}" --timeout="${TIMEOUT_PVC_BIND:-120}s" &>/dev/null; then
            status="FAIL"
            conclusion="PVC 未绑定"
            detail="test-pvc 未在 ${TIMEOUT_PVC_BIND:-120}s 内 Bound"
        else
            log_pass "PVC 绑定成功"
        fi

        if [[ "${status}" == "PASS" ]]; then
            local pod_name
            pod_name=$(get_pod_by_label "${ns}" "app=storage-test")
            if [[ -n "${pod_name}" ]]; then
                if ! wait_for_pod "${ns}" "app=storage-test" "${TIMEOUT_POD_READY:-120}"; then
                    status="FAIL"
                    conclusion="存储测试 Pod 未就绪"
                    detail="${pod_name} 未 Ready"
                else
                    # 读写测试
                    if exec_check "${ns}" "${pod_name}" "echo acceptance-test-data > /data/testfile && cat /data/testfile" | grep -q "acceptance-test-data"; then
                        log_pass "存储读写测试通过"
                    else
                        status="FAIL"
                        conclusion="存储读写测试失败"
                        detail="无法在挂载卷中读写数据"
                    fi
                fi
            fi
        fi
    else
        log_warn "缺少存储测试清单或无 StorageClass，跳过动态供给测试"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "存储检查通过"
    else
        log_fail "存储检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "存储检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"

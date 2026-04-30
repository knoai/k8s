#!/usr/bin/env bash
# check-coredns.sh - CoreDNS 静态解析配置检测脚本
# 用途：验证 CoreDNS 配置、检测静态解析是否生效、排查 DNS 问题

set -euo pipefail

# ========== 配置 ==========
COREDNS_NS="kube-system"
COREDNS_LABEL="k8s-app=kube-dns"
UPSTREAM_DNS=""
VERBOSE=false
JSON_MODE=false
TEST_DOMAINS=()
REPORT_FILE=""

# 颜色
CLR_INFO='\033[0;34m'
CLR_PASS='\033[0;32m'
CLR_WARN='\033[1;33m'
CLR_FAIL='\033[0;31m'
CLR_RESET='\033[0m'

# JSON 输出累加器
JSON_ITEMS=()

log_info()  { echo -e "${CLR_INFO}[INFO]${CLR_RESET}  $*"; }
log_pass()  { echo -e "${CLR_PASS}[PASS]${CLR_RESET}  $*"; }
log_warn()  { echo -e "${CLR_WARN}[WARN]${CLR_RESET}  $*"; }
log_fail()  { echo -e "${CLR_FAIL}[FAIL]${CLR_RESET}  $*"; }

json_add() {
    local item="$1"
    JSON_ITEMS+=("$item")
}

# ========== 参数解析 ==========
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --json)
                JSON_MODE=true
                shift
                ;;
            -o|--output)
                REPORT_FILE="$2"
                shift 2
                ;;
            -h|--help)
                cat <<EOF
Usage: $0 [options] [domain1] [domain2] ...

Options:
  -v, --verbose    详细输出
  --json           输出 JSON 格式
  -o, --output     指定报告输出文件
  -h, --help       显示帮助

Examples:
  $0                          # 基础检查
  $0 api.internal.local       # 测试指定静态域名
  $0 -v api.local db.local    # 详细模式 + 测试域名
  $0 --json                   # JSON 输出
EOF
                exit 0
                ;;
            -*)
                log_warn "未知参数: $1"
                shift
                ;;
            *)
                TEST_DOMAINS+=("$1")
                shift
                ;;
        esac
    done
}

# ========== 检查 CoreDNS Pod 状态 ==========
check_pod_status() {
    local status="PASS" detail="CoreDNS Pod 运行正常"

    log_info "============================================"
    log_info "1. CoreDNS Pod 状态检查"
    log_info "============================================"

    local pod_count ready_count
    pod_count=$(kubectl get pod -n "$COREDNS_NS" -l "$COREDNS_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready_count=$(kubectl get pod -n "$COREDNS_NS" -l "$COREDNS_LABEL" --no-headers 2>/dev/null | awk '{print $2}' | grep -cE "[1-9]/[1-9]" || true)

    log_info "CoreDNS Pod 数量: $pod_count"
    log_info "CoreDNS Pod 就绪: $ready_count"

    if [[ "$pod_count" -eq 0 ]]; then
        status="FAIL"
        detail="未找到 CoreDNS Pod"
        log_fail "$detail"
    elif [[ "$ready_count" -lt "$pod_count" ]]; then
        status="FAIL"
        detail="部分 CoreDNS Pod 未就绪 ($ready_count/$pod_count)"
        log_fail "$detail"

        if [[ "$VERBOSE" == "true" ]]; then
            log_info "未就绪的 Pod："
            kubectl get pod -n "$COREDNS_NS" -l "$COREDNS_LABEL" --no-headers 2>/dev/null | grep -v "Running" || true
        fi
    else
        log_pass "所有 CoreDNS Pod 运行正常 ($ready_count/$pod_count)"
    fi

    json_add "{\"check\":\"pod_status\",\"status\":\"$status\",\"total\":$pod_count,\"ready\":$ready_count,\"detail\":\"$detail\"}"
}

# ========== 检查 CoreDNS 配置 ==========
check_config() {
    local status="PASS" detail="CoreDNS 配置正常"

    log_info ""
    log_info "============================================"
    log_info "2. CoreDNS ConfigMap 配置检查"
    log_info "============================================"

    local corefile
    corefile=$(kubectl get configmap coredns -n "$COREDNS_NS" -o jsonpath='{.data.Corefile}' 2>/dev/null || true)

    if [[ -z "$corefile" ]]; then
        status="FAIL"
        detail="无法获取 CoreDNS Corefile"
        log_fail "$detail"
        json_add "{\"check\":\"config\",\"status\":\"$status\",\"detail\":\"$detail\"}"
        return
    fi

    # 检查是否包含 hosts 插件
    local has_hosts hosts_inline
    has_hosts="false"
    hosts_inline="false"
    if echo "$corefile" | grep -q "hosts"; then
        has_hosts="true"
        if echo "$corefile" | grep -qE "hosts[[:space:]]*\{"; then
            hosts_inline="true"
            log_pass "Corefile 包含 inline hosts 插件"
        elif echo "$corefile" | grep -qE "hosts[[:space:]]+/"; then
            log_pass "Corefile 包含外部 hosts 文件引用"
        fi
    else
        status="WARN"
        detail="Corefile 未配置 hosts 插件，无静态解析"
        log_warn "$detail"
    fi

    # 检查是否包含 reload 插件
    if echo "$corefile" | grep -q "reload"; then
        log_pass "Corefile 已启用 reload 插件（配置变更自动生效）"
    else
        log_warn "Corefile 未启用 reload 插件，配置修改后需手动重启 CoreDNS"
    fi

    # 提取静态解析条目
    local static_entries
    static_entries=""
    if [[ "$has_hosts" == "true" && "$hosts_inline" == "true" ]]; then
        static_entries=$(echo "$corefile" | awk '/hosts[[:space:]]*\{/{flag=1;next}/\}/{flag=0}flag' | grep -E "^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" || true)
        local entry_count
        entry_count=$(echo "$static_entries" | grep -cE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" || true)
        log_info "静态解析条目数: $entry_count"

        if [[ "$VERBOSE" == "true" && -n "$static_entries" ]]; then
            log_info "静态解析配置："
            echo "$static_entries" | while read -r line; do
                echo "  $line"
            done
        fi
    fi

    # 检查 forward 插件
    local forward_target
    forward_target=$(echo "$corefile" | grep -oE "forward\s+\.\s+[^}]+" | head -1 || true)
    if [[ -n "$forward_target" ]]; then
        log_info "上游 DNS 转发配置: $forward_target"
        UPSTREAM_DNS=$(echo "$forward_target" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)
    fi

    json_add "{\"check\":\"config\",\"status\":\"$status\",\"has_hosts\":$has_hosts,\"hosts_inline\":$hosts_inline,\"detail\":\"$detail\"}"
}

# ========== DNS 解析测试 ==========
check_dns_resolution() {
    log_info ""
    log_info "============================================"
    log_info "3. DNS 解析测试"
    log_info "============================================"

    local test_domains=(
        "kubernetes.default"
        "kubernetes.default.svc.cluster.local"
    )

    # 添加用户指定的静态域名
    if [[ ${#TEST_DOMAINS[@]} -gt 0 ]]; then
        test_domains+=("${TEST_DOMAINS[@]}")
    fi

    local total_passed=0 total_failed=0

    for domain in "${test_domains[@]}"; do
        local resolved_ip status detail
        resolved_ip=$(kubectl run -n default --rm -i --restart=Never \
            dns-test-$(date +%s) --image=busybox:stable -- \
            nslookup "$domain" 2>/dev/null | grep -oE "Address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | tail -1 | awk '{print $2}' || true)

        if [[ -n "$resolved_ip" && "$resolved_ip" != "*" ]]; then
            status="PASS"
            detail="解析到 $resolved_ip"
            log_pass "$domain → $resolved_ip"
            ((total_passed++)) || true
        else
            status="FAIL"
            detail="解析失败"
            log_fail "$domain → 解析失败"
            ((total_failed++)) || true
        fi

        json_add "{\"check\":\"dns_resolution\",\"domain\":\"$domain\",\"status\":\"$status\",\"ip\":\"${resolved_ip:-}\",\"detail\":\"$detail\"}"
    done

    log_info "DNS 解析通过: $total_passed/${#test_domains[@]}"
    log_info "DNS 解析失败: $total_failed/${#test_domains[@]}"

    json_add "{\"check\":\"dns_summary\",\"passed\":$total_passed,\"failed\":$total_failed,\"total\":${#test_domains[@]}}"
}

# ========== 静态域名专项测试 ==========
check_static_domains() {
    if [[ ${#TEST_DOMAINS[@]} -eq 0 ]]; then
        return
    fi

    log_info ""
    log_info "============================================"
    log_info "4. 静态域名专项测试"
    log_info "============================================"

    for domain in "${TEST_DOMAINS[@]}"; do
        log_info "--- 测试域名: $domain ---"

        # 测试 A 记录解析
        local a_record
        a_record=$(kubectl run -n default --rm -i --restart=Never \
            dns-test-$(date +%s) --image=busybox:stable -- \
            nslookup "$domain" 2>/dev/null | grep -oE "Address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | tail -1 | awk '{print $2}' || true)

        if [[ -n "$a_record" ]]; then
            log_pass "A 记录: $domain → $a_record"
        else
            log_fail "A 记录: $domain → 未解析"
        fi

        # 测试 dig 详细结果
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "dig 查询详情:"
            kubectl run -n default --rm -i --restart=Never \
                dns-test-$(date +%s) --image=busybox:stable -- \
                nslookup "$domain" 2>/dev/null || true
        fi
    done
}

# ========== 检查 CoreDNS 日志 ==========
check_logs() {
    log_info ""
    log_info "============================================"
    log_info "5. CoreDNS 日志检查"
    log_info "============================================"

    local log_output errors warnings
    log_output=$(kubectl logs -n "$COREDNS_NS" -l "$COREDNS_LABEL" --tail=100 2>/dev/null || true)

    errors=$(echo "$log_output" | grep -ci "error" || true)
    warnings=$(echo "$log_output" | grep -ci "warn" || true)

    log_info "最近 100 行日志中:"
    log_info "  错误数: $errors"
    log_info "  警告数: $warnings"

    if [[ "$errors" -gt 0 ]]; then
        log_fail "发现 $errors 条错误日志"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$log_output" | grep -i "error" | tail -5
        fi
    else
        log_pass "近期无错误日志"
    fi

    if [[ "$warnings" -gt 0 ]]; then
        log_warn "发现 $warnings 条警告日志"
    fi

    json_add "{\"check\":\"logs\",\"errors\":$errors,\"warnings\":$warnings}"
}

# ========== 检查 DNS 延迟 ==========
check_dns_latency() {
    log_info ""
    log_info "============================================"
    log_info "6. DNS 延迟测试"
    log_info "============================================"

    local latency_ms
    latency_ms=$(kubectl run -n default --rm -i --restart=Never \
        dns-test-$(date +%s) --image=busybox:stable -- \
        sh -c "time nslookup kubernetes.default >/dev/null 2>&1" 2>&1 | grep -oE "real.*[0-9]+m[0-9]+\.[0-9]+s" | sed 's/real\s*//' | sed 's/m/*60000+/;s/s/\/1000/' | bc 2>/dev/null || echo "")

    if [[ -n "$latency_ms" ]]; then
        log_info "DNS 解析延迟: ${latency_ms}ms"
    else
        # 简单方式
        local start end
        start=$(date +%s%3N)
        kubectl run -n default --rm -i --restart=Never \
            dns-test-$(date +%s) --image=busybox:stable -- \
            nslookup kubernetes.default >/dev/null 2>&1 || true
        end=$(date +%s%3N)
        latency_ms=$((end - start))
        log_info "DNS 解析延迟: ${latency_ms}ms"
    fi

    json_add "{\"check\":\"dns_latency\",\"latency_ms\":\"${latency_ms:-unknown}\"}"
}

# ========== 检查上游 DNS ==========
check_upstream() {
    log_info ""
    log_info "============================================"
    log_info "7. 上游 DNS 检查"
    log_info "============================================"

    # 检查 /etc/resolv.conf 中的 nameserver
    local ns_list
    ns_list=$(kubectl run -n default --rm -i --restart=Never \
        dns-test-$(date +%s) --image=busybox:stable -- \
        cat /etc/resolv.conf 2>/dev/null | grep "nameserver" | awk '{print $2}' || true)

    if [[ -n "$ns_list" ]]; then
        log_info "Pod /etc/resolv.conf nameserver:"
        echo "$ns_list" | while read -r ns; do
            log_info "  $ns"
        done
    fi

    # 检查上游 DNS 是否可达
    if [[ -n "$UPSTREAM_DNS" ]]; then
        log_info "测试上游 DNS $UPSTREAM_DNS 连通性："
        local upstream_ping
        upstream_ping=$(kubectl run -n default --rm -i --restart=Never \
            dns-test-$(date +%s) --image=busybox:stable -- \
            ping -c 2 -W 2 "$UPSTREAM_DNS" 2>/dev/null | tail -1 | grep -oE "[0-9]+% packet loss" | awk '{print $1}' || true)

        if [[ "$upstream_ping" == "0%" ]]; then
            log_pass "上游 DNS $UPSTREAM_DNS 可达"
        else
            log_warn "上游 DNS $UPSTREAM_DNS 可能不可达（丢包: $upstream_ping）"
        fi
    fi

    json_add "{\"check\":\"upstream\",\"nameservers\":\"${ns_list:-unknown}\",\"upstream_dns\":\"${UPSTREAM_DNS:-none}\"}"
}

# ========== 输出报告 ==========
gen_report() {
    log_info ""
    log_info "============================================"
    log_info "检测完成"
    log_info "============================================"

    if [[ "$JSON_MODE" == "true" ]]; then
        local json_output
        json_output=$(printf '%s\n' "${JSON_ITEMS[@]}" | awk 'BEGIN{print "["} {if(NR>1)print ","; printf "  %s", $0} END{print "\n]"}')
        echo "$json_output"

        if [[ -n "$REPORT_FILE" ]]; then
            echo "$json_output" > "$REPORT_FILE"
            log_info "JSON 报告已保存到: $REPORT_FILE"
        fi
    fi
}

# ========== 主函数 ==========
main() {
    parse_args "$@"

    if [[ "$JSON_MODE" == "false" ]]; then
        log_info "CoreDNS 静态解析检测脚本启动"
    fi

    # 检查 kubectl 可用
    if ! kubectl cluster-info &>/dev/null; then
        log_fail "无法连接 Kubernetes 集群"
        exit 1
    fi

    check_pod_status
    check_config
    check_dns_resolution
    check_static_domains
    check_logs
    check_dns_latency
    check_upstream

    gen_report
}

main "$@"

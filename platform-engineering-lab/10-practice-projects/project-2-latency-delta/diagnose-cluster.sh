#!/bin/bash
# 多集群延迟差异诊断脚本
# 对比健康集群 A 和问题集群 B 的各项指标
# 用于 platform-engineering-lab 项目 2
# 覆盖 DNS → CNI → 节点 → Pod 全链路诊断

set -euo pipefail

echo "=============================================="
echo "  多集群延迟差异诊断"
echo "  时间: $(date -Iseconds)"
echo "=============================================="
echo ""
echo "本脚本将对比两个 Kind 集群:"
echo "  Cluster A: 健康基线（正确配置）"
echo "  Cluster B: 问题集群（配置错误）"
echo ""
echo "诊断层次:"
echo "  1. 基础检查（版本、节点、事件）"
echo "  2. DNS（CoreDNS 配置、ndots、解析时间）"
echo "  3. CNI（插件类型、跨节点延迟、iptables 规则）"
echo "  4. 应用（Pod 状态、资源、延迟测试）"
echo ""

# 切换到 kind 集群
switch_cluster() {
  local cluster_name=$1
  echo "=== 切换上下文到: $cluster_name ==="
  kubectl config use-context "kind-$cluster_name" 2>/dev/null || {
    echo "  错误: 无法切换到 kind-$cluster_name"
    echo "  可用的上下文:"
    kubectl config get-contexts -o name
    return 1
  }
}

# 1. 基础检查
check_basic() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - 基础检查"
  echo "========================================"
  
  echo "--- K8s 版本 ---"
  kubectl version --short 2>/dev/null || kubectl version
  
  echo ""
  echo "--- 节点状态 ---"
  kubectl get nodes -o wide
  
  echo ""
  echo "--- 节点资源 (kubectl top) ---"
  kubectl top nodes 2>/dev/null || echo "  metrics-server 不可用"
  
  echo ""
  echo "--- 最近 Warning 事件（最近 10 条）---"
  kubectl get events --field-selector type=Warning --sort-by='.lastTimestamp' | tail -10 || echo "  无 Warning 事件"
  
  echo ""
  echo "--- 系统组件状态 ---"
  kubectl get pods -n kube-system
  
  echo ""
}

# 2. DNS 检查
check_dns() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - DNS 检查"
  echo "========================================"
  
  local coredns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [ -z "$coredns_pods" ]; then
    echo "  警告: 未找到 CoreDNS Pod"
    echo ""
    return
  fi
  
  echo "CoreDNS Pod: $coredns_pods"
  echo "CoreDNS 副本数: $(echo $coredns_pods | wc -w)"
  
  echo ""
  echo "--- CoreDNS 配置 (Corefile) ---"
  kubectl get configmap coredns -n kube-system -o yaml 2>/dev/null | grep -A 15 "Corefile" | head -20 || echo "  无法获取 Corefile"
  
  echo ""
  echo "--- CoreDNS 日志（最近 ERROR）---"
  for pod in $coredns_pods; do
    echo "Pod $pod:"
    kubectl logs "$pod" -n kube-system --tail=30 2>/dev/null | grep -iE "error|fail|timeout| SERVFAIL" | tail -3 || echo "  无 ERROR 日志"
  done
  
  echo ""
  echo "--- CoreDNS 资源使用 ---"
  kubectl top pods -n kube-system -l k8s-app=kube-dns 2>/dev/null || echo "  metrics-server 不可用"
  
  echo ""
  
  # 检查 ndots 配置
  echo "--- Pod DNS 配置 (ndots) ---"
  kubectl run tmp-dns-check --image=busybox:1.36 --rm -i --restart=Never -- \
    cat /etc/resolv.conf 2>/dev/null || echo "  无法检查 resolv.conf"
  
  echo ""
  echo "--- DNS 解析时间测试 ---"
  echo "测试 1: nslookup kubernetes.default"
  kubectl run tmp-dns-test1 --image=busybox:1.36 --rm -i --restart=Never -- \
    sh -c "time nslookup kubernetes.default" 2>/dev/null || echo "  DNS 解析失败"
  
  echo ""
  echo "测试 2: 带 search 域的解析（模拟 ndots:5 问题）"
  kubectl run tmp-dns-test2 --image=busybox:1.36 --rm -i --restart=Never -- \
    sh -c "time nslookup kubernetes.default.svc.cluster.local" 2>/dev/null || echo "  解析失败"
  
  echo ""
}

# 3. CoreDNS 指标
check_coredns_metrics() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - CoreDNS 指标"
  echo "========================================"
  
  local coredns_pod=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -n "$coredns_pod" ]; then
    echo "尝试获取 CoreDNS metrics（端口 9153）..."
    kubectl exec "$coredns_pod" -n kube-system -- wget -qO- http://localhost:9153/metrics 2>/dev/null | \
      grep -E "coredns_cache_hits_total|coredns_cache_misses_total|coredns_dns_request_duration_seconds_bucket|coredns_dns_request_count_total|coredns_forward_request_duration_seconds" | \
      head -15 || echo "  CoreDNS metrics 端口未暴露或 metrics 未启用"
  fi
  
  echo ""
}

# 4. CNI 检查
check_cni() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - CNI 检查"
  echo "========================================"
  
  echo "--- CNI 插件类型 ---"
  local cni=""
  if kubectl get pods -n kube-system -l app=flannel 2>/dev/null | grep -q flannel; then
    echo "  CNI: Flannel（VXLAN/UDP 后端）"
    cni="flannel"
  elif kubectl get pods -n kube-system -l k8s-app=calico-node 2>/dev/null | grep -q calico; then
    echo "  CNI: Calico（BGP/eBPF 模式）"
    cni="calico"
  elif kubectl get pods -n kube-system -l k8s-app=cilium 2>/dev/null | grep -q cilium; then
    echo "  CNI: Cilium（eBPF 模式）"
    cni="cilium"
  elif kubectl get pods -n kube-system -l app=weave-net 2>/dev/null | grep -q weave; then
    echo "  CNI: Weave Net"
    cni="weave"
  else
    echo "  CNI: 未识别（可能是 kindnetd）"
    cni="unknown"
  fi
  
  echo ""
  echo "--- CNI Pod 状态 ---"
  kubectl get pods -n kube-system | grep -E "calico|flannel|cilium|weave|kube-proxy|kindnet"
  
  echo ""
  echo "--- CNI Pod 资源使用 ---"
  kubectl top pods -n kube-system | grep -E "calico|flannel|cilium|weave|kube-proxy|kindnet" 2>/dev/null || echo "  metrics-server 不可用"
  
  echo ""
  echo "--- iptables 规则数量 ---"
  local kube_proxy=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$kube_proxy" ]; then
    echo "kube-proxy Pod: $kube_proxy"
    echo "KUBE-SERVICES 规则数:"
    kubectl exec "$kube_proxy" -n kube-system -- iptables -t nat -L KUBE-SERVICES --line-numbers 2>/dev/null | wc -l | xargs -I{} echo "  {} 条规则"
    echo "KUBE-POSTROUTING 规则数:"
    kubectl exec "$kube_proxy" -n kube-system -- iptables -t nat -L KUBE-POSTROUTING 2>/dev/null | wc -l | xargs -I{} echo "  {} 条规则"
  fi
  
  echo ""
  
  # 跨节点 ping 测试
  echo "--- 跨节点网络延迟 ---"
  local nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
  if [ -n "$nodes" ]; then
    for node in $nodes; do
      echo "Ping $node:"
      kubectl run tmp-ping --image=busybox:1.36 --rm -i --restart=Never -- \
        ping -c 3 -W 2 "$node" 2>/dev/null | tail -3 || echo "  ping 失败"
    done
  fi
  
  echo ""
}

# 5. 应用 Pod 检查
check_pods() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - 应用 Pod 检查"
  echo "========================================"
  
  echo "--- 所有 Pod（含命名空间） ---"
  kubectl get pods -A -o wide
  
  echo ""
  echo "--- Pod 资源使用 ---"
  kubectl top pods -A 2>/dev/null || echo "  metrics-server 不可用"
  
  echo ""
  echo "--- 异常 Pod（非 Running/Completed） ---"
  kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded 2>/dev/null || echo "  无异常 Pod"
  
  echo ""
  echo "--- Pod 事件（最近 5 条） ---"
  kubectl get events --field-selector reason=FailedScheduling,reason=FailedMount,reason=ImagePullBackOff --sort-by='.lastTimestamp' | tail -5 || echo "  无异常事件"
  
  echo ""
}

# 6. 延迟对比测试
latency_test() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - 延迟对比测试"
  echo "========================================"
  
  echo "--- HTTP 延迟测试 (curl -w time decomposition) ---"
  echo "字段说明:"
  echo "  time_namelookup  = DNS 解析时间"
  echo "  time_connect     = TCP 连接建立时间"
  echo "  time_appconnect  = TLS 握手时间（如有）"
  echo "  time_pretransfer = 请求发送前时间"
  echo "  time_starttransfer = TTFB（首字节时间）"
  echo "  time_total       = 总时间"
  echo ""
  
  local svc_url=""
  local svc=$(kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || echo "")
  
  if [ -n "$svc" ]; then
    local ns=$(echo "$svc" | cut -d'/' -f1)
    local name=$(echo "$svc" | cut -d'/' -f2)
    local nodeport=$(kubectl get svc "$name" -n "$ns" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    if [ -n "$nodeport" ]; then
      svc_url="http://localhost:$nodeport"
      echo "测试服务: $svc_url"
      echo ""
      
      for i in 1 2 3; do
        echo "请求 $i:"
        curl -o /dev/null -s -w \
"  DNS解析: %{time_namelookup}s
  TCP连接: %{time_connect}s
  TTFB:    %{time_starttransfer}s
  总时间:  %{time_total}s\n" \
          "$svc_url" 2>/dev/null || echo "  请求失败"
        echo ""
      done
    fi
  else
    echo "  未找到 NodePort 服务"
  fi
  
  echo ""
}

# 7. 自动诊断摘要
diagnosis_summary() {
  local cluster=$1
  echo "========================================"
  echo "集群 $cluster - 诊断摘要"
  echo "========================================"
  echo ""
  echo "请手动对比以下关键指标:"
  echo ""
  echo "  DNS 层:"
  echo "    - ndots 配置（Cluster A: ndots:5 vs Cluster B: 可能不同）"
  echo "    - CoreDNS 副本数（Cluster A: 2 vs Cluster B: 1）"
  echo "    - DNS 解析时间（正常 < 5ms，异常 > 50ms）"
  echo ""
  echo "  CNI 层:"
  echo "    - CNI 插件类型（不同插件延迟差异显著）"
  echo "    - 跨节点 ping 延迟（正常 < 1ms，异常 > 5ms）"
  echo "    - iptables 规则数量（过多增加处理延迟）"
  echo ""
  echo "  应用层:"
  echo "    - Pod CPU/内存使用（是否接近 limit）"
  echo "    - 异常 Pod/事件（ImagePullBackOff、CrashLoopBackOff）"
  echo "    - HTTP 延迟分解（DNS vs TCP vs TTFB）"
  echo ""
}

# 主流程
main() {
  echo "========================================"
  echo "开始对比诊断"
  echo "========================================"
  echo ""
  
  # 集群 A
  if switch_cluster "cluster-a"; then
    check_basic "cluster-a"
    check_dns "cluster-a"
    check_coredns_metrics "cluster-a"
    check_cni "cluster-a"
    check_pods "cluster-a"
    latency_test "cluster-a"
    diagnosis_summary "cluster-a"
  fi
  
  echo ""
  echo "########################################"
  echo "#                                      #"
  echo "#    Cluster B 诊断开始                #"
  echo "#                                      #"
  echo "########################################"
  echo ""
  
  # 集群 B
  if switch_cluster "cluster-b"; then
    check_basic "cluster-b"
    check_dns "cluster-b"
    check_coredns_metrics "cluster-b"
    check_cni "cluster-b"
    check_pods "cluster-b"
    latency_test "cluster-b"
    diagnosis_summary "cluster-b"
  fi
  
  echo ""
  echo "=============================================="
  echo "  诊断完成"
  echo ""
  echo "  常见延迟差异根因（按频率排序）:"
  echo "    1. DNS: ndots 配置差异、CoreDNS 副本不足、上游 DNS 超时"
  echo "    2. CNI: eBPF vs iptables、跨节点网络抖动、MTU 不一致"
  echo "    3. 应用: 连接池耗尽、JVM GC、CPU throttling"
  echo "    4. 节点: 磁盘 I/O 瓶颈、网络带宽饱和、NUMA 亲和性"
  echo ""
  echo "  面试知识点:"
  echo "    Q: CoreDNS ndots:5 导致的问题？"
  echo "    A: 查询 'foo' 时，会依次尝试:"
  echo "       foo.default.svc.cluster.local."
  echo "       foo.svc.cluster.local."
  echo "       foo.cluster.local."
  echo "       foo."
  echo "       每次失败增加 ~5ms DNS 延迟，总计 ~20ms+"
  echo "    解决: 使用 FQDN（末尾加 .）或调整 ndots"
  echo ""
  echo "    Q: CNI 插件延迟对比？"
  echo "    A: Cilium eBPF < Calico eBPF < Calico iptables < Flannel VXLAN"
  echo "       差距可达 30-50%（尤其在 Pod-Pod 通信场景）"
  echo "=============================================="
}

main "$@"

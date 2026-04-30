#!/bin/bash
# Service Mesh 延迟诊断脚本
# 检查 Envoy Sidecar 配置、统计、mTLS 状态、WASM filter、路由配置
# 用于 platform-engineering-lab 项目 5
# 输出包含自动建议和面试级分析

set -euo pipefail

APP_NAME=${1:-""}
if [ -z "$APP_NAME" ]; then
  echo "用法: $0 <app-name>"
  echo ""
  echo "示例:"
  echo "  $0 app-b    # 诊断 STRICT mTLS 应用"
  echo "  $0 app-c    # 诊断 PERMISSIVE mTLS 应用"
  echo ""
  echo "可用应用:"
  kubectl get pods -n mesh-lab -l app -o jsonpath='{range .items[*]}{.metadata.labels.app}{"\n"}{end}' 2>/dev/null || echo "  无"
  exit 1
fi

NAMESPACE="mesh-lab"
APP_POD=$(kubectl get pod -n "$NAMESPACE" -l app="$APP_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$APP_POD" ]; then
  echo "错误: 未找到应用 Pod (app=$APP_NAME)"
  exit 1
fi

echo "=============================================="
echo "  Service Mesh 延迟诊断报告"
echo "  应用: $APP_NAME"
echo "  Pod: $APP_POD"
echo "  命名空间: $NAMESPACE"
echo "  时间: $(date -Iseconds)"
echo "=============================================="
echo ""

# 检查是否有 Sidecar
SIDECAR_READY=$(kubectl get pod "$APP_POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="istio-proxy")].ready}' 2>/dev/null || echo "")
if [ "$SIDECAR_READY" = "true" ]; then
  echo "Sidecar 状态: 就绪 ✓"
  HAS_SIDECAR=1
elif [ -z "$SIDECAR_READY" ]; then
  echo "Sidecar 状态: 无 Sidecar（基线对照应用）"
  HAS_SIDECAR=0
else
  echo "Sidecar 状态: 未就绪 ✗"
  HAS_SIDECAR=0
fi
echo ""

# 1. Envoy 版本和配置
echo "========================================"
echo "1. Envoy Server Info"
echo "========================================"
if [ "$HAS_SIDECAR" -eq 1 ]; then
  echo "Envoy 版本和运行状态:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/server_info 2>/dev/null | jq -r '{version: .version, state: .state, uptime_current_epoch: .uptime_current_epoch, concurrency: .command_line_options.concurrency, hot_restart_version: .hot_restart_version}' || echo "  无法获取 Envoy 信息"
else
  echo "  跳过（无 Sidecar）"
fi
echo ""

# 2. Cluster 统计
echo "========================================"
echo "2. Upstream Cluster 统计"
echo "========================================"
if [ "$HAS_SIDECAR" -eq 1 ]; then
  echo "关键指标说明:"
  echo "  cx_active      = 活跃连接数"
  echo "  cx_connect_ms  = 连接建立时间(ms)"
  echo "  rq_active      = 活跃请求数"
  echo "  rq_success     = 成功请求数"
  echo "  rq_time        = 请求处理时间分布"
  echo "  rq_5xx         = 5xx 错误数"
  echo ""
  echo "Cluster 统计:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/clusters 2>/dev/null | grep -E "::|cx_active|rq_active|rq_success|rq_time|rq_5xx|cx_connect_ms" | head -40 || echo "  无法获取 cluster 统计"
else
  echo "  跳过（无 Sidecar）"
fi
echo ""

# 3. mTLS 状态
echo "========================================"
echo "3. mTLS 连接统计"
echo "========================================"
if [ "$HAS_SIDECAR" -eq 1 ]; then
  echo "connection_security_policy 分布:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "istio_requests_total.*connection_security_policy" | head -10 || echo "  无法获取 mTLS 统计"
  
  echo ""
  echo "SSL/TLS 握手统计:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "ssl.handshake|ssl.session_reused|ssl.fail_verify_san|ssl.fail_verify_error" | head -10 || echo "  无 SSL 统计"
  
  echo ""
  echo "证书信息:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/certs 2>/dev/null | jq '.certificates[0] | {serial: .serial_number, valid_from: .valid_from, valid_to: .valid_to, expire_seconds: .days_until_expiration}' 2>/dev/null || echo "  无法获取证书信息"
else
  echo "  跳过（无 Sidecar）"
fi
echo ""

# 4. WASM filter 统计
echo "========================================"
echo "4. WASM Filter 统计"
echo "========================================"
if [ "$HAS_SIDECAR" -eq 1 ]; then
  WASM_STATS=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "wasm" | head -15 || echo "")
  if [ -n "$WASM_STATS" ]; then
    echo "$WASM_STATS"
  else
    echo "  未启用 WASM filter"
  fi
else
  echo "  跳过（无 Sidecar）"
fi
echo ""

# 5. Listener 配置
echo "========================================"
echo "5. Listener 配置摘要"
echo "========================================"
if [ "$HAS_SIDECAR" -eq 1 ]; then
  echo "Listener 列表:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/listeners 2>/dev/null | jq -r '.[] | {name: .name, address: .address.socket_address, filter_chains_count: (.filter_chains | length), traffic_direction: .traffic_direction}' 2>/dev/null | head -15 || echo "  无法获取 listener 配置"
  
  echo ""
  echo "出站 Listener 数量:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/listeners 2>/dev/null | jq '[.[] | select(.traffic_direction == "OUTBOUND")] | length' 2>/dev/null || echo "  无法统计"
else
  echo "  跳过（无 Sidecar）"
fi
echo ""

# 6. 检查 PeerAuthentication
echo "========================================"
echo "6. PeerAuthentication 策略"
echo "========================================"
echo "PeerAuthentication 资源:"
kubectl get peerauthentication -n "$NAMESPACE" -o yaml 2>/dev/null | grep -B 5 -A 5 "matchLabels" | grep -E "matchLabels|mode:|name:" | head -15 || echo "  未找到 PeerAuthentication"

echo ""
echo "DestinationRule（如果配置了 mTLS）:"
kubectl get destinationrule -n "$NAMESPACE" -o yaml 2>/dev/null | grep -B 3 -A 3 "mode:" | head -15 || echo "  未找到 DestinationRule"
echo ""

# 7. Sidecar 资源使用
echo "========================================"
echo "7. Sidecar 资源使用"
echo "========================================"
echo "Pod 资源使用:"
kubectl top pod "$APP_POD" -n "$NAMESPACE" --containers 2>/dev/null || echo "  metrics-server 不可用"

echo ""
echo "Sidecar 配置的资源限制:"
kubectl get pod "$APP_POD" -n "$NAMESPACE" -o jsonpath='{range .spec.containers[?(@.name=="istio-proxy")].resources}{"  limits: "}{.limits}{"\n  requests: "}{.requests}{"\n"}{end}' 2>/dev/null || echo "  无法获取"
echo ""

# 8. Envoy 配置差异
echo "========================================"
echo "8. Envoy 配置差异分析"
echo "========================================"
if [ "$HAS_SIDECAR" -eq 1 ]; then
  echo "Bootstrap 配置摘要:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/config_dump 2>/dev/null | jq '.configs[0] | {node: .bootstrap.node.id, static_listeners: (.bootstrap.static_resources.listeners | length), clusters: (.bootstrap.static_resources.clusters | length)}' 2>/dev/null || echo "  无法获取"
  
  echo ""
  echo "动态 RDS 路由数量:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/config_dump 2>/dev/null | jq '[.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.RoutesConfigDump")] | length' 2>/dev/null || echo "  无法统计"
else
  echo "  跳过（无 Sidecar）"
fi
echo ""

# 9. 自动诊断建议
echo "========================================"
echo "9. 自动诊断建议"
echo "========================================"

WARNINGS=0

# 检查 mTLS 模式
MTLS_MODE=$(kubectl get peerauthentication -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A 2 "matchLabels" | grep "$APP_NAME" -A 2 | grep "mode:" | awk '{print $2}' || echo "")
if [ -n "$MTLS_MODE" ]; then
  echo "mTLS 模式: $MTLS_MODE"
  case "$MTLS_MODE" in
    *STRICT*)
      echo "  影响: 每次新连接需要 TLS 握手（5-15ms）"
      echo "  症状: P50 增加 ~3ms，P99 增加 ~10ms（冷连接）"
      echo "  优化建议:"
      echo "    - 增大连接池复用（keepalive，减少握手次数）"
      echo "    - 内部服务可考虑 PERMISSIVE（权衡安全与性能）"
      echo "    - 使用 connectionPool.tcp.maxConnections 限制并发"
      echo "    - 启用会话恢复（session resumption）"
      WARNINGS=$((WARNINGS + 1))
      ;;
    *PERMISSIVE*)
      echo "  影响: 允许明文和 mTLS 共存"
      echo "  建议: 生产环境建议逐步切换到 STRICT"
      echo "  迁移策略:"
      echo "    Phase 1: 全局 PERMISSIVE（允许明文）"
      echo "    Phase 2: 核心服务 STRICT"
      echo "    Phase 3: 全局 STRICT"
      ;;
  esac
else
  echo "mTLS 模式: 未配置（默认 PERMISSIVE）"
fi

# 检查 WASM filter
if [ "$HAS_SIDECAR" -eq 1 ]; then
  WASM_COUNT=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -c "wasm" || echo "0")
  if [ "$WASM_COUNT" -gt 0 ]; then
    echo ""
    echo "WASM filter: 检测到 $WASM_COUNT 个 WASM 相关指标"
    echo "  影响: 每个 WASM filter 增加 ~0.1-1ms 延迟"
    echo "  建议: 评估是否所有 filter 都是必需的"
    echo "  优化: 简化 filter 逻辑，减少上下文切换"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# 检查 Sidecar 资源
if [ "$HAS_SIDECAR" -eq 1 ]; then
  SIDECAR_CPU=$(kubectl top pod "$APP_POD" -n "$NAMESPACE" --containers 2>/dev/null | grep istio-proxy | awk '{print $2}' || echo "")
  if [ -n "$SIDECAR_CPU" ]; then
    echo ""
    echo "Sidecar CPU 使用: $SIDECAR_CPU"
    CPU_VAL=$(echo "$SIDECAR_CPU" | sed 's/m//')
    if [ -n "$CPU_VAL" ] && [ "$CPU_VAL" -gt 800 ] 2>/dev/null; then
      echo "  ⚠️ 警告: Sidecar CPU 使用率接近 limit"
      echo "  影响: CPU 受限时 Envoy 处理延迟增加"
      echo "  建议: 增加 Sidecar CPU limit 或优化 filter"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# 检查 Listener 数量
if [ "$HAS_SIDECAR" -eq 1 ]; then
  LISTENER_COUNT=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -c istio-proxy -- curl -s localhost:15000/listeners 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
  if [ -n "$LISTENER_COUNT" ] && [ "$LISTENER_COUNT" -gt 500 ] 2>/dev/null; then
    echo ""
    echo "⚠️ 警告: Listener 数量 $LISTENER_COUNT（过多）"
    echo "  影响: 每个请求需要遍历更多 listener 匹配，增加延迟"
    echo "  原因: 命名空间内服务过多，或 Sidecar 导出范围过大"
    echo "  建议: 使用 Sidecar CRD 限制导出服务范围"
    echo ""
    echo "  Sidecar CRD 示例:"
    echo "    apiVersion: networking.istio.io/v1beta1"
    echo "    kind: Sidecar"
    echo "    metadata:"
    echo "      name: default"
    echo "      namespace: mesh-lab"
    echo "    spec:"
    echo "      egress:"
    echo "      - hosts:"
    echo "        - mesh-lab/*    # 只导出同命名空间服务"
    echo "        - istio-system/* # 系统服务"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

if [ "$WARNINGS" -eq 0 ]; then
  echo "✓ 未发现明显问题"
fi

echo ""
echo "========================================"
echo "面试知识点"
echo "========================================"
echo "Q: Istio Sidecar 增加多少延迟？"
echo "A:"
echo "  基线（无 mTLS）:"
echo "    P50: ~0.3ms, P99: ~1-3ms"
echo ""
echo "  mTLS STRICT:"
echo "    增加 3-10ms（取决于连接复用程度）"
echo "    冷连接（首次握手）: ~10-15ms"
echo "    热连接（会话复用）: ~1-3ms"
echo ""
echo "  WASM filter:"
echo "    每个 filter 增加 ~0.1-1ms"
echo ""
echo "  优化后（连接复用 + 无 WASM）:"
echo "    P50: ~0.5ms, P99: ~2ms"
echo ""
echo "Q: 如何优化 Service Mesh 延迟？"
echo "A:"
echo "  1. 连接池复用（keepalive）"
echo "     减少 TLS 握手次数，降低连接建立开销"
echo ""
echo "  2. 减少 listener/cluster 数量"
echo "     使用 Sidecar CRD 限制服务可见范围"
echo ""
echo "  3. 评估 mTLS 必要性"
echo "     内部服务可用 PERMISSIVE，边界服务用 STRICT"
echo ""
echo "  4. 限制 WASM filter 数量和复杂度"
echo "     每个 filter 都有上下文切换开销"
echo ""
echo "  5. 调整 Sidecar 资源"
echo "     确保 CPU/memory limit 不会成为瓶颈"
echo ""
echo "  6. 使用 eBPF 加速（Cilium + Istio）"
echo "     绕过 iptables，减少数据包处理跳数"
echo ""
echo "Q: Istio vs Linkerd vs Cilium Service Mesh？"
echo "A:"
echo "  Istio:"
echo "    - 功能最丰富（mTLS、流量管理、可观测性）"
echo "    - 延迟中等，资源占用高"
echo "    - 社区最大，企业支持最好"
echo ""
echo "  Linkerd:"
echo "    - 轻量，延迟低"
echo "    - 功能相对简单"
echo "    - 适合中小规模集群"
echo ""
echo "  Cilium Service Mesh:"
echo "    - eBPF 数据面，延迟最低"
echo "    - Sidecar-less 架构（或使用 sidecar）"
echo "    - 与 CNI 深度集成"
echo ""
echo "  选择: 功能需求高选 Istio，性能优先选 Cilium，简单场景选 Linkerd"
echo ""

echo "=============================================="
echo "  Service Mesh 诊断完成"
echo "=============================================="

# 13 - 性能基准测试

性能基准测试是平台工程的核心交付物之一。没有量化的性能数据，
所有架构决策都是凭感觉。本章提供可复现的基准测试方法论、
工具链和参考数据，帮助团队建立性能基线并追踪回归。

## 学习目标

1. 掌握 CNI、存储、DNS 的基准测试方法
2. 建立可复现的测试环境（Kind + 标准化工具）
3. 理解 P50/P95/P99 在平台性能评估中的意义
4. 学会编写基准测试报告
5. 将基准测试集成到 CI/CD 流程
6. 掌握性能回归的判定标准和应对策略

## 为什么需要基准测试

在平台工程中，基准测试回答以下关键问题:

- "Cilium eBPF 比 Calico iptables 快多少？"
- "我们的 DNS 解析在 1000 QPS 下是否满足 <5ms P99？"
- "新版本的 K8s 升级后 API Server 延迟是否有回归？"
- "存储从 gp2 切换到 gp3 后 IOPS 提升多少？"

没有基准测试，这些问题的答案只能是"感觉快了一点"或"应该没问题"。
平台工程师需要用数据说话，用数据驱动架构决策。

## 基准测试原则

### 可复现性

每次测试必须记录完整上下文:
- K8s 版本、CNI 版本、内核版本
- 节点规格（CPU、内存、磁盘类型）
- 测试工具版本和参数
- 环境配置（如 Kind 配置、节点污点）

### 统计显著性

- 至少运行 5 次，取中位数（排除异常值）
- 报告标准差，判断结果稳定性
- 预热阶段（前 10 秒数据丢弃）

### 隔离性

- 测试期间节点不应运行其他负载
- 使用节点亲和性将测试 Pod 绑定到专用节点
- 避免与监控、日志采集竞争资源

## 模块内容

### CNI 吞吐量测试

文件: `cni-throughput-test.md`

使用 iperf3/netperf 对比不同 CNI 插件的 Pod-Pod 吞吐量和延迟。

**测试矩阵**:

| CNI | 后端模式 | 吞吐量 (Gbps) | P50 延迟 | P99 延迟 | CPU 开销 | 适用场景 |
|-----|---------|--------------|---------|---------|---------|---------|
| Calico | iptables | 8-9 | 0.3ms | 0.8ms | 中等 | 通用 |
| Calico | eBPF | 9-10 | 0.2ms | 0.5ms | 低 | 高性能 |
| Cilium | eBPF | 9-10 | 0.15ms | 0.4ms | 低 | 服务网格 |
| Flannel | VXLAN | 6-7 | 0.8ms | 2.0ms | 高 | 简单场景 |
| Flannel | host-gw | 9-10 | 0.2ms | 0.5ms | 低 | 同二层 |
| AWS VPC-CNI | ENI | 10+ | 0.05ms | 0.2ms | 极低 | AWS 原生 |
| Azure CNI | vnet | 9-10 | 0.1ms | 0.3ms | 低 | Azure 原生 |

**测试命令**:
```bash
# 部署 iperf3 Server Pod
kubectl run iperf-server --image=networkstatic/iperf3 -- iperf3 -s
SERVER_IP=$(kubectl get pod iperf-server -o jsonpath='{.status.podIP}')

# 运行吞吐量测试（单流）
kubectl run iperf-client --image=networkstatic/iperf3 --rm -it -- \
  iperf3 -c $SERVER_IP -t 30 -i 1 -J > /tmp/iperf-result.json

# 解析结果
jq -r '.intervals[].streams[].bits_per_second' /tmp/iperf-result.json | \
  awk '{sum+=$1; count++} END {print "平均吞吐量:", sum/count/1e9, "Gbps"}'

# 运行延迟测试（使用 netperf TCP_RR）
kubectl run netperf-client --image=networkstatic/netperf --rm -it -- \
  netperf -H $SERVER_IP -t TCP_RR -l 30 -- -r 1,1
```

**关键指标解读**:
- **吞吐量 (Gbps)**: 单流/多流的网络带宽，反映 CNI 数据面效率
- **P50 延迟**: 中位数延迟，反映典型性能
- **P99 延迟**: 尾部延迟，影响实时应用和微服务链路
- **CPU 开销**: CNI 数据面的 CPU 消耗，影响节点 Pod 密度

### 存储 I/O 测试

文件: `storage-io-test.md` (规划中)

使用 fio 测试不同 StorageClass 的 I/O 性能:

```bash
# 创建测试 PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fio-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3  # 或 standard, premium-rwo
EOF

# 运行 fio 测试
kubectl run fio-test --image=williamyeh/fio --rm -it --overrides='
{
  "spec": {
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {"claimName": "fio-test"}
    }],
    "containers": [{
      "name": "fio",
      "volumeMounts": [{"name": "data", "mountPath": "/data"}]
    }]
  }
}' -- fio --name=random-read --ioengine=libaio --iodepth=32 \
  --rw=randread --bs=4k --direct=1 --size=1G \
  --numjobs=4 --runtime=60 --directory=/data
```

**测试场景**:

| 场景 | 参数 | 关键指标 |
|------|------|---------|
| 数据库随机读 | randread, 4k, iodepth=32 | IOPS, P99 延迟 |
| 日志顺序写 | write, 256k, iodepth=16 | 吞吐量 (MB/s) |
| 混合读写 | randrw, 8k, rwmixread=70 | IOPS, 延迟分布 |
| 大文件顺序读 | read, 1m, iodepth=64 | 吞吐量 |

**关键指标**:
- IOPS (4K 随机读/写): 数据库类应用最关注
- 吞吐量 (MB/s，顺序读/写): 大数据、日志类应用关注
- 延迟 (us，P50/P99): 实时应用关注

### DNS 解析压力测试

文件: `dns-pressure-test.md` (规划中)

使用 dnsperf 测试 CoreDNS 在不同负载下的表现:

```bash
# 生成测试域名列表
cat > /tmp/queries.txt <<EOF
nginx.default.svc.cluster.local A
nginx.default.svc.cluster.local A
nginx.default.svc.cluster.local A
redis.default.svc.cluster.local A
EOF

# 运行 dnsperf
kubectl run dnsperf --image=azukiapp/dnsperf --rm -it -- \
  dnsperf -s $(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}') \
    -d /tmp/queries.txt -Q 1000 -l 30
```

**关键指标**:
- QPS (Queries Per Second): CoreDNS 处理能力
- 响应时间分布 (P50/P95/P99): 延迟表现
- 丢包率 / 超时率: 可靠性

**CoreDNS 性能基线**:
- 单核 QPS: ~20,000-40,000（缓存命中）
- 单核 QPS: ~5,000-10,000（缓存未命中，上游查询）
- 建议: 每 1000 节点部署 2-4 个 CoreDNS 副本

### 控制面压力测试

文件: `control-plane-stress.md` (规划中)

测试 API Server 在大量 LIST/WATCH 下的表现:

```bash
# 使用 kube-burner 模拟大规模集群
# 创建 1000 个 Deployment、5000 个 Pod
kube-burner init -c cluster-density.yml --uuid $(uuidgen)

# 监控 API Server 延迟
kubectl get --raw /metrics | grep apiserver_request_duration_seconds
```

**关键指标**:
- API Server LIST 延迟 (P99 < 1s)
- API Server WATCH 连接数（建议 < 10,000）
- etcd 磁盘 I/O (WAL fsync < 10ms)
- etcd DB 大小（建议 < 8GB）

## 测试环境标准化

### Kind 集群规格

所有基准测试使用统一的 Kind 配置:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: benchmark
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 8080
    hostPort: 8080
- role: worker
  extraMounts:
  - hostPath: /tmp/benchmark-data
    containerPath: /data
```

### 节点规格要求

- **CPU**: 4+ vCPU（避免 CPU 成为瓶颈）
- **Memory**: 8GB+（避免内存不足影响测试）
- **Disk**: SSD（避免磁盘 I/O 成为瓶颈）
- **网络**: 主机网络模式（Kind 的局限性，生产环境用裸机或云实例）

### 测试工具版本矩阵

| 工具 | 最低版本 | 推荐版本 | 用途 |
|------|---------|---------|------|
| iperf3 | 3.9 | 3.15 | 网络吞吐 |
| netperf | 2.7 | 2.7 | 网络延迟 |
| fio | 3.28 | 3.35 | 存储 I/O |
| dnsperf | 2.5 | 2.5 | DNS 压力 |
| wrk | 4.2 | 4.2 | HTTP 吞吐 |
| hey | 0.1.4 | 0.1.4 | HTTP 压力 |
| kube-burner | 1.7 | 1.9 | 控制面压力 |

## 结果记录模板

每次测试应记录完整上下文:

```yaml
test_id: "cni-calico-ebpf-20240415"
date: "2024-04-15T10:00:00Z"
tester: "platform-team"
environment:
  kind_version: "0.20.0"
  k8s_version: "1.28.3"
  container_runtime: "containerd"
  cni: "calico"
  cni_version: "3.26.1"
  cni_mode: "eBPF"
  node_count: 3
  node_cpu: 4
  node_memory: "8Gi"
  node_disk: "SSD"
test_config:
  tool: "iperf3"
  duration: 30
  streams: 1
  packet_size: "default"
results:
  throughput_gbps: 9.5
  throughput_stddev: 0.3
  latency_p50_ms: 0.2
  latency_p95_ms: 0.4
  latency_p99_ms: 0.5
  cpu_usage_percent: 15
  memory_usage_mb: 128
notes: "eBPF 数据面，无 kube-proxy。测试期间节点负载 <20%"
```

## 性能回归检测

建议将基准测试集成到 CI/CD:

```yaml
# .github/workflows/benchmark.yml
name: Performance Benchmark
on:
  schedule:
    - cron: '0 2 * * 1'  # 每周一凌晨 2 点
  workflow_dispatch:  # 支持手动触发

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Kind
        uses: helm/kind-action@v1
        with:
          cluster_name: benchmark
      
      - name: Install CNI
        run: |
          kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml
          kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
      
      - name: Run CNI Benchmark
        run: ./scripts/cni-benchmark.sh | tee results/cni-$(date +%Y%m%d).json
      
      - name: Compare with Baseline
        run: ./scripts/compare-baseline.sh results/cni-$(date +%Y%m%d).json
      
      - name: Upload Results
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-results
          path: results/
      
      - name: Alert on Regression
        if: failure()
        uses: slack-action@v1
        with:
          message: "性能基准测试发现回归！"
```

**回归判定标准**:
- 吞吐量下降 > 10%: 警告
- 吞吐量下降 > 20%: 阻断
- P99 延迟增加 > 50%: 警告
- P99 延迟增加 > 100%: 阻断

**回归应对流程**:
1. 复现测试（排除环境波动）
2. 定位变更（代码、配置、依赖）
3. 回滚或修复
4. 补充测试用例防止再次回归

## 面试常见问题

**Q: 为什么需要 P99 而不是只看平均值？**

A: 平均值会掩盖尾部延迟。在微服务架构中:
- 一个请求的响应时间 = 调用链上所有服务的最大值（而非平均值）
- 假设 5 个服务，每个平均 10ms，P99 是 100ms
- 整体链路平均延迟 ≈ 50ms，但 P99 延迟 ≈ 500ms

平台工程需要确保 P99 满足 SLO，因为用户体验由最差的情况决定。
生产环境建议同时关注 P99 和 P99.9。

**Q: 如何排除测试环境本身的影响？**

A: 四个原则:
1. **多次运行取中位数**: 排除偶然波动（建议至少 5 次）
2. **隔离测试**: 避免与其他负载共享节点（使用污点/容忍）
3. **预热**: 排除冷缓存影响（先运行 10 秒预热）
4. **对照组**: 同时测试基线和变更（A/B 测试）

**Q: CNI 选择对实际业务的影响有多大？**

A: 取决于业务类型:
- **普通 Web 应用**: 差异不明显（<5%），选运维简单的即可
- **高频交易/实时游戏**: Cilium eBPF 比 Flannel 延迟低 50%+，差异显著
- **大数据处理**: AWS VPC-CNI 的吞吐量比 VXLAN 高 30%+
- **服务网格**: CNI 性能直接影响 Sidecar 的 Envoy 转发效率

**Q: 如何建立长期的性能基线？**

A: 五步流程:
1. 选择稳定的测试环境（裸机或固定规格云实例）
2. 每周运行一次完整基准测试
3. 记录所有测试结果到时间序列数据库（如 Prometheus）
4. 设置自动告警，检测回归
5. 每次升级前对比基线（K8s 升级、CNI 升级、内核升级）

**Q: 性能测试中的常见陷阱？**

A: 五大陷阱:
1. **冷启动效应**: 第一次运行结果异常，需要预热
2. **资源竞争**: 测试节点上运行其他 Pod，导致结果不稳定
3. **工具本身开销**: 某些测试工具消耗大量 CPU，影响被测系统
4. **网络抖动**: 云环境中的网络波动导致结果不一致
5. **数据量不足**: 测试时间太短（<10 秒），无法反映真实性能

**Q: 如何向非技术管理层解释性能基准的重要性？**

A: 用业务语言:
- "基准测试帮助我们回答'升级后会不会变慢'"
- "没有基准，所有优化都是盲目的，可能花了时间却没效果"
- "基准数据是容量规划的依据，避免过度采购或资源不足"
- "自动回归检测可以在问题影响用户前发现"

## 参考资源

- [Kubernetes 网络性能测试指南](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [CNI Benchmark 对比](https://www.cni.dev/docs/)
- [etcd 性能基准](https://etcd.io/docs/v3.5/op-guide/performance/)
- [Kind 性能注意事项](https://kind.sigs.k8s.io/docs/user/known-issues/)
- [iperf3 文档](https://iperf.fr/iperf-doc.php)
- [fio 文档](https://github.com/axboe/fio)
- [kube-burner 文档](https://kube-burner.readthedocs.io/)

## 性能基准测试进阶

### 大规模集群压力测试

**kube-burner 实战**:
```bash
# 安装 kube-burner
curl -L https://github.com/cloud-bulldozer/kube-burner/releases/latest/download/kube-burner-$(uname -s)-$(uname -m) -o kube-burner
chmod +x kube-burner

# 创建测试场景：模拟 1000 个 Pod 创建/删除
cat > cluster-density.yaml << 'KBEOF'
global:
  qps: 20
  burst: 40
global:
  gc: true
  gcMetrics: false
  measurements:
  - name: podLatency
jobs:
  - name: cluster-density
    jobIterations: 1000
    qps: 20
    burst: 40
    namespacedIterations: true
    namespace: cluster-density
    preLoadImages: true
    objects:
    - objectTemplate: deployment.yaml
      replicas: 1
      inputVars:
        containerImage: nginx:alpine
        replicas: 2
    - objectTemplate: service.yaml
      replicas: 1
    - objectTemplate: configmap.yaml
      replicas: 1
KBEOF

# 运行测试
kube-burner init -c cluster-density.yaml

# 查看结果
# podLatency 指标: P50, P95, P99 的 Pod 启动时间
# 正常集群: P99 < 30s
# 异常集群: P99 > 60s（需排查）
```

**控制面压力测试**:
```bash
# 测试 API Server 吞吐量
# 使用 Vegeta 进行并发请求测试
echo "GET https://k8s-api:6443/api/v1/namespaces" | vegeta attack -rate=1000 -duration=60s | vegeta report

# 关键指标:
# - 成功率 > 99.9%
# - P99 延迟 < 1s
# - 无 429 (Too Many Requests)

# etcd 压力测试
etcdctl check perf
# 结果:
#  PASS: Throughput is 150 writes/s (expect: > 100)
#  PASS: Slowest request took 0.1s (expect: < 0.5s)
#  FAIL: Stddev is 0.05s (expect: < 0.03s)
```

### 存储性能基准

**CNI 存储性能测试**:
```bash
# 1. 创建测试 PVC
cat > test-pvc.yaml << 'PVCEOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: perf-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3  # 或你的 StorageClass
PVCEOF
kubectl apply -f test-pvc.yaml

# 2. 运行 fio 测试
cat > fio-test.yaml << 'FIOEOF'
apiVersion: v1
kind: Pod
metadata:
  name: fio-test
spec:
  containers:
  - name: fio
    image: xridge/fio
    command: ["fio"]
    args:
    - "--name=random-write"
    - "--ioengine=libaio"
    - "--iodepth=32"
    - "--rw=randwrite"
    - "--bs=4k"
    - "--direct=1"
    - "--size=1G"
    - "--numjobs=4"
    - "--runtime=60"
    - "--group_reporting"
    - "--directory=/data"
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: perf-test
  restartPolicy: Never
FIOEOF
kubectl apply -f fio-test.yaml
kubectl logs fio-test -f

# 3. 预期结果（AWS gp3）:
# IOPS: 3000 (可提升到 16000)
# 吞吐量: 125 MB/s (可提升到 1000 MB/s)
# 延迟: P99 < 10ms
```

### 服务网格性能测试

**Istio 性能基准**:
```bash
# 测试场景：带 Sidecar vs 不带 Sidecar

# 1. 基线（无 Sidecar）
kubectl label namespace default istio-injection=disabled --overwrite
# 运行 vegeta 测试

# 2. 带 Sidecar（默认配置）
kubectl label namespace default istio-injection=enabled --overwrite
# 等待 Sidecar 注入
# 运行 vegeta 测试

# 3. 带 Sidecar（优化配置）
# 关闭遥测（如果不需要）
# 调整并发连接数
# 运行 vegeta 测试

# 典型结果:
# ┌──────────────┬─────────┬─────────┬────────┐
# │   场景       │  QPS    │ P99 延迟 │ CPU    │
# ├──────────────┼─────────┼─────────┼────────┤
# │ 无 Sidecar   │ 50,000  │  5ms    │ 1 core │
# │ 默认 Sidecar │ 40,000  │  10ms   │ 2 core │
# │ 优化 Sidecar │ 45,000  │  7ms    │ 1.5core│
# └──────────────┴─────────┴─────────┴────────┘
```

### 性能回归检测自动化

**CI 集成方案**:
```yaml
# .github/workflows/perf-regression.yaml
name: Performance Regression Test
on:
  pull_request:
    branches: [main]

jobs:
  perf-test:
    runs-on: self-hosted  # 需要固定硬件
    steps:
    - uses: actions/checkout@v4
    
    - name: Deploy to test cluster
      run: kubectl apply -k kustomize/test/
    
    - name: Warm up
      run: sleep 30  # 等待 Pod Ready + JVM 预热
    
    - name: Run benchmark
      run: |
        echo "GET http://test-service/api/health" | vegeta attack -rate=1000 -duration=60s > results.bin
        vegeta report -type=json results.bin > metrics.json
    
    - name: Compare with baseline
      run: |
        current_p99=$(jq '.latencies."99th"' metrics.json)
        baseline_p99=$(cat baseline/p99.json)
        regression=$(echo "$current_p99 > $baseline_p99 * 1.1" | bc)
        if [ "$regression" -eq 1 ]; then
          echo "PERFORMANCE REGRESSION DETECTED!"
          echo "Current P99: ${current_p99}ns"
          echo "Baseline P99: ${baseline_p99}ns"
          exit 1
        fi
```

### 性能问题诊断方法论

**延迟分解技术**:
```
总延迟 = 客户端延迟 + 网络延迟 + 服务端延迟 + 数据库延迟

测量方法:
1. 客户端: curl -w "@curl-format.txt" -o /dev/null -s http://service/api
   # curl-format.txt:
   # time_namelookup: %{time_namelookup}\n
   # time_connect: %{time_connect}\n
   # time_appconnect: %{time_appconnect}\n
   # time_pretransfer: %{time_pretransfer}\n
   # time_redirect: %{time_redirect}\n
   # time_starttransfer: %{time_starttransfer}\n
   # time_total: %{time_total}\n
2. 网络: tcpdump + Wireshark 分析
3. 服务端: APM 工具（Jaeger / SkyWalking）
4. 数据库: 慢查询日志 + EXPLAIN ANALYZE
```

**火焰图生成**:
```bash
# 使用 bpftrace 或 perf 生成火焰图
# 1. 收集数据
kubectl exec -it <pod> -- perf record -F 99 -a -g -- sleep 30

# 2. 生成火焰图
kubectl cp <pod>:/tmp/perf.data ./perf.data
perf script | ./stackcollapse-perf.pl | ./flamegraph.pl > flame.svg

# 分析:
# - 宽层 = 消耗 CPU 多
# - 定位最宽的调用栈
```


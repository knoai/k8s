# Kubernetes 性能基准测试套件

> 从集群压测到组件级微基准的完整方法论，含具体命令、预期输出和判定标准。

---

## 测试环境准备

### 集群规格基准

```
测试集群最小规格：
  Master (3 节点)：
    - CPU: 8 核
    - Memory: 32 GB
    - Disk: 200GB SSD (5000+ IOPS)
    - Network: 10Gbps
  
  Worker (3-10 节点)：
    - CPU: 16 核
    - Memory: 64 GB
    - Disk: 200GB SSD
    - Network: 10Gbps

工具准备：
  # 集群级压测
  go install sigs.k8s.io/cluster-proportional-autoscaler@latest
  
  # API Server 压测
  go install github.com/linode/cluster-api-loadbalancer@latest
  
  # 网络性能
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/perf-tests/master/network/benchmarks/netperf/launch.yaml
  
  # 存储性能
  kubectl apply -f https://raw.githubusercontent.com/cloud-bulldozer/kraken/master/kraken/chaos/pvc-scenarios/pvc scenario.yaml
  
  # 自定义工具
  # - wrk/http_load: HTTP 压测
  # - iperf3: 网络吞吐
  # - fio: 存储 IO
  # - sysbench: CPU/内存/线程
```

---

## 1. API Server 压测

### 1.1 并发 LIST 测试

```bash
# 测试方法：同时从多个客户端 LIST 大量资源
# 指标：延迟、成功率、API Server CPU/内存

# 步骤 1：创建测试资源
kubectl create namespace benchmark
cat > benchmark-resources.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: benchmark-cm-{i}
  namespace: benchmark
data:
  key: value
---
EOF

# 批量创建 10000 个 ConfigMap
for i in $(seq 1 10000); do
  sed "s/{i}/$i/g" benchmark-resources.yaml | kubectl apply -f -
done

# 步骤 2：并发 LIST 测试
CONCURRENCY=50
duration=60

for i in $(seq 1 $CONCURRENCY); do
  (
    start=$(date +%s)
    count=0
    while [ $(($(date +%s) - start)) -lt $duration ]; do
      kubectl get configmaps -n benchmark --no-headers 2>/dev/null | wc -l
      count=$((count + 1))
    done
    echo "Client $i: $count requests in ${duration}s"
  ) &
done
wait

# 预期输出（健康集群，5000 ConfigMap）：
# Client 1: 120 requests in 60s    → 平均 500ms/请求
# Client 2: 118 requests in 60s
# ...
# Client 50: 115 requests in 60s
# 
# 总计：~5900 次 LIST / 60s = 98 QPS
# 平均延迟：~500ms
# API Server CPU：30-50%

# 危险信号：
# Client 1: 12 requests in 60s     → 平均 5s/请求
# Client 2: 10 requests in 60s
# ...
# API Server CPU：100%（throttling）
# etcd 延迟：>1s
```

### 1.2 创建 Pod 吞吐量测试

```bash
# 使用 k8s-load-test 工具
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: pod-creation-benchmark
  namespace: benchmark
spec:
  parallelism: 10
  template:
    spec:
      containers:
      - name: benchmark
        image: bitnami/kubectl
        command:
        - /bin/sh
        - -c
        - |
          start=$(date +%s%N)
          for i in $(seq 1 100); do
            cat <<POD | kubectl apply -f -
          apiVersion: v1
kind: Pod
metadata:
  name: test-pod-$i-$(hostname)
  namespace: benchmark
spec:
  containers:
  - name: nginx
    image: nginx:alpine
POD
          done
          end=$(date +%s%N)
          elapsed=$(( (end - start) / 1000000 ))
          echo "$(hostname): Created 100 pods in ${elapsed}ms"
          echo "$(hostname): Average $(echo "scale=2; $elapsed / 100" | bc)ms per pod"
      restartPolicy: Never
EOF

# 预期输出：
# pod-creation-benchmark-abc: Created 100 pods in 23456ms
# pod-creation-benchmark-abc: Average 234.56ms per pod
# 
# 10 并行客户端 × 100 Pod = 1000 Pod
# 总时间 ≈ 30-60 秒
# 吞吐量 ≈ 15-30 Pod/s

# 优化后（预拉取镜像、containerd 缓存）：
# Average 80ms per pod
# 吞吐量 ≈ 100+ Pod/s
```

### 1.3 API Server 性能判定标准

| 指标 | 合格线 | 优秀线 | 测试方法 |
|------|--------|--------|---------|
| GET Pod (单个) | < 10ms | < 2ms | `time kubectl get pod xxx` |
| LIST Pod (1000个) | < 500ms | < 200ms | `time kubectl get pods` |
| CREATE Pod | < 1s | < 500ms | 批量创建计时 |
| DELETE Pod | < 500ms | < 200ms | 批量删除计时 |
| WATCH 事件延迟 | < 100ms | < 50ms | 创建 Pod 到收到事件 |
| API Server CPU | < 50% | < 30% | `kubectl top pod` |
| API Server 内存 | < 2GB | < 1GB | `kubectl top pod` |
| etcd fsync P99 | < 10ms | < 5ms | Prometheus |

---

## 2. 调度器性能测试

### 2.1 调度延迟测试

```bash
# 方法：创建大量 Pod，测量从 Pending 到 Scheduled 的时间
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: scheduling-benchmark
spec:
  parallelism: 1
  completions: 1000
  template:
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: "10m"
            memory: "32Mi"
      restartPolicy: Never
EOF

# 监控调度延迟
kubectl get events --field-selector reason=Scheduled -w | \
  awk '/Scheduled/{print $1, $4}' | head -1000

# 或者使用 Prometheus 查询：
# histogram_quantile(0.99, rate(scheduler_e2e_scheduling_duration_seconds_bucket[5m]))

# 预期输出（1000 节点集群）：
# P50 调度延迟: 50ms
# P99 调度延迟: 300ms
# 1000 个 Pod 全部调度完成: 30 秒

# 危险信号：
# P99 调度延迟: 5s
# 1000 个 Pod 全部调度完成: 10 分钟
# 原因：可能是预选阶段遍历所有节点（10,000 节点）太慢
```

### 2.2 调度器压力测试

```bash
# 同时创建 5000 个 Pod
for i in $(seq 1 5000); do
  cat <<EOF | kubectl apply -f - &
apiVersion: v1
kind: Pod
metadata:
  name: stress-pod-$i
  namespace: benchmark
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: "10m"
        memory: "32Mi"
EOF
done
wait

# 监控 Pending Pod 数量
watch 'kubectl get pods -n benchmark --field-selector status.phase=Pending | wc -l'

# 预期：
# 初始 Pending: 5000
# 30 秒后 Pending: 0
# 调度速率: ~150-200 Pod/秒

# 危险信号：
# 5 分钟后仍有大量 Pending
# 调度器日志: "Unable to schedule pod; no fit"
# 原因：资源不足或预选规则过于严格
```

---

## 3. 网络性能测试

### 3.1 Pod 到 Pod 延迟

```bash
# 部署测试 Pod
kubectl run netperf-server --image=networkstatic/iperf3 -- iperf3 -s
kubectl run netperf-client --rm -i --restart=Never --image=networkstatic/iperf3 -- \
  iperf3 -c netperf-server -t 30 -i 1

# 预期输出（同节点）：
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-30.00  sec  33.5 GBytes  9.59 Gbits/sec    0             sender
# [  5]   0.00-30.00  sec  33.5 GBytes  9.59 Gbits/sec                  receiver
# 
# 延迟测试：
# iperf Done.
# 同节点延迟: ~0.05ms (veth 直接转发)

# 预期输出（跨节点，VPC 网络）：
# [  5]   0.00-30.00  sec  32.8 GBytes  9.39 Gbits/sec    0             sender
# 跨节点延迟: ~0.2-0.5ms

# 预期输出（跨节点，VXLAN 封装）：
# [  5]   0.00-30.00  sec  28.5 GBytes  8.16 Gbits/sec  123             sender
# 跨节点延迟: ~0.5-1ms
# 注意：VXLAN 封装有约 10% 吞吐损失
```

### 3.2 Service 转发性能

```bash
# 部署测试服务
kubectl create deployment nginx --image=nginx --replicas=3
kubectl expose deployment nginx --port=80 --target-port=80

# 使用 wrk 压测
kubectl run wrk --rm -i --restart=Never --image=williamyeh/wrk -- \
  wrk -t10 -c100 -d30s http://nginx

# 预期输出（ClusterIP, kube-proxy iptables）：
# Running 30s test @ http://nginx
#   10 threads and 100 connections
#   Thread Stats   Avg      Stdev     Max   +/- Stdev
#     Latency   234.56us  123.45us   5.67ms   95.23%
#     Req/Sec    42.15k     3.21k   50.23k    78.45%
#   12634567 requests in 30.10s, 10.23GB read
# Requests/sec: 419754          ← 约 42万 QPS
# Transfer/sec:    348.21MB

# 预期输出（ClusterIP, kube-proxy IPVS）：
# Requests/sec: 450123          ← IPVS 略快

# 预期输出（NodePort）：
# Requests/sec: 380456          ← NodePort 有额外 DNAT 开销
```

### 3.3 网络性能判定标准

| 指标 | 同节点 | 跨节点 (VPC) | 跨节点 (VXLAN) | 测试方法 |
|------|--------|-------------|---------------|---------|
| 延迟 P50 | < 0.1ms | < 0.5ms | < 1ms | `iperf3 -c` |
| 延迟 P99 | < 0.5ms | < 2ms | < 5ms | `iperf3 -c` |
| 吞吐 (TCP) | > 9Gbps | > 9Gbps | > 7Gbps | `iperf3 -c` |
| 吞吐 (UDP) | > 9Gbps | > 9Gbps | > 6Gbps | `iperf3 -c -u -b 0` |
| Service QPS | > 40万 | > 40万 | > 35万 | `wrk` |

---

## 4. 存储性能测试

### 4.1 云盘性能测试

```bash
# 创建测试 PVC
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: benchmark-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Gi
  storageClassName: gp3
EOF

# 部署 fio 测试 Pod
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: fio-test
spec:
  containers:
  - name: fio
    image: joshbmarshall/fio
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: benchmark-pvc
EOF

# 顺序写测试
kubectl exec fio-test -- fio --name=seq-write \
  --directory=/data \
  --rw=write \
  --bs=1M \
  --size=10G \
  --numjobs=1 \
  --direct=1 \
  --runtime=60 \
  --group_reporting

# 预期输出（AWS gp3, 3000 IOPS）：
# seq-write: (groupid=0, jobs=1): err= 0: pid=123: Mon Jan 15 08:30:00 2024
#   write: IOPS=312, BW=312MiB/s (327MB/s)(18.3GiB/60001msec)
#   slat (usec): min=123, max=5678, avg=456.78, stdev=234.56
#   clat (msec): min=1, max=45, avg=3.21, stdev=2.34
#   lat (msec): min=2, max=46, avg=3.67, stdev=2.45
# ← 顺序写 312 MB/s，延迟 3.67ms

# 随机读测试（4K）
kubectl exec fio-test -- fio --name=rand-read \
  --directory=/data \
  --rw=randread \
  --bs=4k \
  --size=10G \
  --numjobs=8 \
  --iodepth=32 \
  --direct=1 \
  --runtime=60 \
  --group_reporting

# 预期输出（AWS gp3, 3000 IOPS）：
# rand-read: (groupid=0, jobs=8): err= 0: pid=456: Mon Jan 15 08:30:00 2024
#   read: IOPS=2987, BW=11.7MiB/s (12.3MB/s)(702MiB/60001msec)
#   slat (usec): min=2, max=1234, avg=12.34, stdev=23.45
#   clat (usec): min=234, max=45678, avg=3456.78, stdev=2345.67
#   lat (usec): min=245, max=45680, avg=3469.12, stdev=2345.89
# ← 随机读 2987 IOPS，延迟 3.47ms

# 随机写测试（4K）
kubectl exec fio-test -- fio --name=rand-write \
  --directory=/data \
  --rw=randwrite \
  --bs=4k \
  --size=10G \
  --numjobs=8 \
  --iodepth=32 \
  --direct=1 \
  --runtime=60 \
  --group_reporting

# 预期输出：
# write: IOPS=2987, BW=11.7MiB/s (12.3MB/s)(702MiB/60001msec)
# ← gp3 读和写 IOPS 相同
```

### 4.2 本地存储性能测试

```bash
# emptyDir 性能（节点本地 tmpfs 或磁盘）
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: local-disk-test
spec:
  containers:
  - name: fio
    image: joshbmarshall/fio
    command: ["sleep", "3600"]
    volumeMounts:
    - name: tmp
      mountPath: /data
  volumes:
  - name: tmp
    emptyDir: {}
EOF

# emptyDir 默认是节点磁盘
kubectl exec local-disk-test -- fio --name=rand-read \
  --directory=/data --rw=randread --bs=4k --size=1G \
  --numjobs=4 --direct=1 --runtime=30

# 预期输出（节点本地 SSD）：
# read: IOPS=85000, BW=332MiB/s (348MB/s)(9.77GiB/30001msec)
# ← 本地盘 8.5万 IOPS，比云盘快 28 倍！
```

### 4.3 存储性能判定标准

| 存储类型 | 顺序写吞吐 | 随机读 IOPS | 随机读延迟 | 适用场景 |
|---------|-----------|------------|-----------|---------|
| emptyDir (本地 SSD) | > 500MB/s | > 50000 | < 1ms | 临时缓存 |
| emptyDir (tmpfs) | > 2GB/s | > 100000 | < 0.1ms | 内存缓存 |
| AWS gp3 (3000 IOPS) | ~300MB/s | ~3000 | ~3ms | 一般业务 |
| AWS io2 (16000 IOPS) | ~300MB/s | ~16000 | ~1ms | 数据库 |
| 阿里云 ESSD PL3 | ~400MB/s | ~50000 | ~0.3ms | 高性能 DB |
| Ceph RBD | ~200MB/s | ~5000 | ~5ms | 共享存储 |
| NFS | ~100MB/s | ~1000 | ~10ms | 共享文件 |

---

## 5. 端到端应用压测

### 5.1 完整链路压测

```bash
# 部署测试应用（带数据库、缓存）
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: benchmark-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: benchmark-app
  template:
    metadata:
      labels:
        app: benchmark-app
    spec:
      containers:
      - name: app
        image: williamyeh/wrk
        env:
        - name: DB_HOST
          value: postgres
        - name: REDIS_HOST
          value: redis
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2"
            memory: "2Gi"
EOF

kubectl expose deployment benchmark-app --port=80 --target-port=8080

# 使用 k6 进行端到端压测
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-benchmark
spec:
  template:
    spec:
      containers:
      - name: k6
        image: grafana/k6:latest
        command:
        - k6
        - run
        - --vus=100
        - --duration=5m
        - -
        args:
        - |
          import http from 'k6/http';
          import { check, sleep } from 'k6';
          
          export const options = {
            thresholds: {
              http_req_duration: ['p(95)<500'],  // P95 < 500ms
              http_req_failed: ['rate<0.01'],     // 错误率 < 1%
            },
          };
          
          export default function () {
            const res = http.get('http://benchmark-app/api/health');
            check(res, {
              'status is 200': (r) => r.status === 200,
              'response time < 500ms': (r) => r.timings.duration < 500,
            });
            sleep(1);
          }
      restartPolicy: Never
EOF

# 预期输出：
# running (5m00.0s), 000/100 VUs, 29876 complete and 0 interrupted iterations
# 
# data_received..................: 234 MB  780 kB/s
# data_sent......................: 45 MB   150 kB/s
# http_req_blocked...............: avg=1.23µs  min=0s      med=1µs     max=1.23ms  p(90)=2µs    p(95)=3µs
# http_req_connecting............: avg=0s      min=0s      med=0s      max=0s      p(90)=0s     p(95)=0s
# http_req_duration..............: avg=23.45ms min=12.34ms med=21.23ms max=456.78ms p(90)=34.56ms p(95)=45.67ms
#   { expected_response:true }...: avg=23.45ms min=12.34ms med=21.23ms max=456.78ms p(90)=34.56ms p(95)=45.67ms
# http_req_failed................: 0.00%   ✓ 0        ✗ 29876
# http_req_receiving.............: avg=45.67µs min=12µs    med=34µs    max=12.34ms p(90)=78µs   p(95)=123µs
# http_req_sending...............: avg=23.45µs min=8µs     med=18µs    max=8.90ms  p(90)=34µs   p(95)=45µs
# http_req_waiting...............: avg=23.38ms min=12.31ms med=21.18ms max=456.67ms p(90)=34.48ms p(95)=45.56ms
# http_reqs......................: 29876   99.58/s
# iteration_duration.............: avg=1.02s   min=1.01s   med=1.02s   max=1.46s   p(90)=1.03s  p(95)=1.04s
# iterations.....................: 29876   99.58/s
# vus............................: 100     min=100    max=100
# vus_max........................: 100     min=100    max=100
# 
# ✓ http_req_duration..............: p(95)=45.67ms (< 500ms)
# ✓ http_req_failed................: 0.00% (< 1%)
```

---

## 6. 自动化基准测试脚本

```bash
#!/bin/bash
# k8s-benchmark.sh
# 一键运行全部基准测试

NAMESPACE="benchmark-$(date +%s)"
RESULTS="benchmark-results-$(date +%Y%m%d_%H%M%S).txt"

echo "==========================================" | tee -a $RESULTS
echo "  K8s 性能基准测试" | tee -a $RESULTS
echo "  命名空间: $NAMESPACE" | tee -a $RESULTS
echo "  时间: $(date)" | tee -a $RESULTS
echo "==========================================" | tee -a $RESULTS

kubectl create namespace $NAMESPACE

# 测试 1：API Server 延迟
echo "" | tee -a $RESULTS
echo "=== 测试 1: API Server 延迟 ===" | tee -a $RESULTS
for i in $(seq 1 10); do
  LATENCY=$(kubectl run latency-test-$i --rm -i --restart=Never \
    --namespace=$NAMESPACE --image=busybox -- \
    time wget -qO- https://kubernetes.default.svc.cluster.local/healthz 2>&1 | \
    grep real | awk '{print $2}')
  echo "  请求 $i: ${LATENCY}s" | tee -a $RESULTS
done

# 测试 2：Pod 创建速度
echo "" | tee -a $RESULTS
echo "=== 测试 2: Pod 创建速度 ===" | tee -a $RESULTS
START=$(date +%s)
for i in $(seq 1 50); do
  kubectl run test-pod-$i --namespace=$NAMESPACE --image=nginx:alpine \
    --restart=Never --requests='cpu=10m,memory=32Mi' >/dev/null 2>&1 &
done
wait
END=$(date +%s)
CREATION_TIME=$((END - START))
echo "  创建 50 个 Pod 耗时: ${CREATION_TIME}s" | tee -a $RESULTS
echo "  平均每个 Pod: $(echo "scale=2; $CREATION_TIME / 50" | bc)s" | tee -a $RESULTS

# 等待 Pod 就绪
kubectl wait --for=condition=ready pod --all --namespace=$NAMESPACE --timeout=120s

# 测试 3：网络延迟
echo "" | tee -a $RESULTS
echo "=== 测试 3: 网络延迟 ===" | tee -a $RESULTS
kubectl run net-server --namespace=$NAMESPACE --image=busybox -- \
  nc -lk -p 8080 -e echo "pong" &
sleep 2
kubectl run net-client --rm -i --restart=Never --namespace=$NAMESPACE --image=busybox -- \
  sh -c 'for i in $(seq 1 10); do time wget -qO- http://net-server:8080 2>&1 | grep real; done' | \
  tee -a $RESULTS

# 测试 4：DNS 解析
echo "" | tee -a $RESULTS
echo "=== 测试 4: DNS 解析 ===" | tee -a $RESULTS
kubectl run dns-test --rm -i --restart=Never --namespace=$NAMESPACE --image=busybox -- \
  sh -c 'for i in $(seq 1 10); do time nslookup kubernetes.default.svc.cluster.local 2>&1 | grep real; done' | \
  tee -a $RESULTS

# 测试 5：资源使用
echo "" | tee -a $RESULTS
echo "=== 测试 5: 组件资源使用 ===" | tee -a $RESULTS
echo "API Server:" | tee -a $RESULTS
kubectl top pod -n kube-system -l component=kube-apiserver 2>/dev/null | tee -a $RESULTS

echo "etcd:" | tee -a $RESULTS
kubectl top pod -n kube-system -l component=etcd 2>/dev/null | tee -a $RESULTS

echo "Scheduler:" | tee -a $RESULTS
kubectl top pod -n kube-system -l component=kube-scheduler 2>/dev/null | tee -a $RESULTS

# 清理
kubectl delete namespace $NAMESPACE --wait=false

echo "" | tee -a $RESULTS
echo "==========================================" | tee -a $RESULTS
echo "  测试完成，结果保存至: $RESULTS" | tee -a $RESULTS
echo "==========================================" | tee -a $RESULTS
```

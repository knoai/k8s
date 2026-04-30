# 持续性能剖析（Continuous Profiling）

> 市场 JD 高频要求："定期采集 CPU/Memory 火焰图，建立性能基线库"、"Profiling 领域"

---

## 1. 为什么需要 Profiling

传统监控回答 **"出了什么问题"**，Profiling 回答 **"为什么出问题"**。

| 监控手段 | 发现问题 | 定位根因 |
|----------|----------|----------|
| Metrics | CPU 使用率 90% | ❌ 不知道哪行代码 |
| Logs | 响应慢 | ❌ 不知道瓶颈函数 |
| Traces | 某 Span 耗时 2s | ❌ 不知道函数内部热点 |
| **Profiling** | CPU/Memory 高 | ✅ 精确到函数行号 |

---

## 2. Profile 类型

| 类型 | 说明 | 用途 |
|------|------|------|
| **CPU Profile** | 采样 CPU 时间消耗 | 定位 CPU 热点函数 |
| **Memory Profile** | 采样内存分配 | 定位内存泄漏、高分配 |
| **Goroutine Profile** | 当前所有 Goroutine 栈 | 定位 Goroutine 泄漏 |
| **Mutex Profile** | 锁竞争等待时间 | 定位锁竞争瓶颈 |
| **Block Profile** | 阻塞等待时间 | 定位 I/O/Channel 阻塞 |
| **Off-CPU Profile** | 非 CPU 等待时间 | 定位 I/O、睡眠、调度延迟 |
| **Heap Profile** | 堆内存快照 | 分析内存使用分布 |

---

## 3. 工具生态

| 工具 | 语言 | 架构 | 部署方式 |
|------|------|------|----------|
| **Pyroscope** | 多语言 | 服务端+Agent | K8s DaemonSet |
| **Parca** | 多语言 | 服务端+Agent | K8s Operator |
| **Grafana Profiles** | 多语言 | 集成 Pyroscope | Grafana 生态 |
| **pprof** | Go | 标准库内置 | 本地/HTTP |
| **async-profiler** | Java | 无侵入 Agent | attach 到 JVM |
| **perf** | 通用 | Linux 工具 | 系统级 |
| **eBPF Profiling** | 多语言 | 内核级 | Cilium/Pixie |

---

## 4. Pyroscope 实战

### 4.1 Pyroscope 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Pyroscope Server                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Ingester   │  │   Store     │  │    Query    │         │
│  │  (接收数据)  │  │ (BadgerDB)  │  │  (查询接口)  │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ push/pull
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
   │ Go App  │          │Java App │          │Rust App │
   │(pyroscope│          │(pyroscope│         │(pyroscope│
   │  go)    │          │  java)  │          │  rs)   │
   └─────────┘          └─────────┘          └─────────┘
```

### 4.2 部署 Pyroscope

```yaml
# pyroscope-server.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pyroscope
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pyroscope
  template:
    metadata:
      labels:
        app: pyroscope
    spec:
      containers:
        - name: pyroscope
          image: grafana/pyroscope:1.5.0
          args:
            - -server.http-listen-port=4040
            - -storage.tsdb.retention.time=30d
          ports:
            - containerPort: 4040
              name: http
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: 2000m
              memory: 8Gi
          volumeMounts:
            - name: storage
              mountPath: /data
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: pyroscope-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: pyroscope
  namespace: monitoring
spec:
  selector:
    app: pyroscope
  ports:
    - port: 4040
      targetPort: 4040
```

### 4.3 Go 应用接入 Pyroscope

```go
package main

import (
    "github.com/grafana/pyroscope-go"
)

func main() {
    pyroscope.Start(pyroscope.Config{
        ApplicationName: "order-service",
        ServerAddress:   "http://pyroscope.monitoring:4040",
        Tags: map[string]string{
            "namespace": "production",
            "pod":       os.Getenv("HOSTNAME"),
        },
        ProfileTypes: []pyroscope.ProfileType{
            pyroscope.ProfileCPU,
            pyroscope.ProfileAllocObjects,
            pyroscope.ProfileAllocSpace,
            pyroscope.ProfileInuseObjects,
            pyroscope.ProfileInuseSpace,
            pyroscope.ProfileGoroutines,
            pyroscope.ProfileMutexCount,
            pyroscope.ProfileMutexDuration,
            pyroscope.ProfileBlockCount,
            pyroscope.ProfileBlockDuration,
        },
    })
    
    // 业务代码...
}
```

### 4.4 Java 应用接入（async-profiler）

```yaml
# Java Deployment 添加 Agent
spec:
  template:
    spec:
      containers:
        - name: app
          image: my-java-app:latest
          env:
            - name: PYROSCOPE_SERVER_ADDRESS
              value: "http://pyroscope.monitoring:4040"
            - name: PYROSCOPE_APPLICATION_NAME
              value: "java-service"
          volumeMounts:
            - name: pyroscope-agent
              mountPath: /pyroscope
          command: ["java"]
          args:
            - "-javaagent:/pyroscope/pyroscope.jar"
            - "-jar"
            - "/app.jar"
      initContainers:
        - name: download-agent
          image: busybox
          command:
            - wget
            - -O
            - /pyroscope/pyroscope.jar
            - https://github.com/grafana/pyroscope-java/releases/download/v0.12.2/pyroscope.jar
          volumeMounts:
            - name: pyroscope-agent
              mountPath: /pyroscope
      volumes:
        - name: pyroscope-agent
          emptyDir: {}
```

---

## 5. Parca 实战

Parca 是 Red Hat 开源的 Continuous Profiling 工具，支持 eBPF 无侵入采集。

### 5.1 Parca 部署

```bash
# 使用 Helm 部署
helm repo add parca https://parca-dev.github.io/helm-charts
helm install parca parca/parca \
  --namespace monitoring \
  --set agent.enabled=true
```

### 5.2 Parca Agent（eBPF 无侵入）

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: parca-agent
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: parca-agent
  template:
    spec:
      hostPID: true
      containers:
        - name: agent
          image: ghcr.io/parca-dev/parca-agent:v0.30.0
          securityContext:
            privileged: true
          args:
            - --node=$(NODE_NAME)
            - --remote-store-address=parca.monitoring:7070
            - --remote-store-insecure
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
```

---

## 6. 火焰图解读

### 6.1 CPU 火焰图

```
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  main.main
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  handler.ProcessOrder
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  db.Query
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  db.parseSQL
▓▓▓▓▓▓▓▓▓▓  regexp.Match
▓▓▓▓  runtime.mallocgc
```

**解读原则**：
- **宽度 = 耗时比例**：越宽表示占用 CPU 越多
- **从下往上 = 调用栈**：下面是父函数，上面是子函数
- **找平顶宽条**：平顶宽条是优化重点

### 6.2 内存火焰图

```
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  main
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  json.Marshal
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  bytes.makeSlice
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  runtime.makeslice
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  runtime.mallocgc
```

---

## 7. Profiling 与监控的关联

### 7.1 从 Metrics 到 Profiling

```
Metrics 发现异常
    ↓
CPU 使用率 90% → 点击 Grafana 面板上的 "View Profile" 链接
    ↓
Pyroscope 打开对应时间段的火焰图
    ↓
定位到具体函数和代码行
    ↓
优化代码 → 重新部署 → 对比 Profile 验证
```

### 7.2 Grafana 集成

```yaml
# Grafana 数据源配置
datasources:
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    url: http://pyroscope:4040
    jsonData:
      minStep: 15s
```

---

## 8. 建立性能基线

### 8.1 基线采集策略

| 场景 | 采集频率 | Profile 类型 |
|------|----------|--------------|
| 日常基线 | 每 5 分钟 | CPU + Memory |
| 发布前后 | 持续采集 30 分钟 | 全类型 |
| 告警触发 | 立即采集 10 分钟 | CPU + Goroutine |
| 压测期间 | 全程采集 | CPU + Memory + Mutex |

### 8.2 基线对比分析

```bash
# 使用 pprof 对比两个 Profile
go tool pprof -http=:8080 -diff_base=baseline.pb.gz current.pb.gz
```

---

## 参考资源

- [Pyroscope 官方文档](https://grafana.com/docs/pyroscope/latest/)
- [Parca 官方文档](https://www.parca.dev/docs/overview)
- [Google - Continuous Profiling](https://cloud.google.com/profiler/docs/)
- [Brendan Gregg - Flame Graphs](https://www.brendangregg.com/flamegraphs.html)
- [Go pprof 文档](https://pkg.go.dev/net/http/pprof)

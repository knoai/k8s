# CoreDNS 从基础到专家完整教材

> 本文档系统讲解 CoreDNS 的架构原理、插件机制、Kubernetes 集成、配置调优及故障排查，覆盖从入门到生产实践的全部知识。

---

## 目录

- [第一章：CoreDNS 基础](#第一章coredns-基础)
- [第二章：架构与工作原理](#第二章架构与工作原理)
- [第三章：插件系统详解](#第三章插件系统详解)
- [第四章：Kubernetes 中的 CoreDNS](#第四章kubernetes-中的-coredns)
- [第五章：静态解析与自定义域名](#第五章静态解析与自定义域名)
- [第六章：性能调优](#第六章性能调优)
- [第七章：监控与可观测性](#第七章监控与可观测性)
- [第八章：故障排查手册](#第八章故障排查手册)
- [第九章：高级主题](#第九章高级主题)
- [第十章：面试常见问题](#第十章面试常见问题)

---

## 第一章：CoreDNS 基础

### 1.1 什么是 CoreDNS

CoreDNS 是一个**灵活、可扩展的 DNS 服务器**，采用插件架构，是 Kubernetes 的默认集群 DNS。

**历史演进**：
- K8s 1.2：使用 kube-dns（基于 dnsmasq + skydns）
- K8s 1.9：引入 CoreDNS 作为可选方案
- K8s 1.11：CoreDNS 成为默认 DNS（GA）
- K8s 1.21：kube-dns 被 CoreDNS 完全取代

**为什么选择 CoreDNS**：

| 特性 | kube-dns | CoreDNS |
|------|---------|---------|
| 架构 | 多组件（dnsmasq + skydns + sidecar） | 单进程，插件化 |
| 性能 | 中等 | 更高 |
| 配置 | 复杂 | Corefile 简单统一 |
| 扩展性 | 差 | 插件机制，易扩展 |
| 健康检查 | sidecar 辅助 | 内置 |
| 监控 | 需额外配置 | 内置 Prometheus 指标 |

### 1.2 Corefile 基础

CoreDNS 使用 **Corefile** 作为配置文件，采用类 Caddy 的语法：

```
# 基本格式
域名:端口 {
    插件1
    插件2 {
        参数
    }
    插件3
}
```

**示例**：

```
.:53 {              # 监听所有域名，53 端口
    errors          # 错误日志
    log             # 查询日志
    health          # 健康检查端点
    ready           # 就绪检查端点
    forward . 8.8.8.8  # 转发到 Google DNS
}
```

### 1.3 核心概念

| 概念 | 说明 |
|------|------|
| **Server Block** | Corefile 中的配置块，一个域名+端口组合 |
| **Zone** | DNS 区域，即域名范围（如 `.`、`example.com`） |
| **Plugin** | 插件，处理 DNS 请求的功能单元 |
| **Query** | DNS 查询请求 |
| **Response** | DNS 响应 |

---

## 第二章：架构与工作原理

### 2.1 整体架构

```
┌─────────────────────────────────────────────┐
│              CoreDNS 进程                      │
│                                              │
│  DNS 请求 ──► Server Block 匹配 ──► 插件链    │
│                                              │
│  ┌──────────────────────────────────────┐   │
│  │  插件链（按配置顺序执行）             │   │
│  │                                      │   │
│  │  log ──► cache ──► hosts ──►        │   │
│  │  kubernetes ──► forward ──►          │   │
│  │  errors                              │   │
│  │                                      │   │
│  │  每个插件决定是否处理该请求           │   │
│  │  处理完成后可选择：                   │   │
│  │  - 直接返回响应                       │   │
│  │  - 继续下一个插件（fallthrough）      │   │
│  └──────────────────────────────────────┘   │
│                                              │
│  内部服务端口：                              │
│  - :53    DNS 服务                          │
│  - :8080  健康检查 (/health)                │
│  - :8181  就绪检查 (/ready)                 │
│  - :9153  Prometheus 指标 (/metrics)        │
└─────────────────────────────────────────────┘
```

### 2.2 请求处理流程

```
1. 客户端发送 DNS 查询
   例：dig @10.96.0.10 kubernetes.default.svc.cluster.local

2. CoreDNS 接收请求，匹配 Server Block
   - 根据查询域名匹配对应的 Zone
   - 找到匹配的 Server Block

3. 按顺序执行插件链
   ┌──────────┐
   │ log      │ → 记录查询日志
   └────┬─────┘
        │ fallthrough
        ▼
   ┌──────────┐
   │ cache    │ → 检查缓存，命中则返回
   └────┬─────┘
        │ cache miss
        ▼
   ┌──────────┐
   │ hosts    │ → 检查静态 hosts
   └────┬─────┘
        │ fallthrough
        ▼
   ┌──────────┐
   │kubernetes│ → 查询 K8s Service/Pod
   └────┬─────┘
        │ fallthrough (非 cluster.local 域名)
        ▼
   ┌──────────┐
   │ forward  │ → 转发到上游 DNS
   └────┬─────┘
        │
        ▼
   返回响应

4. 响应沿插件链反向返回
   - 经过 cache（写入缓存）
   - 经过 log（记录响应）
```

### 2.3 插件执行规则

```
每个插件处理请求后，有三种选择：

1. 直接返回响应（终止插件链）
   例：cache 命中，直接返回缓存结果

2. 返回错误（终止插件链）
   例：forward 超时，返回 SERVFAIL

3. 继续下一个插件（fallthrough）
   例：hosts 未匹配，继续执行 kubernetes 插件
```

**重要原则**：插件链中**前面的插件优先**。配置顺序直接影响解析行为。

---

## 第三章：插件系统详解

### 3.1 常用插件速查

| 插件 | 功能 | K8s 默认是否启用 |
|------|------|----------------|
| `kubernetes` | K8s 集群内 DNS 解析 | 是 |
| `forward` | 转发到上游 DNS | 是 |
| `cache` | DNS 缓存 | 是 |
| `hosts` | 静态 hosts 解析 | 否（需手动配置） |
| `errors` | 错误日志 | 是 |
| `log` | 查询日志 | 否 |
| `health` | 健康检查 | 是 |
| `ready` | 就绪检查 | 是 |
| `prometheus` | 指标暴露 | 是 |
| `loop` | 循环检测 | 是 |
| `reload` | 配置热重载 | 是 |
| `loadbalance` | 负载均衡（随机排序 A 记录） | 是 |
| `template` | 模板化 DNS 响应 | 否 |
| `rewrite` | 重写查询 | 否 |
| `etcd` | 从 etcd 读取 DNS 记录 | 否 |

### 3.2 kubernetes 插件

**作用**：处理 `cluster.local` 域名的 DNS 查询，提供 Service 和 Pod 的 DNS 解析。

```
.:53 {
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure          # 启用 Pod DNS（可选：disabled/insecure/verified）
        fallthrough in-addr.arpa ip6.arpa
        ttl 30                 # DNS 记录 TTL
    }
}
```

**解析规则**：

| 资源 | DNS 格式 | 示例 |
|------|---------|------|
| Service A 记录 | `svc-name.namespace.svc.cluster.local` | `my-svc.default.svc.cluster.local` |
| Service ClusterIP | 返回 ClusterIP | `10.96.0.1` |
| Headless Service | 返回所有 Pod IP | `[10.244.1.2, 10.244.1.3]` |
| Pod A 记录（insecure） | `pod-ip.pod-namespace.pod.cluster.local` | `10-244-1-2.default.pod.cluster.local` |
| SRV 记录 | `_port-name._protocol.svc-name.namespace.svc.cluster.local` | `_http._tcp.my-svc.default.svc.cluster.local` |
| PTR 反向解析 | IP 反序.in-addr.arpa | `1.0.96.10.in-addr.arpa` |

**Pod DNS 三种模式**：

| 模式 | 说明 |
|------|------|
| `disabled` | 不启用 Pod DNS（默认） |
| `insecure` | 所有 Pod 都有 DNS 记录（基于 IP，不验证） |
| `verified` | 只有匹配 Pod 名称的才有 DNS 记录 |

### 3.3 forward 插件

**作用**：将未匹配的查询转发到上游 DNS 服务器。

```
forward . /etc/resolv.conf {
    max_concurrent 1000    # 最大并发连接数
    prefer_udp            # 优先使用 UDP（避免 TCP 连接开销）
    policy sequential     # 选择策略：random/sequential/round_robin
}
```

**转发目标格式**：

```
# 单个上游
forward . 8.8.8.8

# 多个上游（负载均衡）
forward . 8.8.8.8 8.8.4.4

# 使用 /etc/resolv.conf 中的配置
forward . /etc/resolv.conf

# 指定端口
forward . 8.8.8.8:53
```

**选择策略**：

| 策略 | 说明 |
|------|------|
| `random` | 随机选择（默认） |
| `round_robin` | 轮询 |
| `sequential` | 按顺序 |

### 3.4 cache 插件

**作用**：缓存 DNS 响应，减少对上游 DNS 的查询。

```
cache {
    success 9984 300    # 成功响应缓存 300 秒，最大 9984 条
    denial 9984 60      # 否定响应（NXDOMAIN）缓存 60 秒
    prefetch 10         # 在 TTL 到期前 10% 时间预取
}
```

**缓存类型**：

| 类型 | 说明 |
|------|------|
| `success` | 成功响应（NOERROR） |
| `denial` | 否定响应（NXDOMAIN、NODATA） |

**预取机制**：
```
TTL = 300 秒
prefetch = 10%

在 TTL 剩余 30 秒时，如果有新的查询：
  1. 返回缓存中的旧结果
  2. 后台异步向上游查询更新缓存
```

### 3.5 hosts 插件

**作用**：提供静态域名解析，类似 `/etc/hosts`。

```
hosts {
    10.131.1.10    api.internal.local
    10.131.1.11    db.internal.local
    10.131.1.12    redis.internal.local
    fallthrough
}
```

**高级用法**：

```
# 引用外部文件
hosts /etc/coredns/custom-hosts {
    fallthrough
}

# 使用系统 hosts 文件
hosts /etc/hosts {
    fallthrough
}

# 定时重载外部文件
hosts /etc/coredns/custom-hosts {
    ttl 60            # 自定义 TTL
    reload 1m         # 每 1 分钟重载文件
    fallthrough
}
```

### 3.6 rewrite 插件

**作用**：重写 DNS 查询，用于域名替换、负载均衡等场景。

```
# 域名重写
rewrite name old.example.com new.example.com

# 正则重写
rewrite name regex (.*)\.dev\.example\.com {1}.example.com

# 指定类型
rewrite name exact my-svc.default.svc.cluster.local my-svc.other.svc.cluster.local
```

### 3.7 template 插件

**作用**：根据模板生成 DNS 响应。

```
# 将 *.dev.local 解析到开发环境
template IN A dev.local {
    match "^.*\.dev\.local\.?$"
    answer "{{ .Name }} 60 IN A 10.131.1.10"
    fallthrough
}

# 通配符解析
template IN A apps.local {
    match "^(?P<app>.*)\.apps\.local\.?$"
    answer "{{ .Name }} 60 IN A 10.131.1.{{ .Group.app }}"
    fallthrough
}
```

---

## 第四章：Kubernetes 中的 CoreDNS

### 4.1 K8s DNS 架构

```
Pod 发起 DNS 查询：my-svc.default.svc.cluster.local
    │
    ├── /etc/resolv.conf
    │   ├── nameserver 10.96.0.10      # CoreDNS Service ClusterIP
    │   ├── search default.svc.cluster.local
    │   ├── search svc.cluster.local
    │   └── search cluster.local
    │
    └── 请求发送到 CoreDNS Service (ClusterIP)
            │
            ├── kube-proxy 转发到 CoreDNS Pod
            │
            └── CoreDNS Pod 处理
                    │
                    ├── kubernetes 插件：返回 Service/Pod IP
                    │
                    └── forward 插件：转发到上游 DNS
```

### 4.2 Pod DNS 配置

```yaml
# Pod 的 /etc/resolv.conf 由 kubelet 生成
apiVersion: v1
kind: Pod
spec:
  dnsPolicy: ClusterFirst    # DNS 策略
  dnsConfig:
    nameservers:
    - 10.96.0.10
    searches:
    - default.svc.cluster.local
    - svc.cluster.local
    - cluster.local
    options:
    - name: ndots
      value: "5"
    - name: timeout
      value: "2"
    - name: attempts
      value: "2"
```

**DNS 策略**：

| 策略 | 说明 |
|------|------|
| `ClusterFirst` | 默认，使用集群 DNS，同时配置上游 DNS |
| `Default` | 使用节点上的 DNS 配置 |
| `ClusterFirstWithHostNet` | 使用 hostNetwork 时仍使用集群 DNS |
| `None` | 完全自定义 DNS 配置（需配合 dnsConfig） |

**ndots 参数**：
```
ndots: 5 表示：
  如果查询域名中的点号少于 5 个，先尝试补全 search 域

例：查询 my-svc
  1. my-svc.default.svc.cluster.local  ← 先尝试
  2. my-svc.svc.cluster.local
  3. my-svc.cluster.local
  4. my-svc  ← 最后尝试原始域名
```

### 4.3 CoreDNS 部署结构

```
Namespace: kube-system

Deployment: coredns
├── Replicas: 2（默认）
├── Pod
│   ├── Container: coredns
│   │   ├── Image: registry.k8s.io/coredns/coredns:v1.11.1
│   │   ├── Port: 53/UDP, 53/TCP
│   │   ├── Config: Corefile (来自 ConfigMap)
│   │   └── LivenessProbe: /health
│   └── Volume: config-volume (ConfigMap coredns)
│
Service: kube-dns
├── ClusterIP: 10.96.0.10（默认）
├── Port: 53/UDP, 53/TCP
└── Selector: k8s-app=kube-dns

ConfigMap: coredns
└── Corefile
```

### 4.4 CoreDNS 水平扩展

```bash
# 根据集群规模调整副本数
# 参考：每 1000 个节点约需要 1-2 个 CoreDNS Pod

kubectl scale deployment coredns -n kube-system --replicas=4

# 使用 PodAntiAffinity 分散部署
kubectl patch deployment coredns -n kube-system --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/affinity", "value": {
    "podAntiAffinity": {
      "preferredDuringSchedulingIgnoredDuringExecution": [
        {
          "weight": 100,
          "podAffinityTerm": {
            "labelSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
            "topologyKey": "kubernetes.io/hostname"
          }
        }
      ]
    }
  }}
]'
```

### 4.5 NodeLocal DNSCache

**问题**：大规模集群中，所有 DNS 查询都经过 CoreDNS Service，可能导致：
- CoreDNS Pod 负载高
- DNS 查询延迟增加
- conntrack 表满（UDP 连接追踪）

**解决方案**：NodeLocal DNSCache

```
传统方式：
  Pod ──► kube-dns Service ──► CoreDNS Pod
  （所有 Pod 共享 CoreDNS Pod，经过 conntrack）

NodeLocal DNSCache：
  Pod ──► 本地 DNS DaemonSet (127.0.0.1:53) ──► CoreDNS
  （每个节点本地缓存，减少跨节点查询）
```

**部署**：

```yaml
# nodelocaldns.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-local-dns
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: node-local-dns
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
    spec:
      containers:
      - name: node-cache
        image: registry.k8s.io/dns/k8s-dns-node-cache:1.22.28
        args:
        - -localip
        - 169.254.20.10          # 本地监听 IP
        - -conf
        - /etc/Corefile
        - -upstreamsvc
        - kube-dns
```

**配合 kubelet 配置**：
```yaml
# /var/lib/kubelet/config.yaml
dnsPolicy: "ClusterFirst"
clusterDNS:
- 169.254.20.10    # 指向 NodeLocal DNSCache
```

---

## 第五章：静态解析与自定义域名

### 5.1 为什么需要静态解析

| 场景 | 说明 |
|------|------|
| 内网域名 | `api.internal.local` 无外网 DNS 记录 |
| 域名劫持防护 | 强制 `docker.io` 指向内部镜像仓库 |
| 多环境隔离 | `*.dev.local` → 开发环境，`*.prod.local` → 生产环境 |
| DNS 故障兜底 | 上游 DNS 故障时提供关键域名解析 |

### 5.2 配置方式对比

| 方式 | 适用场景 | 优缺点 |
|------|---------|--------|
| hosts 插件 inline | 条目少（< 20） | 简单，直接修改 Corefile |
| hosts 插件 + ConfigMap | 条目多（> 20） | 独立管理，需挂载卷 |
| template 插件 | 通配符/模式匹配 | 灵活，支持正则 |
| etcd 插件 | 动态 DNS | 需部署 etcd，复杂 |
| rewrite 插件 | 域名替换 | 不改变原始域名记录 |

### 5.3 完整配置案例

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready

    # 日志配置（生产环境可关闭以减少 IO）
    log . "{remote}:{port} - {>id} '{type} {class} {name} {proto} {size} {>do} {>bufsize}' {rcode} {>rflags} {rsize} {duration}"

    # === 静态解析（高优先级）===
    hosts /etc/coredns/custom-hosts {
        ttl 300
        reload 1m
        fallthrough
    }

    # 通配符域名解析
    template IN A dev.local {
        match "^.*\.dev\.local\.?$"
        answer "{{ .Name }} 60 IN A 10.131.1.10"
        fallthrough
    }

    # === K8s 集群 DNS ===
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
    }

    # Prometheus 指标
    prometheus :9153

    # === 缓存配置 ===
    cache 30 {
        success 9984 300
        denial 9984 60
        prefetch 10
    }

    # === 上游 DNS ===
    forward . /etc/resolv.conf {
        max_concurrent 1000
        prefer_udp
    }

    loop
    reload
    loadbalance
}
```

---

## 第六章：性能调优

### 6.1 性能指标基准

| 指标 | 健康值 | 告警值 |
|------|--------|--------|
| DNS 查询延迟（P99） | < 5ms | > 20ms |
| CoreDNS CPU 使用率 | < 50% | > 80% |
| CoreDNS 内存使用 | < 200MB | > 500MB |
| 缓存命中率 | > 90% | < 70% |
| 并发查询数 | < max_concurrent | 接近上限 |

### 6.2 调优参数

```
# Corefile 调优配置
.:53 {
    # 缓存优化
    cache 30 {
        success 9984 300
        denial 9984 60
        prefetch 10              # 预取，减少缓存穿透
    }

    # 转发优化
    forward . /etc/resolv.conf {
        max_concurrent 1000       # 限制并发连接，防止过载
        prefer_udp               # UDP 比 TCP 开销小
        policy round_robin       # 多个上游时轮询
        expire 10s               # 连接过期时间
    }

    # 负载均衡
    loadbalance round_robin      # A 记录轮询返回
}
```

### 6.3 资源限制

```yaml
# CoreDNS Deployment 资源限制
spec:
  template:
    spec:
      containers:
      - name: coredns
        resources:
          requests:
            cpu: 100m
            memory: 70Mi
          limits:
            cpu: 1000m
            memory: 512Mi
```

### 6.4 大规模集群优化

| 集群规模 | CoreDNS 副本数 | 特殊配置 |
|---------|---------------|---------|
| < 100 节点 | 2 | 默认配置 |
| 100-500 节点 | 4-6 | NodeLocal DNSCache |
| 500-1000 节点 | 8-12 | NodeLocal DNSCache + 高 CPU 限制 |
| > 1000 节点 | 12+ | NodeLocal DNSCache + 专用节点 |

---

## 第七章：监控与可观测性

### 7.1 Prometheus 指标

CoreDNS 暴露的指标：`http://<coredns-pod>:9153/metrics`

| 指标 | 说明 |
|------|------|
| `coredns_dns_requests_total` | DNS 请求总数（按 zone、type 等分类） |
| `coredns_dns_responses_total` | DNS 响应总数 |
| `coredns_forward_requests_total` | 转发请求数 |
| `coredns_forward_responses_total` | 转发响应数 |
| `coredns_cache_hits_total` | 缓存命中数 |
| `coredns_cache_misses_total` | 缓存未命中数 |
| `coredns_cache_size` | 缓存条目数 |
| `coredns_dns_request_duration_seconds` | DNS 请求延迟分布 |
| `coredns_forward_request_duration_seconds` | 转发请求延迟分布 |
| `coredns_panics_total` | CoreDNS panic 次数 |

**常用 PromQL**：

```promql
# DNS 查询速率
rate(coredns_dns_requests_total[5m])

# 缓存命中率
rate(coredns_cache_hits_total[5m]) /
  (rate(coredns_cache_hits_total[5m]) + rate(coredns_cache_misses_total[5m]))

# P99 DNS 延迟
histogram_quantile(0.99,
  rate(coredns_dns_request_duration_seconds_bucket[5m]))

# 转发错误率
rate(coredns_forward_responses_total{rcode="SERVFAIL"}[5m]) /
  rate(coredns_forward_requests_total[5m])
```

### 7.2 日志配置

```
# 详细日志（调试用）
log . "{remote}:{port} - {>id} '{type} {class} {name} {proto} {size} {>do} {>bufsize}' {rcode} {>rflags} {rsize} {duration}"

# 简化日志
log . "{type} {name} {rcode} {duration}"

# 关闭日志（生产环境减少 IO）
# 注释掉 log 插件即可
```

**日志字段说明**：

| 字段 | 说明 |
|------|------|
| `{remote}` | 客户端 IP |
| `{port}` | 客户端端口 |
| `{type}` | 查询类型（A、AAAA、PTR 等） |
| `{class}` | 查询类（IN） |
| `{name}` | 查询域名 |
| `{proto}` | 协议（udp/tcp） |
| `{rcode}` | 响应码（NOERROR、NXDOMAIN、SERVFAIL） |
| `{duration}` | 处理耗时 |

---

## 第八章：故障排查手册

### 8.1 排查流程图

```
Pod DNS 解析失败
    │
    ├── 1. 检查 Pod /etc/resolv.conf
    │       ├── nameserver 是否正确？
    │       └── search 域是否配置？
    │
    ├── 2. 检查 CoreDNS Pod 状态
    │       ├── kubectl get pod -n kube-system -l k8s-app=kube-dns
    │       └── 是否 Running？是否 Ready？
    │
    ├── 3. 检查 CoreDNS 配置
    │       ├── kubectl get cm coredns -n kube-system
    │       └── Corefile 语法是否正确？
    │
    ├── 4. 测试 CoreDNS 直接解析
    │       ├── 进入 Pod：nslookup <domain> 10.96.0.10
    │       └── 是否能解析？
    │
    ├── 5. 检查 CoreDNS 日志
    │       ├── kubectl logs -n kube-system -l k8s-app=kube-dns
    │       └── 是否有 error？
    │
    └── 6. 检查上游 DNS
            ├── forward 配置是否正确？
            └── 上游 DNS 是否可达？
```

### 8.2 常见故障及解决

#### 故障 1：CoreDNS Pod CrashLoopBackOff

**原因**：Corefile 语法错误

```bash
# 查看日志
kubectl logs -n kube-system deployment/coredns

# 典型错误
# /etc/coredns/Corefile:4 - Error during parsing: Unknown directive 'host'

# 修复：检查 Corefile 拼写
kubectl edit cm coredns -n kube-system
# 修正后重启
kubectl rollout restart deployment coredns -n kube-system
```

#### 故障 2：DNS 查询超时

**排查**：

```bash
# 1. 测试 CoreDNS 是否可达
kubectl run -it --rm debug --image=busybox -- nc -vz 10.96.0.10 53

# 2. 检查 CoreDNS 负载
kubectl top pod -n kube-system -l k8s-app=kube-dns

# 3. 检查上游 DNS
kubectl exec -it -n kube-system deployment/coredns -- cat /etc/resolv.conf

# 4. 测试上游 DNS
kubectl exec -it -n kube-system deployment/coredns -- nslookup example.com <upstream-ip>
```

**解决**：
- CoreDNS 负载高：增加副本数
- 上游 DNS 慢：优化 forward 配置，使用本地 DNS
- conntrack 表满：部署 NodeLocal DNSCache

#### 故障 3：集群内域名解析失败

**排查**：

```bash
# 1. 测试 Service DNS
kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default

# 2. 检查 kubernetes 插件配置
kubectl get cm coredns -n kube-system -o yaml
# 确认包含：kubernetes cluster.local in-addr.arpa ip6.arpa

# 3. 检查 Service 是否存在
kubectl get svc kubernetes

# 4. 检查 CoreDNS 是否有权限访问 apiserver
kubectl auth can-i list services --as=system:serviceaccount:kube-system:coredns
```

#### 故障 4：静态 hosts 不生效

**排查**：

```bash
# 1. 检查 Corefile 中 hosts 插件位置
# hosts 必须在 kubernetes 之前，否则会被 kubernetes 拦截

# 2. 检查 fallthrough
# 如果 hosts 没有 fallthrough，未匹配的域名不会继续处理

# 3. 检查域名是否带尾部点号
# DNS 查询可能带尾部点号：api.internal.local.
# hosts 中也需要配置带点的版本

# 4. 验证配置已加载
kubectl exec -it -n kube-system deployment/coredns -- cat /etc/coredns/Corefile
```

#### 故障 5：DNS 缓存不生效

**原因**：
- 查询类型不在缓存范围内（如 PTR 反向解析）
- TTL 设置过短
- 否定缓存（NXDOMAIN）未启用

**解决**：
```
cache 30 {
    success 9984 300
    denial 9984 60    # 启用否定缓存
    prefetch 10        # 启用预取
}
```

### 8.3 排查命令速查

```bash
# CoreDNS 状态
kubectl get pod -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns
kubectl get cm -n kube-system coredns

# CoreDNS 配置
kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}'

# CoreDNS 日志
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100
kubectl logs -n kube-system -l k8s-app=kube-dns --previous

# DNS 测试
kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default
kubectl run -it --rm debug --image=busybox -- nslookup <domain> 10.96.0.10
kubectl run -it --rm debug --image=busybox -- dig @10.96.0.10 <domain>

# Pod DNS 配置
kubectl run -it --rm debug --image=busybox -- cat /etc/resolv.conf

# CoreDNS 指标
curl http://<coredns-pod-ip>:9153/metrics | grep coredns_dns

# 抓包
kubectl exec -it <coredns-pod> -n kube-system -- tcpdump -i eth0 port 53 -nn
```

---

## 第九章：高级主题

### 9.1 自定义插件开发

CoreDNS 插件是 Go 模块，需实现 `plugin.Handler` 接口。

```go
package myplugin

import (
    "context"
    "github.com/coredns/coredns/plugin"
    "github.com/coredns/coredns/request"
    "github.com/miekg/dns"
)

type MyPlugin struct {
    Next plugin.Handler
}

func (m MyPlugin) ServeDNS(ctx context.Context, w dns.ResponseWriter, r *dns.Msg) (int, error) {
    state := request.Request{W: w, Req: r}

    // 只处理 A 记录查询
    if state.QType() != dns.TypeA {
        return plugin.NextOrFailure(m.Name(), m.Next, ctx, w, r)
    }

    // 自定义逻辑
    if state.Name() == "custom.example.com." {
        msg := new(dns.Msg)
        msg.SetReply(r)
        msg.Answer = append(msg.Answer, &dns.A{
            Hdr: dns.RR_Header{Name: state.Name(), Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 300},
            A:   net.ParseIP("10.0.0.1"),
        })
        w.WriteMsg(msg)
        return dns.RcodeSuccess, nil
    }

    // 未匹配，继续下一个插件
    return plugin.NextOrFailure(m.Name(), m.Next, ctx, w, r)
}

func (m MyPlugin) Name() string { return "myplugin" }
```

### 9.2 CoreDNS 与 Istio 集成

Istio 使用 CoreDNS 进行服务发现：

```
Pod ──► Istio Sidecar (Envoy) ──► CoreDNS
              │
              ├── 获取 Service IP
              └── 建立连接
```

Istio 的 DNS 代理（1.8+）：
```
# Istio 在 Sidecar 中内置 DNS 代理
# 优先使用 Istio 内部服务注册表
# 未匹配时转发到 CoreDNS
```

### 9.3 多租户 DNS 隔离

使用 View 插件（外部插件）实现基于客户端 IP 的不同解析：

```
view {
    expr client_ip() in ['10.244.1.0/24']
    .
    kubernetes cluster.local {
        namespaces dev
    }
}

view {
    expr client_ip() in ['10.244.2.0/24']
    .
    kubernetes cluster.local {
        namespaces prod
    }
}
```

---

## 第十章：面试常见问题

### Q1: CoreDNS 和 kube-dns 有什么区别？

**答**：
- CoreDNS 是单进程、插件化架构；kube-dns 是多组件（dnsmasq + skydns + sidecar）
- CoreDNS 性能更高，配置更简单（Corefile），扩展性更好
- CoreDNS 内置健康检查、Prometheus 指标
- K8s 1.11+ CoreDNS 成为默认 DNS

### Q2: Pod 的 DNS 解析流程？

**答**：
1. Pod 读取 `/etc/resolv.conf`，获取 nameserver（CoreDNS ClusterIP）
2. DNS 查询发送到 CoreDNS Service
3. kube-proxy 将请求转发到某个 CoreDNS Pod
4. CoreDNS 按插件链处理：log → cache → hosts → kubernetes → forward
5. 返回解析结果

### Q3: CoreDNS 的缓存机制？

**答**：
- cache 插件缓存 DNS 响应
- 分为 success 缓存（NOERROR）和 denial 缓存（NXDOMAIN）
- 支持预取（prefetch），在 TTL 过期前主动更新
- 缓存大小和 TTL 可配置

### Q4: 如何实现静态 DNS 解析？

**答**：
- 使用 hosts 插件：在 Corefile 中直接配置 IP-域名映射
- 使用 hosts 插件 + 外部文件：将 hosts 配置放在 ConfigMap 中挂载
- 使用 template 插件：通配符匹配和模板化响应
- 配置后需要重启 CoreDNS 或等待 reload

### Q5: CoreDNS Pod 频繁重启怎么办？

**答**：
1. 查看日志定位原因（通常是 Corefile 语法错误）
2. 检查 ConfigMap 配置
3. 检查资源限制是否过低（OOMKilled）
4. 检查是否有循环查询（loop 插件检测到循环会 panic）

### Q6: NodeLocal DNSCache 解决了什么问题？

**答**：
- 减少 DNS 查询延迟（本地缓存）
- 降低 CoreDNS 负载
- 避免 conntrack 表满（UDP 连接追踪限制）
- 提高 DNS 可用性（CoreDNS 故障时本地缓存仍可工作）

### Q7: 如何排查 DNS 解析慢？

**答**：
1. 测试 CoreDNS 直接解析延迟
2. 检查 CoreDNS 资源使用（CPU/内存）
3. 检查上游 DNS 延迟
4. 检查缓存命中率
5. 考虑部署 NodeLocal DNSCache
6. 检查 ndots 配置（不必要的 search 域补全）

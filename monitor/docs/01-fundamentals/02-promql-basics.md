# PromQL 基础教程

## 1. PromQL 数据类型

| 类型 | 说明 | 示例 |
|------|------|------|
| **Instant Vector** | 每个时序单个样本 | `http_requests_total` |
| **Range Vector** | 每个时序一段时间样本 | `http_requests_total[5m]` |
| **Scalar** | 浮点数值 | `3.14` |
| **String** | 字符串字面量 | `"some text"` |

---

## 2. 基础查询

### 2.1 选择器（Selectors）

```promql
# 查询所有指标
http_requests_total

# 带标签过滤
http_requests_total{job="api", status="200"}

# 正则匹配
http_requests_total{status=~"2.."}       # 2xx 状态码
http_requests_total{status!~"4..|5.."}   # 排除 4xx 和 5xx

# 多标签过滤
http_requests_total{job="api", method="GET", status="200"}
```

### 2.2 范围查询

```promql
# 过去 5 分钟的数据
http_requests_total[5m]

# 常用时间单位
# s = 秒, m = 分钟, h = 小时, d = 天, w = 周, y = 年

http_requests_total[1h]   # 过去1小时
http_requests_total[1d]   # 过去1天
```

---

## 3. 聚合操作符

```promql
# sum: 求和
sum(http_requests_total)

# avg: 平均值
avg(node_cpu_seconds_total{mode!="idle"})

# min/max: 最小/最大值
min(node_memory_MemAvailable_bytes)
max(node_memory_MemAvailable_bytes)

# count: 计数
count(up{job="kubernetes-nodes"})

# count_values: 按值统计分布
count_values("version", build_info)

# topk/bottomk: 最大/最小的 K 个
topk(5, http_requests_total)
bottomk(3, node_memory_MemAvailable_bytes)

# quantile: 分位数
quantile(0.95, http_request_duration_seconds)
```

### 聚合 by / without

```promql
# 按 instance 分组求和
sum by (instance) (node_cpu_seconds_total{mode!="idle"})

# 排除 mode 标签后求和
sum without (mode) (node_cpu_seconds_total)
```

---

## 4.  rate / irate / increase（计数器专用）

> **重要**：查询 Counter 指标必须使用 rate() 或 irate()，不能直接查询！

```promql
# rate: 计算每秒平均增长率（推荐）
rate(http_requests_total[5m])

# irate: 使用最后两个样本计算瞬时率（对突变更敏感）
irate(http_requests_total[5m])

# increase: 计算时间范围内总增量
increase(http_requests_total[1h])

# resets: 计算计数器重置次数
resets(uptime_seconds[1d])
```

### 最佳实践
- rate() 时间范围至少为 scrape interval 的 2-3 倍
- 30s 采集间隔 → 使用 `[2m]` 或更长
- 60s 采集间隔 → 使用 `[5m]` 或更长

---

## 5. 数学与比较运算

```promql
# 数学运算
node_memory_MemAvailable_bytes / 1024 / 1024 / 1024   # 转换为 GB

# 百分比计算
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 比较运算（返回 0 或 1）
up == 0                    # 实例宕机
http_requests_total > 1000

# 比较过滤（只返回满足条件的序列）
http_requests_total{job="api"} > 100

# 逻辑运算
up{job="api"} and http_requests_total > 0
```

---

## 6. 常用函数

### 6.1 时间函数

```promql
# 时间戳相关
time()                     # 当前 Unix 时间戳
day_of_week()              # 星期几 (0=周日)
hour()                     # 当前小时
minute()                   # 当前分钟
```

### 6.2 变化检测

```promql
# delta: Gauge 的差值（不推荐用于 Counter）
delta(node_memory_MemAvailable_bytes[1h])

# deriv: Gauge 的每秒导数（线性回归）
deriv(node_memory_MemAvailable_bytes[1h])

# changes: 样本值变化次数
changes(up[1h])            # 1小时内状态变化次数

# predict_linear: 线性预测
predict_linear(node_filesystem_free_bytes[1h], 4 * 3600)  # 预测4小时后磁盘剩余
```

### 6.3 Histogram 分位数

```promql
# histogram_quantile: 从 Histogram 计算分位数
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)

# 按服务分组计算 P99
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
)
```

### 6.4 其他实用函数

```promql
# absent: 检查序列是否存在（用于告警）
absent(up{job="critical"} == 1)

# clamp_min / clamp_max: 限制最小/最大值
clamp_min(http_requests_total, 0)

# label_join / label_replace: 标签操作
label_join(instance_cpu, "host_port", ":", "instance", "port")
label_replace(up, "ip", "$1", "instance", "(.*):.*")
```

---

## 7. 实战查询示例

### 7.1 节点监控

```promql
# CPU 使用率（排除 idle）
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 内存使用率
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# 磁盘使用率
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# 网络流量
rate(node_network_receive_bytes_total[5m])
rate(node_network_transmit_bytes_total[5m])
```

### 7.2 Kubernetes 监控

```promql
# Pod 重启次数
increase(kube_pod_container_status_restarts_total[1h])

# Pod CPU 使用率
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (pod, namespace)

# Pod 内存使用
sum(container_memory_working_set_bytes{container!=""}) by (pod, namespace)

# Deployment 可用副本比例
kube_deployment_status_replicas_ready / kube_deployment_spec_replicas
```

### 7.3 应用监控

```promql
# HTTP QPS
sum(rate(http_requests_total[5m]))

# HTTP 错误率
sum(rate(http_requests_total{status=~"5.."}[5m])) 
/ sum(rate(http_requests_total[5m]))

# P99 延迟
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)

# 各状态码占比
sum by (status) (rate(http_requests_total[5m]))
```

---

## 8. Recording Rules 示例

```yaml
groups:
  - name: example
    interval: 30s
    rules:
      # 预计算 CPU 使用率
      - record: instance:node_cpu:avg_rate5m
        expr: avg by(instance) (rate(node_cpu_seconds_total[5m]))
      
      # 预计算 HTTP 请求率
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)
      
      # 预计算错误率
      - record: job:http_errors:rate5m
        expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
```

---

## 参考资源

- [PromQL 官方文档](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [PromQL for Humans](https://timber.io/blog/promql-for-humans/)
- [PromQL 查询示例](https://prometheus.io/docs/prometheus/latest/querying/examples/)

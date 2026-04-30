# 自定义 Exporter / Collector 开发

> 市场 JD 高频要求："精通 Python 或 Go，能独立开发监控插件、告警处理器"、"Prometheus 定制化经验"

---

## 1. Go 开发自定义 Prometheus Exporter

### 1.1 Exporter 核心原理

```
┌─────────────┐      HTTP GET /metrics      ┌─────────────┐
│  Prometheus │  ─────────────────────────▶ │  Exporter   │
│   Server    │  ◀───────────────────────── │  (你的程序)  │
└─────────────┘    text/plain 指标数据      └─────────────┘
```

### 1.2 完整 Exporter 示例

```go
package main

import (
	"flag"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"log/slog"
)

// 定义指标
var (
	// Counter: 请求总数
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "myapp_http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"method", "endpoint", "status"},
	)

	// Gauge: 当前在线用户数
	activeUsers = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "myapp_active_users",
			Help: "Number of active users",
		},
	)

	// Histogram: 请求延迟分布
	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "myapp_http_request_duration_seconds",
			Help:    "HTTP request latency in seconds",
			Buckets: prometheus.DefBuckets, // 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
		},
		[]string{"method", "endpoint"},
	)

	// Summary: 请求延迟分位
	httpRequestSummary = prometheus.NewSummaryVec(
		prometheus.SummaryOpts{
			Name:       "myapp_http_request_duration_summary",
			Help:       "HTTP request latency summary",
			Objectives: map[float64]float64{0.5: 0.05, 0.9: 0.01, 0.99: 0.001},
		},
		[]string{"method", "endpoint"},
	)
)

func init() {
	// 注册指标
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(activeUsers)
	prometheus.MustRegister(httpRequestDuration)
	prometheus.MustRegister(httpRequestSummary)
}

func main() {
	var addr = flag.String("listen-address", ":8080", "The address to listen on for HTTP requests")
	flag.Parse()

	// 启动后台采集 goroutine
	go collectMetrics()

	// 暴露指标端点
	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/api/health", healthHandler)
	http.HandleFunc("/api/order", instrumentHandler("/api/order", orderHandler))

	slog.Info("Starting exporter", "addr", *addr)
	http.ListenAndServe(*addr, nil)
}

// 模拟业务 handler
func orderHandler(w http.ResponseWriter, r *http.Request) {
	// 业务逻辑...
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("Order created"))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// HTTP 中间件：自动记录指标
func instrumentHandler(endpoint string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// 包装 ResponseWriter 以捕获状态码
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(rw, r)

		duration := time.Since(start).Seconds()

		// 记录指标
		httpRequestsTotal.WithLabelValues(r.Method, endpoint, http.StatusText(rw.statusCode)).Inc()
		httpRequestDuration.WithLabelValues(r.Method, endpoint).Observe(duration)
		httpRequestSummary.WithLabelValues(r.Method, endpoint).Observe(duration)
	}
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

// 后台采集指标
func collectMetrics() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		// 模拟采集当前在线用户数
		users := float64(time.Now().Second() * 100) // 模拟数据
		activeUsers.Set(users)
	}
}
```

### 1.3 自定义 Collector（高级）

```go
package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

// 自定义 Collector
type MyCollector struct {
	temperature *prometheus.Desc
}

func NewMyCollector() *MyCollector {
	return &MyCollector{
		temperature: prometheus.NewDesc(
			"hardware_temperature_celsius",
			"Current temperature in Celsius",
			[]string{"sensor", "location"},
			prometheus.Labels{"device": "server01"},
		),
	}
}

// Describe 实现 prometheus.Collector
func (c *MyCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.temperature
}

// Collect 实现 prometheus.Collector
func (c *MyCollector) Collect(ch chan<- prometheus.Metric) {
	// 从硬件读取温度
	temp := readHardwareTemperature()

	ch <- prometheus.MustNewConstMetric(
		c.temperature,
		prometheus.GaugeValue,
		temp,
		"cpu", "chassis",
	)
}

func readHardwareTemperature() float64 {
	// 实际实现：读取 /sys/class/thermal 或 IPMI
	return 45.5
}

// 注册使用
// prometheus.MustRegister(NewMyCollector())
```

---

## 2. 自定义 OpenTelemetry Collector Processor

### 2.1 Processor 开发框架

```go
package myprocessor

import (
	"context"
	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/consumer"
	"go.opentelemetry.io/collector/pdata/ptrace"
	"go.opentelemetry.io/collector/processor"
)

// Config 定义配置
type Config struct {
	DropAttribute string `mapstructure:"drop_attribute"`
}

// 创建 Factory
func NewFactory() processor.Factory {
	return processor.NewFactory(
		"myprocessor",
		createDefaultConfig,
		processor.WithTraces(createTracesProcessor, component.StabilityLevelBeta),
	)
}

func createDefaultConfig() component.Config {
	return &Config{
		DropAttribute: "sensitive_data",
	}
}

func createTracesProcessor(
	ctx context.Context,
	set processor.CreateSettings,
	cfg component.Config,
	nextConsumer consumer.Traces,
) (processor.Traces, error) {
	config := cfg.(*Config)
	return &myProcessor{
		config:   config,
		next:     nextConsumer,
	}, nil
}

type myProcessor struct {
	config *Config
	next   consumer.Traces
}

func (p *myProcessor) Capabilities() consumer.Capabilities {
	return consumer.Capabilities{MutatesData: true}
}

func (p *myProcessor) ConsumeTraces(ctx context.Context, td ptrace.Traces) error {
	// 遍历所有 Span，删除敏感属性
	for i := 0; i < td.ResourceSpans().Len(); i++ {
		rs := td.ResourceSpans().At(i)
		for j := 0; j < rs.ScopeSpans().Len(); j++ {
			ss := rs.ScopeSpans().At(j)
			for k := 0; k < ss.Spans().Len(); k++ {
				span := ss.Spans().At(k)
				span.Attributes().RemoveIf(func(key string, _ pcommon.Value) bool {
					return key == p.config.DropAttribute
				})
			}
		}
	}
	return p.next.ConsumeTraces(ctx, td)
}

func (p *myProcessor) Start(ctx context.Context, host component.Host) error { return nil }
func (p *myProcessor) Shutdown(ctx context.Context) error                   { return nil }
```

---

## 3. 自定义告警处理器

### 3.1 Alertmanager Webhook 接收器

```go
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Alertmanager Webhook 数据格式
type AlertManagerWebhook struct {
	Version           string            `json:"version"`
	GroupKey          string            `json:"groupKey"`
	TruncatedAlerts   int               `json:"truncatedAlerts"`
	Status            string            `json:"status"`
	Receiver          string            `json:"receiver"`
	GroupLabels       map[string]string `json:"groupLabels"`
	CommonLabels      map[string]string `json:"commonLabels"`
	CommonAnnotations map[string]string `json:"commonAnnotations"`
	ExternalURL       string            `json:"externalURL"`
	Alerts            []Alert           `json:"alerts"`
}

type Alert struct {
	Status       string            `json:"status"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     time.Time         `json:"startsAt"`
	EndsAt       time.Time         `json:"endsAt"`
	GeneratorURL string            `json:"generatorURL"`
	Fingerprint  string            `json:"fingerprint"`
}

func webhookHandler(w http.ResponseWriter, r *http.Request) {
	var webhook AlertManagerWebhook
	if err := json.NewDecoder(r.Body).Decode(&webhook); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// 智能降噪：同一服务 5 分钟内只发送一次
	for _, alert := range webhook.Alerts {
		if shouldNotify(alert) {
			sendToSlack(alert)
			sendToDingTalk(alert)
		}
	}

	w.WriteHeader(http.StatusOK)
}

var notificationCache = make(map[string]time.Time)

func shouldNotify(alert Alert) bool {
	key := alert.Labels["alertname"] + ":" + alert.Labels["service"]
	lastTime, exists := notificationCache[key]
	if !exists || time.Since(lastTime) > 5*time.Minute {
		notificationCache[key] = time.Now()
		return true
	}
	return false
}

func sendToSlack(alert Alert) {
	color := "danger"
	if alert.Status == "resolved" {
		color = "good"
	}

	payload := map[string]interface{}{
		"attachments": []map[string]interface{}{
			{
				"color": color,
				"title": alert.Annotations["summary"],
				"text":  alert.Annotations["description"],
				"fields": []map[string]string{
					{"title": "Status", "value": alert.Status, "short": true},
					{"title": "Severity", "value": alert.Labels["severity"], "short": true},
					{"title": "Service", "value": alert.Labels["service"], "short": true},
					{"title": "Instance", "value": alert.Labels["instance"], "short": true},
				},
				"footer": alert.GeneratorURL,
				"ts":     alert.StartsAt.Unix(),
			},
		},
	}

	jsonPayload, _ := json.Marshal(payload)
	http.Post("https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
		"application/json", bytes.NewBuffer(jsonPayload))
}

func sendToDingTalk(alert Alert) {
	// 钉钉机器人实现类似...
}

func main() {
	http.HandleFunc("/webhook", webhookHandler)
	http.ListenAndServe(":8080", nil)
}
```

---

## 4. 面试编程题

### 4.1 题目一：实现一个简单的 Metrics 缓存

```go
// 要求：实现一个线程安全的指标缓存，支持 Increment/Set/Get
// 考察：sync.RWMutex、map 并发安全

type MetricsCache struct {
	mu      sync.RWMutex
	counters map[string]float64
	gauges   map[string]float64
}

func (c *MetricsCache) Inc(name string, value float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counters[name] += value
}

func (c *MetricsCache) Set(name string, value float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.gauges[name] = value
}

func (c *MetricsCache) GetCounter(name string) float64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.counters[name]
}
```

### 4.2 题目二：实现滑动窗口限流器

```go
// 要求：基于滑动窗口实现 API 限流，用于保护监控查询接口
// 考察：时间窗口算法、并发控制

type SlidingWindowLimiter struct {
	windowSize time.Duration
	maxRequests int
	timestamps  []time.Time
	mu          sync.Mutex
}

func (l *SlidingWindowLimiter) Allow() bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-l.windowSize)

	// 清理过期时间戳
	valid := make([]time.Time, 0)
	for _, ts := range l.timestamps {
		if ts.After(cutoff) {
			valid = append(valid, ts)
		}
	}
	l.timestamps = valid

	// 检查是否超过限制
	if len(l.timestamps) >= l.maxRequests {
		return false
	}

	l.timestamps = append(l.timestamps, now)
	return true
}
```

---

## 参考资源

- [Prometheus Client Go](https://github.com/prometheus/client_golang)
- [OpenTelemetry Collector Builder](https://opentelemetry.io/docs/collector/custom-collector/)
- [Building a Prometheus Exporter](https://prometheus.io/docs/instrumenting/writing_exporters/)

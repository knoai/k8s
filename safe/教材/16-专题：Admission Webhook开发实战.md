# 第16章 专题：自定义 Admission Webhook 开发实战

> **本章目标**：从零开始用 Go 语言构建生产级的 Validating + Mutating Webhook。当 Kyverno/OPA 无法满足复杂业务逻辑时，自定义 Webhook 是最终的灵活解决方案。
>
> 读完本章后，你应该能够：理解 Webhook 架构和工作流程；开发 Mutating 和 Validating Webhook；管理 TLS 证书；部署高可用的 Webhook 服务；调试 Webhook 问题。

---

## 16.1 Webhook 架构与原理

### 16.1.1 K8s 准入控制完整链路

```
用户提交资源 (kubectl apply -f pod.yaml)
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  1. 认证（Authentication）                                   │
│     验证用户身份（X.509 / Token / OIDC / Webhook）           │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  2. 授权（Authorization）                                    │
│     RBAC 检查用户是否有权限执行操作                          │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Mutating Admission（变更准入）                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ Webhook 1   │  │ Webhook 2   │  │ Webhook N   │         │
│  │ (自动注入   │  │ (设置默认   │  │ (Sidecar    │         │
│  │  Sidecar)   │  │  资源限制)  │  │  注入)      │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                │
│         └────────┬───────┴────────────────┘                │
│                  ▼                                          │
│           资源被顺序修改                                    │
│           （每个 Webhook 看到前一个的结果）                  │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  4. Schema Validation（对象验证）                            │
│     验证资源是否符合 OpenAPI Schema                          │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  5. Validating Admission（验证准入）                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ Webhook A   │  │ Webhook B   │  │ Webhook Z   │         │
│  │ (禁止特权  │  │ (检查标签   │  │ (镜像签名   │         │
│  │  容器)      │  │  完整性)    │  │  验证)      │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                │
│         └────────┬───────┴────────────────┘                │
│                  ▼                                          │
│           全部通过 → 准入成功                                │
│           任一拒绝 → 准入失败（返回错误）                    │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
    写入 etcd
```

### 16.1.2 Webhook 配置资源详解

```yaml
# MutatingWebhookConfiguration
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: security-mutator
webhooks:
- name: pod-security-mutator.webhook-system.svc
  # 匹配规则：什么资源、什么操作触发
  rules:
  - apiGroups: [""]           # "" = core group
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
    scope: "Namespaced"       # 或 "*" 匹配所有范围

  # 客户端配置：Webhook 服务地址
  clientConfig:
    service:
      namespace: webhook-system
      name: webhook-service
      path: "/mutate"
      port: 443
    caBundle: <base64-encoded-ca>  # 信任 CA 证书

  # 准入审查版本
  admissionReviewVersions: ["v1"]

  # 副作用：Webhook 是否可能产生副作用（如创建其他资源）
  # None = 无副作用（Dry Run 安全）
  # Some = 有副作用（Dry Run 时会跳过）
  sideEffects: None

  # 超时：API Server 等待 Webhook 响应的时间
  timeoutSeconds: 5

  # 失败策略：Webhook 不可用时如何处理
  # Fail = 阻断请求（安全但严格）
  # Ignore = 忽略 Webhook 错误（宽松但可能不安全）
  failurePolicy: Fail

  # 命名空间选择器：只对匹配的命名空间生效
  namespaceSelector:
    matchExpressions:
    - key: security-webhook
      operator: NotIn
      values: ["disabled"]

  # 对象选择器：只对带特定标签的对象生效
  objectSelector:
    matchLabels:
      app.kubernetes.io/managed-by: "helm"

  # 重新调用策略（仅 Mutating）
  # IfNeeded = 如果修改了对象，允许其他 Webhook 再次调用
  # Never = 不重新调用
  reinvocationPolicy: IfNeeded

  # 匹配条件（K8s 1.28+）
  matchConditions:
  - name: "exclude-system-namespaces"
    expression: "object.metadata.namespace != 'kube-system'"
```

---

## 16.2 Webhook 开发实战

### 16.2.1 项目结构

```
my-webhook/
├── main.go                      # HTTP 服务器入口
├── go.mod / go.sum              # Go 依赖
├── Dockerfile                   # 多阶段构建
├── Makefile                     # 构建脚本
├── deploy/
│   ├── namespace.yaml           # webhook-system 命名空间
│   ├── rbac.yaml                # ServiceAccount + RBAC
│   ├── deployment.yaml          # Webhook Deployment
│   ├── service.yaml             # ClusterIP Service
│   ├── webhook-config.yaml      # Mutating + Validating 配置
│   └── certs/                   # TLS 证书（或用 cert-manager）
├── pkg/
│   ├── handler/
│   │   ├── mutate.go            # Mutating 逻辑
│   │   ├── validate.go          # Validating 逻辑
│   │   └── common.go            # 共享工具函数
│   ├── patch/
│   │   └── jsonpatch.go         # JSON Patch 构造器
│   └── tls/
│       └── cert.go              # 证书管理（可选）
└── test/
    └── handler_test.go          # 单元测试
```

### 16.2.2 核心代码

**main.go**：

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/utils/pointer"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var (
	scheme       = runtime.NewScheme()
	codecs       = serializer.NewCodecFactory(scheme)
	deserializer = codecs.UniversalDeserializer()
)

type patchOperation struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", readyHandler)
	mux.HandleFunc("/mutate", mutateHandler)
	mux.HandleFunc("/validate", validateHandler)

	certFile := "/etc/webhook/certs/tls.crt"
	keyFile := "/etc/webhook/certs/tls.key"

	srv := &http.Server{
		Addr:         ":8443",
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	go func() {
		log.Println("Starting webhook server on :8443")
		if err := srv.ListenAndServeTLS(certFile, keyFile); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start server: %v", err)
		}
	}()

	// 优雅关闭
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down webhook server...")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("Server forced to shutdown: %v", err)
	}
	log.Println("Server exited")
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func readyHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ready"))
}

func mutateHandler(w http.ResponseWriter, r *http.Request) {
	admissionReview, err := parseAdmissionReview(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var pod corev1.Pod
	if err := json.Unmarshal(admissionReview.Request.Object.Raw, &pod); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// 排除系统命名空间
	if isSystemNamespace(pod.Namespace) {
		sendAllowResponse(w, admissionReview)
		return
	}

	patches := []patchOperation{}

	// 1. 注入 Pod 级 SecurityContext
	if pod.Spec.SecurityContext == nil {
		patches = append(patches, patchOperation{
			Op:   "add",
			Path: "/spec/securityContext",
			Value: corev1.PodSecurityContext{
				RunAsNonRoot: pointer.Bool(true),
				SeccompProfile: &corev1.SeccompProfile{
					Type: corev1.SeccompProfileTypeRuntimeDefault,
				},
			},
		})
	}

	// 2. 为每个容器添加安全上下文
	for i := range pod.Spec.Containers {
		path := fmt.Sprintf("/spec/containers/%d/securityContext", i)
		patches = append(patches, patchOperation{
			Op:   "add",
			Path: path,
			Value: corev1.SecurityContext{
				AllowPrivilegeEscalation: pointer.Bool(false),
				ReadOnlyRootFilesystem:   pointer.Bool(true),
				Capabilities: &corev1.Capabilities{
					Drop: []corev1.Capability{"ALL"},
				},
			},
		})
	}

	// 3. 自动注入资源限制（如果未设置）
	for i := range pod.Spec.Containers {
		if pod.Spec.Containers[i].Resources.Limits == nil {
			path := fmt.Sprintf("/spec/containers/%d/resources", i)
			patches = append(patches, patchOperation{
				Op:   "add",
				Path: path,
				Value: corev1.ResourceRequirements{
					Limits: corev1.ResourceList{
						corev1.ResourceMemory: *resource.NewQuantity(256*1024*1024, resource.BinarySI), // 256Mi
						corev1.ResourceCPU:    *resource.NewMilliQuantity(500, resource.DecimalSI),      // 500m
					},
					Requests: corev1.ResourceList{
						corev1.ResourceMemory: *resource.NewQuantity(64*1024*1024, resource.BinarySI), // 64Mi
						corev1.ResourceCPU:    *resource.NewMilliQuantity(100, resource.DecimalSI),     // 100m
					},
				},
			})
		}
	}

	patchBytes, err := json.Marshal(patches)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	patchType := admissionv1.PatchTypeJSONPatch
	admissionResponse := &admissionv1.AdmissionResponse{
		UID:       admissionReview.Request.UID,
		Allowed:   true,
		Patch:     patchBytes,
		PatchType: &patchType,
	}

	sendResponse(w, admissionReview, admissionResponse)
}

func validateHandler(w http.ResponseWriter, r *http.Request) {
	admissionReview, err := parseAdmissionReview(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var pod corev1.Pod
	if err := json.Unmarshal(admissionReview.Request.Object.Raw, &pod); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	allowed := true
	var messages []string

	// 1. 检查特权容器
	for _, container := range pod.Spec.Containers {
		if container.SecurityContext != nil &&
			container.SecurityContext.Privileged != nil &&
			*container.SecurityContext.Privileged {
			allowed = false
			messages = append(messages, fmt.Sprintf("Container %s is privileged", container.Name))
		}
	}

	// 2. 检查 hostPID
	if pod.Spec.HostPID {
		allowed = false
		messages = append(messages, "hostPID is not allowed")
	}

	// 3. 检查 hostNetwork
	if pod.Spec.HostNetwork {
		allowed = false
		messages = append(messages, "hostNetwork is not allowed")
	}

	// 4. 检查 hostIPC
	if pod.Spec.HostIPC {
		allowed = false
		messages = append(messages, "hostIPC is not allowed")
	}

	// 5. 检查危险 hostPath
	for _, vol := range pod.Spec.Volumes {
		if vol.HostPath != nil {
			dangerousPaths := []string{"/", "/proc", "/sys", "/var/run/docker.sock", "/etc/kubernetes", "/var/lib/kubelet"}
			for _, dp := range dangerousPaths {
				if vol.HostPath.Path == dp {
					allowed = false
					messages = append(messages, fmt.Sprintf("Dangerous hostPath mount: %s", dp))
				}
			}
		}
	}

	// 6. 检查镜像来源（只允许内部仓库）
	for _, container := range pod.Spec.Containers {
		if !strings.HasPrefix(container.Image, "registry.company.io/") &&
			!strings.HasPrefix(container.Image, "gcr.io/company/") {
			allowed = false
			messages = append(messages, fmt.Sprintf("Container %s uses untrusted image registry", container.Name))
		}
	}

	admissionResponse := &admissionv1.AdmissionResponse{
		UID:     admissionReview.Request.UID,
		Allowed: allowed,
	}
	if !allowed {
		msg := strings.Join(messages, "; ")
		admissionResponse.Result = &metav1.Status{
			Code:    403,
			Message: msg,
			Reason:  metav1.StatusReasonForbidden,
		}
	}

	sendResponse(w, admissionReview, admissionResponse)
}

func parseAdmissionReview(r *http.Request) (*admissionv1.AdmissionReview, error) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err
	}

	var admissionReview admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &admissionReview); err != nil {
		return nil, err
	}

	return &admissionReview, nil
}

func sendResponse(w http.ResponseWriter, review *admissionv1.AdmissionReview, response *admissionv1.AdmissionResponse) {
	review.Response = response
	review.Request = nil

	respBytes, err := json.Marshal(review)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func sendAllowResponse(w http.ResponseWriter, review *admissionv1.AdmissionReview) {
	response := &admissionv1.AdmissionResponse{
		UID:     review.Request.UID,
		Allowed: true,
	}
	sendResponse(w, review, response)
}

func isSystemNamespace(ns string) bool {
	systemNamespaces := []string{"kube-system", "kube-public", "kube-node-lease", "webhook-system"}
	for _, s := range systemNamespaces {
		if ns == s {
			return true
		}
	}
	return false
}
```

**go.mod**：

```
module my-webhook

go 1.21

require (
	k8s.io/api v0.28.0
	k8s.io/apimachinery v0.28.0
	k8s.io/utils v0.0.0-20230726121419-3b25d923346b
)
```

### 16.2.3 Dockerfile（多阶段构建）

```dockerfile
# 构建阶段
FROM golang:1.21-alpine AS builder
WORKDIR /app

# 安装 CA 证书（用于 HTTPS 调用）
RUN apk add --no-cache ca-certificates git

# 下载依赖
COPY go.mod go.sum ./
RUN go mod download

# 构建
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o webhook main.go

# 运行阶段
FROM gcr.io/distroless/static-debian12:nonroot

# 复制 CA 证书
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# 复制二进制文件
COPY --from=builder /app/webhook /webhook

# 使用非 root 用户运行
USER nonroot:nonroot

EXPOSE 8443

ENTRYPOINT ["/webhook"]
```

### 16.2.4 Makefile

```makefile
.PHONY: build docker deploy test clean

IMAGE ?= myregistry/webhook:v1.0.0
NAMESPACE ?= webhook-system

build:
	go build -o bin/webhook main.go

test:
	go test -v ./...

docker:
	docker build -t $(IMAGE) .
	kind load docker-image $(IMAGE) || true

deploy:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f deploy/

undeploy:
	kubectl delete -f deploy/ --ignore-not-found=true

clean:
	rm -rf bin/
```

---

## 16.3 证书管理

### 16.3.1 使用 cert-manager 自动管理证书

```bash
# 安装 cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# 等待 cert-manager 就绪
kubectl wait --for=condition=ready pod -l app=cert-manager -n cert-manager
```

```yaml
# 1. 创建自签名 CA Issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}

---
# 2. 创建 CA 证书
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webhook-ca
  namespace: webhook-system
spec:
  isCA: true
  commonName: webhook-ca
  secretName: webhook-ca-secret
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer

---
# 3. 创建 CA Issuer（命名空间级别）
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: webhook-ca-issuer
  namespace: webhook-system
spec:
  ca:
    secretName: webhook-ca-secret

---
# 4. 为 Webhook 服务签发证书
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webhook-tls
  namespace: webhook-system
spec:
  secretName: webhook-tls-secret
  duration: 2160h  # 90 天
  renewBefore: 360h  # 15 天前自动续期
  subject:
    organizations:
    - my-company
  isCA: false
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 2048
  usages:
  - server auth
  - client auth
  dnsNames:
  - webhook-service
  - webhook-service.webhook-system
  - webhook-service.webhook-system.svc
  - webhook-service.webhook-system.svc.cluster.local
  issuerRef:
    name: webhook-ca-issuer
    kind: Issuer
```

### 16.3.2 自动注入 CA Bundle

```yaml
# 使用 cert-manager 的 ca-injector 自动注入 CA
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: security-mutator
  annotations:
    cert-manager.io/inject-ca-from: webhook-system/webhook-tls
webhooks:
- name: security-mutator.webhook-system.svc
  # ... 其他配置

---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: security-validator
  annotations:
    cert-manager.io/inject-ca-from: webhook-system/webhook-tls
webhooks:
- name: security-validator.webhook-system.svc
  # ... 其他配置
```

### 16.3.3 手动生成证书（测试用）

```bash
#!/bin/bash
# generate-certs.sh

WEBHOOK_NAME="webhook-service"
WEBHOOK_NAMESPACE="webhook-system"

# 生成 CA 私钥
openssl genrsa -out ca.key 2048

# 生成 CA 证书
openssl req -x509 -new -nodes -key ca.key -subj "/CN=${WEBHOOK_NAME}" -days 365 -out ca.crt

# 生成服务器私钥
openssl genrsa -out server.key 2048

# 创建 CSR 配置文件
cat > csr.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${WEBHOOK_NAME}
DNS.2 = ${WEBHOOK_NAME}.${WEBHOOK_NAMESPACE}
DNS.3 = ${WEBHOOK_NAME}.${WEBHOOK_NAMESPACE}.svc
DNS.4 = ${WEBHOOK_NAME}.${WEBHOOK_NAMESPACE}.svc.cluster.local
EOF

# 生成 CSR
openssl req -new -key server.key -out server.csr -config csr.conf

# 使用 CA 签名
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 \
  -extensions v3_req -extfile csr.conf

# 创建 Secret
kubectl create secret tls webhook-tls-secret \
  --cert=server.crt --key=server.key \
  -n ${WEBHOOK_NAMESPACE} --dry-run=client -o yaml > deploy/tls-secret.yaml

# 输出 CA Bundle（用于 WebhookConfiguration）
echo "CA Bundle (base64):"
cat ca.crt | base64

# 清理
rm -f ca.key ca.srl server.csr csr.conf
```

---

## 16.4 部署配置

### 16.4.1 完整部署清单

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: webhook-system
  labels:
    pod-security.kubernetes.io/enforce: restricted

---
# rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webhook-sa
  namespace: webhook-system

---
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-server
  namespace: webhook-system
  labels:
    app: webhook-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webhook-server
  template:
    metadata:
      labels:
        app: webhook-server
    spec:
      serviceAccountName: webhook-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values: ["webhook-server"]
              topologyKey: kubernetes.io/hostname
      containers:
      - name: webhook
        image: myregistry/webhook:v1.0.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8443
          protocol: TCP
          name: https
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/webhook/certs
          readOnly: true
        resources:
          limits:
            memory: "128Mi"
            cpu: "500m"
          requests:
            memory: "64Mi"
            cpu: "100m"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8443
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8443
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
      volumes:
      - name: tls-certs
        secret:
          secretName: webhook-tls-secret

---
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: webhook-service
  namespace: webhook-system
  labels:
    app: webhook-server
spec:
  selector:
    app: webhook-server
  ports:
  - port: 443
    targetPort: 8443
    protocol: TCP
  type: ClusterIP

---
# webhook-config.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: security-mutator
  annotations:
    cert-manager.io/inject-ca-from: webhook-system/webhook-tls
webhooks:
- name: security-mutator.webhook-system.svc
  namespaceSelector:
    matchExpressions:
    - key: security-webhook
      operator: NotIn
      values: ["disabled"]
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
    scope: "Namespaced"
  clientConfig:
    service:
      namespace: webhook-system
      name: webhook-service
      path: "/mutate"
      port: 443
  admissionReviewVersions: ["v1"]
  sideEffects: None
  timeoutSeconds: 5
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded

---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: security-validator
  annotations:
    cert-manager.io/inject-ca-from: webhook-system/webhook-tls
webhooks:
- name: security-validator.webhook-system.svc
  namespaceSelector:
    matchExpressions:
    - key: security-webhook
      operator: NotIn
      values: ["disabled"]
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
    scope: "Namespaced"
  clientConfig:
    service:
      namespace: webhook-system
      name: webhook-service
      path: "/validate"
      port: 443
  admissionReviewVersions: ["v1"]
  sideEffects: None
  timeoutSeconds: 5
  failurePolicy: Fail
```

---

## 16.5 高级技巧

### 16.5.1 排除特定命名空间

```go
// 在 handler 中排除系统命名空间
var ignoredNamespaces = []string{
	"kube-system",
	"kube-public",
	"kube-node-lease",
	"cert-manager",
	"webhook-system",
}

func shouldIgnoreNamespace(ns string) bool {
	for _, ignored := range ignoredNamespaces {
		if ns == ignored {
			return true
		}
	}
	return false
}
```

### 16.5.2 优雅关闭

```go
func main() {
	srv := &http.Server{Addr: ":8443", Handler: mux}

	go func() {
		if err := srv.ListenAndServeTLS(certFile, keyFile); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("Forced shutdown: %v", err)
	}
}
```

### 16.5.3 性能优化

```go
// 使用对象池减少 GC 压力
var patchPool = sync.Pool{
	New: func() interface{} {
		return make([]patchOperation, 0, 10)
	},
}

func mutateHandler(w http.ResponseWriter, r *http.Request) {
	patches := patchPool.Get().([]patchOperation)
	defer patchPool.Put(patches[:0])
	// ...
}

// 预编译正则表达式
var imageRegistryRegex = regexp.MustCompile(`^(registry\.company\.io|gcr\.io/company)/`)

// 使用 fastjson 替代 encoding/json（高性能场景）
```

### 16.5.4 Dry Run 支持

```go
// 检查是否是 Dry Run 请求
func isDryRun(req *admissionv1.AdmissionRequest) bool {
	for _, opt := range req.DryRun {
		if opt {
			return true
		}
	}
	return false
}

// 在 handler 中处理 Dry Run
func mutateHandler(w http.ResponseWriter, r *http.Request) {
	// ...
	if admissionReview.Request.DryRun != nil && *admissionReview.Request.DryRun {
		// Dry Run 模式下不产生副作用
		// 但 Mutation Patch 仍然可以返回
		log.Println("Processing dry-run request")
	}
	// ...
}
```

---

## 16.6 测试策略

### 16.6.1 单元测试

```go
// handler_test.go
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/pointer"
)

func TestMutateHandler(t *testing.T) {
	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pod",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "nginx", Image: "nginx:alpine"},
			},
		},
	}

	podBytes, _ := json.Marshal(pod)
	review := admissionv1.AdmissionReview{
		Request: &admissionv1.AdmissionRequest{
			UID: "test-uid",
			Kind: metav1.GroupVersionKind{
				Group:   "",
				Version: "v1",
				Kind:    "Pod",
			},
			Object: runtime.RawExtension{Raw: podBytes},
		},
	}

	body, _ := json.Marshal(review)
	req := httptest.NewRequest("POST", "/mutate", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	mutateHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("Expected status 200, got %d", rr.Code)
	}

	var response admissionv1.AdmissionReview
	json.Unmarshal(rr.Body.Bytes(), &response)

	if !response.Response.Allowed {
		t.Fatal("Expected allowed = true")
	}

	if response.Response.Patch == nil {
		t.Fatal("Expected patch to be present")
	}
}

func TestValidateHandlerRejectPrivileged(t *testing.T) {
	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "bad-pod",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name:  "nginx",
					Image: "nginx",
					SecurityContext: &corev1.SecurityContext{
						Privileged: pointer.Bool(true),
					},
				},
			},
		},
	}

	podBytes, _ := json.Marshal(pod)
	review := admissionv1.AdmissionReview{
		Request: &admissionv1.AdmissionRequest{
			UID:    "test-uid",
			Object: runtime.RawExtension{Raw: podBytes},
		},
	}

	body, _ := json.Marshal(review)
	req := httptest.NewRequest("POST", "/validate", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	validateHandler(rr, req)

	var response admissionv1.AdmissionReview
	json.Unmarshal(rr.Body.Bytes(), &response)

	if response.Response.Allowed {
		t.Fatal("Expected allowed = false for privileged pod")
	}
}
```

### 16.6.2 集成测试

```bash
#!/bin/bash
# integration-test.sh

set -e

# 1. 部署 Webhook
kubectl apply -f deploy/

# 2. 等待就绪
kubectl wait --for=condition=ready pod -l app=webhook-server -n webhook-system --timeout=60s

# 3. 测试 Mutating Webhook（安全上下文注入）
echo "=== Test 1: Mutating Webhook ==="
kubectl run test-mutate --image=nginx:alpine --restart=Never
kubectl get pod test-mutate -o jsonpath='{.spec.securityContext.runAsNonRoot}'
# 应输出: true
kubectl delete pod test-mutate --force

# 4. 测试 Validating Webhook（拒绝特权容器）
echo "=== Test 2: Validating Webhook - Reject Privileged ==="
if kubectl run test-reject --image=nginx --privileged --restart=Never 2>/dev/null; then
    echo "FAIL: Should have rejected privileged pod"
    exit 1
else
    echo "PASS: Correctly rejected privileged pod"
fi

# 5. 测试 Validating Webhook（允许合规容器）
echo "=== Test 3: Validating Webhook - Allow Compliant ==="
kubectl run test-allow --image=nginx:alpine --restart=Never
kubectl delete pod test-allow --force

echo "=== All tests passed ==="
```

---

## 16.7 调试技巧

### 16.7.1 常见问题排查

```bash
# 1. 查看 Webhook 是否已注册
kubectl get mutatingwebhookconfiguration
kubectl get validatingwebhookconfiguration
kubectl describe mutatingwebhookconfiguration security-mutator

# 2. 查看 API Server 日志（找 Webhook 调用记录）
kubectl logs -n kube-system -l component=kube-apiserver | grep webhook

# 3. 查看 Webhook Pod 日志
kubectl logs -n webhook-system -l app=webhook-server -f

# 4. 检查证书是否有效
kubectl get certificate -n webhook-system
kubectl describe certificate webhook-tls -n webhook-system

# 5. 检查 CA Bundle 是否正确注入
kubectl get mutatingwebhookconfiguration security-mutator -o yaml | grep caBundle

# 6. 测试 Webhook 服务端点
kubectl run curl-test --image=curlimages/curl --rm -it -- \
  -k https://webhook-service.webhook-system.svc:443/healthz

# 7. 手动发送 AdmissionReview 测试
cat << 'EOF' | kubectl run test-webhook --image=curlimages/curl --rm -i -- \
  -k -X POST https://webhook-service.webhook-system.svc:443/mutate \
  -H "Content-Type: application/json" -d @-
{
  "kind": "AdmissionReview",
  "apiVersion": "admission.k8s.io/v1",
  "request": {
    "uid": "test-uid",
    "kind": {"group": "", "version": "v1", "kind": "Pod"},
    "resource": {"group": "", "version": "v1", "resource": "pods"},
    "operation": "CREATE",
    "object": {
      "apiVersion": "v1",
      "kind": "Pod",
      "metadata": {"name": "test", "namespace": "default"},
      "spec": {"containers": [{"name": "nginx", "image": "nginx:alpine"}]}
    }
  }
}
EOF

# 8. 临时禁用 Webhook（紧急排障）
kubectl delete validatingwebhookconfiguration security-validator
kubectl delete mutatingwebhookconfiguration security-mutator
# 恢复时重新 apply
```

### 16.7.2 生产环境最佳实践

| 实践 | 说明 | 配置 |
|------|------|------|
| **高可用** | 多副本 + PodDisruptionBudget | replicas: 2+ |
| **资源限制** | 防止 OOM 或 CPU 饥饿 | memory: 64-128Mi |
| **超时设置** | 避免 API Server 等待过久 | timeoutSeconds: 5 |
| **失败策略** | 初期用 Ignore，稳定后改 Fail | failurePolicy: Ignore → Fail |
| **系统命名空间排除** | 避免影响系统组件 | namespaceSelector |
| **证书自动轮转** | 使用 cert-manager | inject-ca-from |
| **健康检查** | liveness + readiness | /healthz + /readyz |
| **监控** | 请求延迟、错误率 | Prometheus metrics |

---

## 16.8 与现有工具的对比

### 16.8.1 何时使用自定义 Webhook

| 场景 | Kyverno | OPA Gatekeeper | 自定义 Webhook |
|------|---------|---------------|---------------|
| 简单策略（禁止 privileged） | ✅ 最佳 | ✅ 可以 | ❌ 过度设计 |
| 复杂条件判断 | ⚠️ 有限 | ✅ 强大 | ✅ 可以 |
| 调用外部服务验证 | ❌ 不支持 | ❌ 不支持 | ✅ 支持 |
| 与内部系统集成 | ❌ 不支持 | ❌ 不支持 | ✅ 支持 |
| 复杂 Mutation 逻辑 | ⚠️ 有限 | ❌ 不支持 | ✅ 支持 |
| 快速迭代开发 | ✅ 快 | ⚠️ 中等 | ❌ 慢 |
| 维护成本 | ✅ 低 | ✅ 低 | ❌ 高 |

**建议**：先用 Kyverno/OPA，当需要以下能力时再考虑自定义 Webhook：
- 调用外部 API（如镜像签名验证服务）
- 复杂的业务逻辑（如基于部门标签动态设置配额）
- 与内部 IAM/CMDB 系统集成

---

## 16.9 本章实验

### 实验 16.1：构建并部署 Mutating Webhook（30 分钟）

```bash
# 步骤 1：初始化项目
mkdir my-webhook && cd my-webhook
go mod init my-webhook

# 步骤 2：编写 main.go（参考 16.2.2）
# 步骤 3：编写 Dockerfile（参考 16.2.3）

# 步骤 4：构建镜像
docker build -t my-webhook:v1 .
kind load docker-image my-webhook:v1  # 如果使用 kind

# 步骤 5：生成证书
bash generate-certs.sh

# 步骤 6：部署
kubectl apply -f deploy/

# 步骤 7：测试
kubectl run test-mutate --image=nginx:alpine --restart=Never
kubectl get pod test-mutate -o yaml | grep -A 20 securityContext
# 应看到自动注入的 runAsNonRoot、readOnlyRootFilesystem 等
```

### 实验 16.2：构建 Validating Webhook 阻止特权容器（20 分钟）

```bash
# 步骤 1：在代码中实现 validateHandler（参考 16.2.2）

# 步骤 2：构建并部署
make docker deploy

# 步骤 3：测试拒绝
kubectl run bad --image=nginx --privileged --restart=Never
# 预期：Error from server: admission webhook denied

# 步骤 4：测试允许
kubectl run good --image=nginx:alpine --restart=Never
# 预期：Pod 创建成功

# 步骤 5：清理
kubectl delete pod bad good --force --grace-period=0 2>/dev/null || true
```

### 实验 16.3：使用 cert-manager 自动轮转证书（25 分钟）

```bash
# 步骤 1：安装 cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app=cert-manager -n cert-manager

# 步骤 2：创建 Issuer 和 Certificate（参考 16.3.1）
kubectl apply -f deploy/cert-manager/

# 步骤 3：配置 Webhook 使用 cert-manager 注入 CA
# 在 webhook-config.yaml 中添加 annotation:
# cert-manager.io/inject-ca-from: webhook-system/webhook-tls

# 步骤 4：验证证书
kubectl get certificate -n webhook-system
kubectl describe certificate webhook-tls -n webhook-system

# 步骤 5：验证 CA Bundle 自动注入
kubectl get mutatingwebhookconfiguration security-mutator -o yaml | grep caBundle
```

---

## 16.10 本章练习题

### 选择题

1. **Mutating Webhook 和 Validating Webhook 的执行顺序是什么？**
   - A. Validating → Mutating → Schema Validation
   - B. Mutating → Schema Validation → Validating
   - C. Schema Validation → Mutating → Validating
   - D. 同时执行

2. **Webhook 的 `failurePolicy: Fail` 意味着什么？**
   - A. Webhook 失败时忽略错误
   - B. Webhook 失败时阻断请求
   - C. Webhook 总是返回失败
   - D. 请求失败时重试

3. **为什么建议使用 cert-manager 管理 Webhook 证书？**
   - A. 减少代码复杂度
   - B. 自动签发和轮转证书
   - C. 提高 Webhook 性能
   - D. 降低部署成本

4. **`reinvocationPolicy: IfNeeded` 的作用是什么？**
   - A. Webhook 失败后自动重试
   - B. Mutation 后允许其他 Webhook 再次处理
   - C. 定期重新调用 Webhook
   - D. 只在需要时调用 Webhook

### 简答题

1. 描述 K8s 准入控制的完整链路。Mutating 和 Validating Webhook 各自的作用是什么？

2. 为什么自定义 Webhook 需要 TLS 证书？API Server 如何验证 Webhook 的身份？

3. 对比 Kyverno、OPA Gatekeeper 和自定义 Webhook。各自的优缺点和适用场景是什么？

4. 设计一个生产级 Webhook 的高可用方案。需要考虑哪些因素？

### 实践题

1. **完整 Webhook 开发**（1 小时）：
   - 开发一个 Mutating Webhook，自动为 Pod 注入 SecurityContext
   - 开发一个 Validating Webhook，阻止特权容器和危险 hostPath
   - 使用 cert-manager 管理证书
   - 编写单元测试和集成测试
   - 部署到测试集群并验证

2. **Webhook 性能测试**（30 分钟）：
   - 使用 Apache Bench 或 hey 测试 Webhook 响应时间
   - 分析在高并发下的表现
   - 优化代码性能（对象池、缓存等）

3. **故障排查演练**（20 分钟）：
   - 故意配置错误的证书，观察 API Server 行为
   - 使用 kubectl 排查 Webhook 注册和调用问题
   - 临时禁用 Webhook 并恢复

---

## 16.12 Webhook 最佳实践清单

### 16.12.1 生产环境部署 Checklist

```
□ 高可用部署
  □ 至少 2 个副本，分布在不同节点
  □ 配置 PodDisruptionBudget
  □ 使用反亲和性避免单节点故障

□ 证书管理
  □ 使用 cert-manager 自动签发
  □ 配置证书自动轮转
  □ 证书过期前告警

□ 性能保障
  □ 设置合理的 timeoutSeconds (5-10s)
  □ 实现请求超时和重试
  □ 使用对象池减少 GC 压力
  □ 配置水平自动扩缩容 (HPA)

□ 安全加固
  □ Webhook 服务使用 HTTPS
  □ 配置 TLS 1.2+
  □ 限制 Webhook 可访问的源 IP
  □ Webhook 使用最小权限 ServiceAccount

□ 可观测性
  □ 暴露 Prometheus 指标
  □ 记录所有请求和响应日志
  □ 配置延迟和错误率告警
  □ 设置 SLO (可用性 > 99.9%)

□ 故障恢复
  □ 实现优雅关闭
  □ 配置 failurePolicy: Fail/Ignore 策略
  □ 测试 Webhook 不可用时的集群行为
  □ 准备紧急禁用 Webhook 的方案
```

### 16.12.2 常见错误与规避

| 错误 | 后果 | 规避方法 |
|------|------|----------|
| Webhook 修改自身 Deployment | 死锁 | 配置 namespaceSelector 排除自身 |
| 无 timeout 配置 | API Server 阻塞 | 始终设置 timeoutSeconds |
| 单副本部署 | 升级时服务中断 | 至少 2 副本 + PDB |
| 忽略 DryRun 请求 | 影响 kubectl diff | 正确处理 dryRun 字段 |
| 证书过期未续期 | 所有请求失败 | cert-manager + 过期告警 |

---

## 16.11 本章小结

| 主题 | 要点 |
|------|------|
| **Webhook 类型** | Mutating（修改资源）+ Validating（验证资源） |
| **执行顺序** | Mutating → Schema Validation → Validating |
| **开发语言** | Go（client-go + admission API） |
| **证书管理** | cert-manager 自动签发和轮转 |
| **部署模式** | Deployment（2+ 副本）+ Service + WebhookConfiguration |
| **高可用** | 多副本 + PDB + 优雅关闭 + 超时配置 |
| **测试** | 单元测试 + 集成测试 + 手动 curl 测试 |
| **调试** | API Server 日志、Webhook 日志、临时禁用 |

**核心原则**：
1. **可靠性优先**：Webhook 故障会阻断集群操作，必须高可用
2. **渐进部署**：先用 `failurePolicy: Ignore` 验证稳定性
3. **系统命名空间排除**：避免影响 K8s 核心组件
4. **证书自动化**：使用 cert-manager 避免手动管理
5. **监控告警**：监控 Webhook 延迟和错误率

**推荐阅读**：
- K8s Admission Controllers：https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Dynamic Admission Control：https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- cert-manager 文档：https://cert-manager.io/docs/

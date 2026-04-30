#!/bin/bash
# JVM 性能实验 - 环境部署脚本
# 部署两组应用: 健康基线 (App A) 和问题应用 (App B)
# 用于 platform-engineering-lab 项目 4

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "  JVM 性能实验 - 环境部署"
echo "  预计时间: 3-5 分钟"
echo "=============================================="
echo ""

# 检查前置条件
check_prerequisites() {
  echo "=== 检查前置条件 ==="
  local missing=()
  
  for cmd in docker kind kubectl; do
    if command -v "$cmd" &> /dev/null; then
      echo "  ✓ $cmd"
    else
      echo "  ✗ $cmd 未安装"
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "错误: 以下必需工具未安装: ${missing[*]}"
    exit 1
  fi
  
  echo ""
}

# 创建 Kind 集群
create_cluster() {
  echo "=== 创建 Kind 集群 ==="
  if kind get clusters | grep -q "^jvm-lab$"; then
    echo "集群 jvm-lab 已存在，跳过创建"
    return
  fi
  
  cat > /tmp/kind-jvm.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: jvm-lab
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
  - containerPort: 30081
    hostPort: 8081
    protocol: TCP
EOF

  kind create cluster --config /tmp/kind-jvm.yaml
  echo "  ✓ 集群创建完成"
  echo ""
}

# 构建应用镜像
build_images() {
  echo "=== 构建应用镜像 ==="
  
  # 检查镜像是否已存在
  if docker image inspect jvm-lab:app-a 2>/dev/null | grep -q "jvm-lab"; then
    echo "镜像已存在，跳过构建"
    return
  fi
  
  # 创建临时目录构建
  mkdir -p /tmp/jvm-lab-build
  
  # 构建 App A - 健康基线（使用 G1GC，有内存限制感知）
  echo "  构建 App A（健康基线 - G1GC）..."
  cat > /tmp/jvm-lab-build/Dockerfile.a <<'EOF'
FROM openjdk:17-jdk-slim
WORKDIR /app
COPY App.java .
RUN javac App.java
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Xlog:gc*:file=/tmp/gc.log"
EXPOSE 8080
CMD java $JAVA_OPTS -cp /app App
EOF
  
  cat > /tmp/jvm-lab-build/App.java <<'EOF'
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;

public class App {
    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/api/health", new HealthHandler());
        server.createContext("/api/process", new ProcessHandler());
        server.createContext("/api/memory", new MemoryHandler());
        server.setExecutor(Executors.newFixedThreadPool(50));
        server.start();
        System.out.println("Server started on port 8080");
    }
    
    static class HealthHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            String response = "{\"status\":\"ok\",\"app\":\"app-a\"}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
    
    static class ProcessHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            long start = System.currentTimeMillis();
            for (int i = 0; i < 1000; i++) {
                Math.sqrt(i);
            }
            long elapsed = System.currentTimeMillis() - start;
            String response = "{\"elapsed_ms\":" + elapsed + "}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
    
    static class MemoryHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            Runtime rt = Runtime.getRuntime();
            long used = (rt.totalMemory() - rt.freeMemory()) / 1024 / 1024;
            long total = rt.totalMemory() / 1024 / 1024;
            String response = "{\"used_mb\":" + used + ",\"total_mb\":" + total + "}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
}
EOF
  
  docker build -t jvm-lab:app-a -f /tmp/jvm-lab-build/Dockerfile.a /tmp/jvm-lab-build
  kind load docker-image jvm-lab:app-a --name jvm-lab
  
  # 构建 App B - 问题应用（使用 ParallelGC，无容器感知，可能的死锁）
  echo "  构建 App B（问题应用 - ParallelGC + 死锁隐患）..."
  cat > /tmp/jvm-lab-build/Dockerfile.b <<'EOF'
FROM openjdk:17-jdk-slim
WORKDIR /app
COPY AppB.java .
RUN javac AppB.java
ENV JAVA_OPTS="-XX:+UseParallelGC -Xmx512m -Xms512m -Xlog:gc*:file=/tmp/gc.log"
EXPOSE 8080
CMD java $JAVA_OPTS -cp /app AppB
EOF
  
  cat > /tmp/jvm-lab-build/AppB.java <<'EOF'
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;
import java.util.*;

public class AppB {
    static final Object lock1 = new Object();
    static final Object lock2 = new Object();
    static List<byte[]> leakList = new ArrayList<>();
    
    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/api/health", new HealthHandler());
        server.createContext("/api/process", new ProcessHandler());
        server.createContext("/api/memory", new MemoryHandler());
        server.createContext("/api/deadlock", new DeadlockHandler());
        server.createContext("/api/leak", new LeakHandler());
        server.setExecutor(Executors.newFixedThreadPool(50));
        server.start();
        System.out.println("Server started on port 8080");
    }
    
    static class HealthHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            String response = "{\"status\":\"ok\",\"app\":\"app-b\"}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
    
    static class ProcessHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            long start = System.currentTimeMillis();
            for (int i = 0; i < 1000; i++) {
                Math.sqrt(i);
            }
            long elapsed = System.currentTimeMillis() - start;
            String response = "{\"elapsed_ms\":" + elapsed + "}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
    
    static class MemoryHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            Runtime rt = Runtime.getRuntime();
            long used = (rt.totalMemory() - rt.freeMemory()) / 1024 / 1024;
            long total = rt.totalMemory() / 1024 / 1024;
            String response = "{\"used_mb\":" + used + ",\"total_mb\":" + total + "}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
    
    static class DeadlockHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            new Thread(() -> {
                synchronized(lock1) {
                    try { Thread.sleep(100); } catch (Exception e) {}
                    synchronized(lock2) {}
                }
            }).start();
            new Thread(() -> {
                synchronized(lock2) {
                    try { Thread.sleep(100); } catch (Exception e) {}
                    synchronized(lock1) {}
                }
            }).start();
            String response = "{\"status\":\"deadlock triggered\"}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
    
    static class LeakHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            leakList.add(new byte[1024 * 1024]); // 每次泄漏 1MB
            String response = "{\"leaked_mb\":" + leakList.size() + "}";
            exchange.sendResponseHeaders(200, response.length());
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }
}
EOF
  
  docker build -t jvm-lab:app-b -f /tmp/jvm-lab-build/Dockerfile.b /tmp/jvm-lab-build
  kind load docker-image jvm-lab:app-b --name jvm-lab
  
  echo "  ✓ 镜像构建完成"
  echo ""
}

# 部署应用到 K8s
deploy_apps() {
  echo "=== 部署应用到 K8s ==="
  
  kubectl create namespace jvm-lab --dry-run=client -o yaml | kubectl apply -f -
  
  # 部署 App A
  echo "  部署 App A（健康基线）..."
  cat > /tmp/app-a.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-a
  namespace: jvm-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-a
  template:
    metadata:
      labels:
        app: app-a
    spec:
      containers:
      - name: app
        image: jvm-lab:app-a
        ports:
        - containerPort: 8080
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
          requests:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: app-a
  namespace: jvm-lab
spec:
  selector:
    app: app-a
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
  type: NodePort
EOF
  kubectl apply -f /tmp/app-a.yaml
  
  # 部署 App B
  echo "  部署 App B（问题应用）..."
  cat > /tmp/app-b.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-b
  namespace: jvm-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-b
  template:
    metadata:
      labels:
        app: app-b
    spec:
      containers:
      - name: app
        image: jvm-lab:app-b
        ports:
        - containerPort: 8080
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
          requests:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: app-b
  namespace: jvm-lab
spec:
  selector:
    app: app-b
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30081
  type: NodePort
EOF
  kubectl apply -f /tmp/app-b.yaml
  
  echo "  等待应用就绪..."
  kubectl wait --for=condition=ready pod -l app=app-a -n jvm-lab --timeout=120s
  kubectl wait --for=condition=ready pod -l app=app-b -n jvm-lab --timeout=120s
  
  echo "  ✓ 应用部署完成"
  echo ""
}

# 验证部署
verify() {
  echo "=============================================="
  echo "  验证部署"
  echo "=============================================="
  echo ""
  echo "Pod 状态:"
  kubectl get pods -n jvm-lab -o wide
  echo ""
  echo "服务:"
  kubectl get svc -n jvm-lab
  echo ""
  echo "=============================================="
  echo "  JVM 实验环境部署完成"
  echo ""
  echo "  访问地址:"
  echo "    App A（健康基线）: http://localhost:8080/api/health"
  echo "    App B（问题应用）: http://localhost:8081/api/health"
  echo ""
  echo "  实验接口:"
  echo "    /api/health    - 健康检查"
  echo "    /api/process   - CPU 密集型操作"
  echo "    /api/memory    - 内存使用"
  echo "    /api/deadlock  - 触发死锁（App B）"
  echo "    /api/leak      - 内存泄漏（App B）"
  echo ""
  echo "  下一步:"
  echo "    1. ./diagnose-jvm.sh app-a    # 诊断健康基线"
  echo "    2. ./diagnose-jvm.sh app-b    # 诊断问题应用"
  echo "    3. 对比差异，找出根因"
  echo "=============================================="
}

# 主流程
main() {
  check_prerequisites
  create_cluster
  build_images
  deploy_apps
  verify
}

main "$@"

#!/bin/bash
# 监控体系压测脚本
# 生成持续流量用于验证监控数据采集

set -e

TARGET_URL=${1:-"http://localhost:8080"}
DURATION=${2:-"300"}  # 默认 5 分钟
CONCURRENCY=${3:-"50"}

echo "=========================================="
echo "  监控压测脚本"
echo "=========================================="
echo "目标: $TARGET_URL"
echo "持续时间: ${DURATION}秒"
echo "并发数: $CONCURRENCY"
echo ""

# 检查 wrk 或 hey
if command -v wrk &> /dev/null; then
    echo "使用 wrk 压测..."
    wrk -t4 -c$CONCURRENCY -d${DURATION}s $TARGET_URL
elif command -v hey &> /dev/null; then
    echo "使用 hey 压测..."
    hey -z ${DURATION}s -c $CONCURRENCY $TARGET_URL
elif command -v ab &> /dev/null; then
    echo "使用 ab 压测..."
    ab -n 100000 -c $CONCURRENCY -t $DURATION $TARGET_URL/
else
    echo "未找到压测工具，使用 curl 模拟..."
    for i in $(seq 1 $DURATION); do
        for j in $(seq 1 $CONCURRENCY); do
            curl -s $TARGET_URL > /dev/null &
        done
        sleep 1
        echo -n "."
    done
    echo ""
fi

echo ""
echo "压测完成！"
echo "请在 Grafana 中查看指标变化"

# 08. RAG与向量数据库：构建Agent记忆系统

> **目标读者**：希望为Agent构建外部知识系统的开发工程师  
> **核心目标**：掌握RAG全流程、向量数据库选型、知识图谱集成与记忆优化策略

---

## 目录

### 第1章 Agent的记忆层次（已详细编写）
1.1 工作记忆 vs 长期记忆  
1.2 语义记忆 vs 情景记忆  
1.3 记忆在Agent系统中的位置

### 第2章 Embedding与语义表示（已详细编写）
2.1 从文本到向量：Embedding原理  
2.2 主流Embedding模型对比  
2.3 向量维度与质量权衡  
2.4 多语言与跨模态Embedding

### 第3章 向量数据库选型与使用（已详细编写）
3.1 向量数据库核心能力  
3.2 Pinecone / Weaviate / Milvus / Chroma 对比  
3.3 索引算法：HNSW、IVF、Flat  
3.4 向量检索的相似度度量  
3.5 实战：Chroma本地快速入门

### 第4章 RAG完整流水线
4.1 文档加载与解析  
4.2 文本分块策略  
4.3 Embedding生成与存储  
4.4 检索策略：相似度、MMR、混合搜索  
4.5 重排序与结果优化  
4.6 生成增强与引用溯源

### 第5章 高级RAG技术
5.1 查询重写与扩展  
5.2 假设性文档嵌入（HyDE）  
5.3 上下文压缩  
5.4 多跳检索与迭代RAG

### 第6章 知识图谱与结构化记忆
6.1 知识图谱基础  
6.2 从文本自动构建知识图谱  
6.3 图数据库集成：Neo4j  
6.4 向量+图谱混合检索

### 第7章 Agent记忆系统实战
7.1 长对话记忆管理  
7.2 实体记忆提取与更新  
7.3 记忆压缩与摘要  
7.4 完整案例：客服Agent的记忆系统

---

## 第1章 Agent的记忆层次

### 1.1 工作记忆 vs 长期记忆

```
Agent记忆层次架构：

┌─────────────────────────────────────────────────────────────┐
│                        工作记忆 (Working Memory)              │
│   ┌──────────────────────────────────────────────────────┐  │
│   │  当前对话上下文（System + 最近N轮消息）               │  │
│   │  容量：模型上下文窗口（4K-1M tokens）                 │  │
│   │  特点：高速访问，断电丢失，容量有限                   │  │
│   └──────────────────────────────────────────────────────┘  │
│                            │                                │
│                            ▼                                │
│   ┌──────────────────────────────────────────────────────┐  │
│   │              短期缓存 (Short-term Cache)               │  │
│   │  最近处理的文档、工具结果、中间推理                   │  │
│   │  容量：MB级别                                        │  │
│   │  特点：分钟-小时级存活                               │  │
│   └──────────────────────────────────────────────────────┘  │
│                            │                                │
│                            ▼                                │
│   ┌──────────────────────────────────────────────────────┐  │
│   │              长期记忆 (Long-term Memory)               │  │
│   │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │  │
│   │  │ 向量记忆   │  │ 知识图谱   │  │ 结构化存储 │     │  │
│   │  │ (语义检索) │  │ (关系推理) │  │ (键值查询) │     │  │
│   │  └────────────┘  └────────────┘  └────────────┘     │  │
│   │  容量：GB-TB级别                                    │  │
│   │  特点：持久化，按需检索，近乎无限                    │  │
│   └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 语义记忆 vs 情景记忆

| 记忆类型 | 存储内容 | 检索方式 | 示例 |
|----------|----------|----------|------|
| **语义记忆** | 概念、事实、知识 | 语义相似度检索 | "退货政策是什么" → 检索相关政策文档 |
| **情景记忆** | 具体事件、对话历史 | 时间/ID索引 | "用户上周问过的问题" |
| **程序记忆** | 如何做事的技能 | 模式匹配 | "处理退款的标准流程" |

```python
from dataclasses import dataclass
from datetime import datetime
from typing import Literal

@dataclass
class Memory:
    id: str
    content: str
    memory_type: Literal["semantic", "episodic", "procedural"]
    embedding: list[float] | None = None
    metadata: dict = None
    created_at: datetime = None
    
    def __post_init__(self):
        if self.metadata is None:
            self.metadata = {}
        if self.created_at is None:
            self.created_at = datetime.now()

# 语义记忆：知识事实
semantic_memory = Memory(
    id="policy_001",
    content="退货政策：自签收日起7天内可无理由退货，需保持商品完好。",
    memory_type="semantic",
    metadata={"category": "policy", "department": "customer_service"}
)

# 情景记忆：具体对话
episodic_memory = Memory(
    id="conv_20240501_001",
    content="用户Alice询问iPhone 15的充电问题，已建议更换充电线。",
    memory_type="episodic",
    metadata={"user_id": "alice", "session_id": "sess_123"}
)
```

### 1.3 记忆在Agent系统中的位置

```
用户输入 ──► [工作记忆：当前对话上下文] ──► LLM推理
                  │                           │
                  ▼                           │
           [RAG检索：相关长期记忆] ◄────────────┘
                  │
                  ▼
           [向量数据库 / 知识图谱]
```

---

## 第2章 Embedding与语义表示

### 2.1 从文本到向量：Embedding原理

Embedding将离散的文本转化为连续的向量空间中的点。语义相似的文本，在向量空间中距离相近。

```
"猫" ──► [0.2, -0.5, 0.8, ...]      维度：768/1024/1536
"狗" ──► [0.3, -0.4, 0.7, ...]      距离("猫", "狗") < 距离("猫", "汽车")
"汽车" ──► [-0.8, 0.2, -0.1, ...]
```

**核心性质：**
- **语义相似性 → 向量接近**：cosine相似度高
- **语义关系 → 向量运算**：King - Man + Woman ≈ Queen
- **可扩展性**：新文本只需通过模型编码即可加入向量空间

### 2.2 主流Embedding模型对比

| 模型 | 维度 | 语言 | 上下文 | 特点 | 适用场景 |
|------|------|------|--------|------|----------|
| OpenAI text-embedding-3-small | 1536 | 多语言 | 8191 | 便宜、通用 | 通用RAG |
| OpenAI text-embedding-3-large | 3072 | 多语言 | 8191 | 高质量 | 精度要求高 |
| BGE-large-zh | 1024 | 中文优化 | 512 | 中文效果优秀 | 中文文档 |
| E5-mistral | 4096 | 多语言 | 32768 | 长文档 | 长文本RAG |
| ColBERT | 可变 | 多语言 | 可变 |  late interaction | 高精度检索 |
| Jina-Embeddings-v2 | 768 | 多语言 | 8192 | 开源、长上下文 | 开源方案 |

```python
from openai import OpenAI

client = OpenAI()

def get_embedding(text: str, model: str = "text-embedding-3-small") -> list[float]:
    response = client.embeddings.create(
        model=model,
        input=text,
        dimensions=512  # 可选：降维以节省存储
    )
    return response.data[0].embedding

# 测试语义相似度
import numpy as np

vec1 = get_embedding("如何退货")
vec2 = get_embedding("退款流程是什么")
vec3 = get_embedding("今天天气很好")

def cosine_similarity(a, b):
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))

print(cosine_similarity(vec1, vec2))  # 高，如 0.85
print(cosine_similarity(vec1, vec3))  # 低，如 0.25
```

### 2.3 向量维度与质量权衡

```python
# OpenAI Embedding 3 支持动态维度
dimension_comparison = {
    512: {"storage": "低", "quality": "中", "speed": "快", "use_case": "大规模检索"},
    1536: {"storage": "中", "quality": "高", "speed": "中", "use_case": "通用场景"},
    3072: {"storage": "高", "quality": "最高", "speed": "慢", "use_case": "高精度需求"},
}

# 维度对检索的影响
# - 低维度：存储小、检索快，但可能丢失细微语义差异
# - 高维度：保留更多语义信息，但存储和计算成本高
# - 推荐：先用高维度生成，通过PCA或模型自带的降维功能压缩
```

---

## 第3章 向量数据库选型与使用

### 3.1 向量数据库核心能力

```
向量数据库 vs 传统数据库：

传统数据库查询：        向量数据库查询：
SELECT * FROM docs      给定向量：[0.1, -0.3, ...]
WHERE id = 123          找到最接近的K个向量
                        （不是精确匹配，是相似度匹配）
```

**核心操作：**
1. **Add/Insert**：存储向量 + 元数据
2. **Search/Query**：相似度检索（KNN/ANN）
3. **Filter**：元数据过滤 + 向量检索
4. **Update/Delete**：维护向量数据

### 3.2 向量数据库对比

| 特性 | Chroma | Pinecone | Weaviate | Milvus |
|------|--------|----------|----------|--------|
| **部署** | 本地/嵌入式 | 全托管云 | 本地/云 | 本地/云/K8s |
| **易用性** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| **扩展性** | 中等 | 高 | 高 | 很高 |
| **元数据过滤** | 支持 | 强大 | 强大 | 强大 |
| **混合搜索** | 基础 | 支持 | 原生支持 | 支持 |
| **成本** | 免费 | 按量付费 | 开源/付费 | 开源 |
| **适用** | 原型/小项目 | 生产级 | 企业级 | 大规模 |

### 3.3 索引算法

```python
"""
ANN（近似最近邻）算法对比：

Flat（暴力搜索）
├── 准确率：100%
├── 速度：慢（O(N)）
├── 内存：低
└── 适用：数据量 < 1万

IVF（倒排文件）
├── 准确率：~95%
├── 速度：快
├── 内存：中
└── 适用：中等规模

HNSW（分层可导航小世界）
├── 准确率：~99%
├── 速度：很快
├── 内存：高
└── 适用：大规模、高召回要求
"""
```

### 3.4 向量检索的相似度度量

| 度量方法 | 公式 | 特点 | 适用 |
|----------|------|------|------|
| **Cosine Similarity** | $A·B / (\|A\| \|B\|)$ | 忽略向量长度，关注方向 | 文本语义（最常用） |
| **Euclidean Distance** | $\|A-B\|$ | 考虑绝对距离 | 空间数据 |
| **Dot Product** | $A·B$ | 简单高效 | 归一化向量时等价于cosine |

### 3.5 实战：Chroma本地快速入门

```python
import chromadb
from chromadb.config import Settings

# 创建客户端
client = chromadb.Client(Settings(
    chroma_db_impl="duckdb+parquet",
    persist_directory="./chroma_db"
))

# 创建集合（相当于表）
collection = client.create_collection(
    name="agent_knowledge",
    metadata={"description": "Agent知识库"}
)

# 添加文档
documents = [
    "退货政策：7天无理由退货，商品需完好无损。",
    "发货时间：下单后24小时内发货，偏远地区48小时。",
    "会员权益：积分可兑换优惠券，生日双倍积分。",
    "售后服务：提供1年质保，人为损坏除外。",
]

metadatas = [
    {"category": "policy", "topic": "return"},
    {"category": "logistics", "topic": "shipping"},
    {"category": "membership", "topic": "benefits"},
    {"category": "service", "topic": "warranty"},
]

ids = ["doc_001", "doc_002", "doc_003", "doc_004"]

collection.add(
    documents=documents,
    metadatas=metadatas,
    ids=ids
)

# 检索
results = collection.query(
    query_texts=["我想退掉昨天买的衣服"],
    n_results=2,
    where={"category": "policy"}  # 元数据过滤
)

print(results["documents"])  # 最相关的文档
print(results["distances"])  # 距离分数
print(results["metadatas"])  # 元数据

# 带Embedding函数的完整RAG
from chromadb.utils.embedding_functions import OpenAIEmbeddingFunction

embedding_fn = OpenAIEmbeddingFunction(
    api_key="your-key",
    model_name="text-embedding-3-small"
)

collection = client.create_collection(
    name="agent_knowledge_v2",
    embedding_function=embedding_fn
)
```

---

## 第4-7章 内容精要

### 第4章 RAG完整流水线
- **文档加载**：支持PDF、Word、Markdown、网页、数据库
- **文本分块**：固定长度、按段落、递归字符、语义分块
- **分块策略**：块大小500-1000 tokens，重叠10-20%
- **检索策略**：
  - 相似度检索：找最相似的K个块
  - MMR（最大边际相关性）：平衡相关性和多样性
  - 混合搜索：向量相似度 + 关键词BM25
- **重排序**：用Cross-Encoder对初筛结果精排序
- **生成增强**：在Prompt中注入检索到的上下文 + 要求引用来源

### 第5章 高级RAG技术
- **查询重写**：将用户问题改写成更适合检索的形式
- **HyDE**：用LLM生成假设性答案，用答案做检索
- **上下文压缩**：检索到的长文档用LLM压缩为关键信息
- **多跳检索**：复杂问题分多步检索（如"A公司的CEO的妻子是谁"→先查CEO→再查其妻子）

### 第6章 知识图谱与结构化记忆
- **实体-关系-实体**三元组存储结构化知识
- 从文本自动提取实体和关系（LLM + 规则）
- Neo4j存储和Cypher查询
- **混合检索**：向量找语义相关内容 + 图谱做关系推理

### 第7章 Agent记忆系统实战
- **长对话记忆**：滑动窗口 + 摘要 + 向量检索
- **实体记忆**：自动提取用户提到的实体（人、地点、产品），持续追踪
- **记忆压缩**：当记忆过多时，LLM自动总结压缩
- **客服Agent案例**：产品知识库（RAG）+ 用户历史（情景记忆）+ 处理流程（程序记忆）

---

## 本章小结

| 知识点 | Agent开发应用 |
|--------|--------------|
| Embedding | 将文本转化为可计算的语义向量 |
| 向量数据库 | Agent的外部长期记忆存储 |
| RAG流水线 | 让Agent基于最新、最相关的知识回答问题 |
| 混合搜索 | 结合语义和关键词，提升检索召回率 |
| 重排序 | 精排检索结果，提升上下文质量 |
| 知识图谱 | 存储结构化关系，支持推理型查询 |
| 记忆分层 | 工作记忆 + 短期缓存 + 长期记忆协同 |

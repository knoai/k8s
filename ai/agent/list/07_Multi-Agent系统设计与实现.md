# 07. Multi-Agent系统设计与实现

> **目标读者**：已掌握单Agent开发，希望构建多Agent协作系统的工程师  
> **核心目标**：掌握多Agent架构模式、通信协议、协作机制与调度策略

---

## 目录

### 第1章 为什么需要Multi-Agent（已详细编写）
1.1 单Agent的局限性  
1.2 Multi-Agent的核心优势  
1.3 适用场景与不适场景

### 第2章 Multi-Agent架构模式（已详细编写）
2.1 层级架构（Hierarchical）  
2.2 对等网络（Peer-to-Peer）  
2.3 流水线架构（Pipeline/Workflow）  
2.4 市场拍卖架构（Market/Auction）  
2.5 混合架构

### 第3章 Agent角色设计与分工（已详细编写）
3.1 角色定义：Persona与职责边界  
3.2 专业Agent vs 通用Agent  
3.3 角色冲突与冗余避免  
3.4 动态角色分配

### 第4章 通信协议与消息机制
4.1 直接消息 vs 广播 vs 消息总线  
4.2 同步通信 vs 异步通信  
4.3 消息格式与Schema  
4.4 共享记忆与黑板机制

### 第5章 协作模式与任务分配
5.1 序列协作：一个完成传给下一个  
5.2 并行协作：分而治之  
5.3 投票与共识机制  
5.4 辩论与对抗模式

### 第6章 调度与编排
6.1 静态工作流 vs 动态编排  
6.2 任务分解与分配算法  
6.3 死锁检测与避免  
6.4 超时与容错

### 第7章 实战：构建软件开发多Agent团队
7.1 架构设计：PM + 架构师 + 开发者 + 测试员  
7.2 需求分析Agent实现  
7.3 代码生成与审查Agent  
7.4 协作流程编排与评估

---

## 第1章 为什么需要Multi-Agent

### 1.1 单Agent的局限性

```
单Agent的"认知负荷"问题：

用户请求："帮我开发一个电商网站，包含用户系统、商品管理、
          购物车、支付接口、订单管理、物流追踪、后台管理"

单Agent处理：
  ├── 需要同时理解：前端、后端、数据库、支付、物流
  ├── 上下文窗口被各种领域知识挤占
  ├── 难以同时保证所有模块的质量
  └── 容易在复杂任务中"迷失"

Multi-Agent处理：
  ├── PM Agent：理解需求，拆解任务
  ├── 架构师 Agent：设计系统架构、数据库schema
  ├── 前端 Agent：开发React/Vue界面
  ├── 后端 Agent：开发API、业务逻辑
  ├── 数据库 Agent：设计表结构、查询优化
  ├── 支付 Agent：对接支付接口
  └── 测试 Agent：编写测试用例、验收
  
  每个Agent专注自己的领域，通过协作完成整体目标
```

**单Agent的核心限制：**

| 限制 | 表现 | Multi-Agent解决方案 |
|------|------|---------------------|
| 上下文溢出 | 复杂任务需要太多背景知识 | 每个Agent只加载相关上下文 |
| 能力边界 | 一个模型难以精通所有领域 | 不同Agent可配置不同模型/提示 |
| 并行瓶颈 | 串行思考效率低 | 多个Agent并行工作 |
| 单点故障 | 一个错误导致整体失败 | 冗余设计和交叉验证 |
| 可扩展性 | 新增能力需修改核心 | 新增Agent即可扩展 |

### 1.2 Multi-Agent的核心优势

```python
from dataclasses import dataclass
from typing import Callable

@dataclass
class MultiAgentSystem:
    """
    Multi-Agent系统的核心优势：
    
    1. 模块化：每个Agent独立开发、测试、部署
    2. 专业化：每个Agent深度优化特定任务
    3. 并行化：独立任务同时执行
    4. 弹性：单个Agent失败不影响整体（有冗余时）
    5. 可扩展：通过增加Agent扩展能力
    """
    agents: dict[str, "Agent"]
    orchestrator: "Orchestrator"
    communication_bus: "MessageBus"
    shared_memory: "SharedMemory"
```

### 1.3 适用场景与不适场景

**适合Multi-Agent的场景：**
- 软件开发（需求→设计→编码→测试→部署）
- 复杂数据分析（采集→清洗→分析→可视化→报告）
- 内容创作（研究→大纲→写作→编辑→校对）
- 客户服务（路由→查询→处理→跟进）

**不适合Multi-Agent的场景：**
- 简单问答（单Agent更快更便宜）
- 实时性要求极高的任务（通信开销）
- 任务间高度耦合无法分解

---

## 第2章 Multi-Agent架构模式

### 2.1 层级架构（Hierarchical）

```
                    ┌─────────────┐
                    │   Supervisor │  ← 调度、决策、汇总
                    │  (Orchestrator)│
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
    │   Manager   │ │   Manager   │ │   Manager   │
    │  (Module A) │ │  (Module B) │ │  (Module C) │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
      ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
      ▼         ▼     ▼         ▼     ▼         ▼
   Worker    Worker Worker   Worker Worker   Worker
   
特点：
- Supervisor做高层决策，Manager负责模块内协调
- 适合复杂分层任务
- 单点风险在Supervisor
```

```python
class HierarchicalMultiAgent:
    """层级多Agent系统"""
    
    def __init__(self):
        self.supervisor = SupervisorAgent()
        self.managers: dict[str, ManagerAgent] = {}
        self.workers: dict[str, list[WorkerAgent]] = {}
    
    async def execute(self, task: str) -> str:
        # 1. Supervisor分解任务
        subtasks = await self.supervisor.decompose(task)
        
        results = {}
        for subtask in subtasks:
            manager = self.managers[subtask.domain]
            
            # 2. Manager进一步分配
            worker_tasks = await manager.distribute(subtask)
            
            # 3. Workers并行执行
            worker_results = await asyncio.gather(*[
                worker.execute(wt)
                for worker, wt in zip(self.workers[subtask.domain], worker_tasks)
            ])
            
            # 4. Manager汇总
            results[subtask.id] = await manager.aggregate(worker_results)
        
        # 5. Supervisor最终汇总
        return await self.supervisor.synthesize(results)
```

### 2.2 对等网络（Peer-to-Peer）

```
    ┌─────────┐         ┌─────────┐
    │ Agent A │◄───────►│ Agent B │
    │ (Search)│         │(Analysis)│
    └────┬────┘         └────┬────┘
         │                   │
         └─────────┬─────────┘
                   │
            ┌──────▼──────┐
            │   Agent C   │
            │  (Writing)  │
            └─────────────┘

特点：
- 无中心节点，Agent间直接通信
- 适合需要大量协作的场景
- 需要共识机制协调决策
```

```python
class PeerToPeerAgent:
    """对等网络Agent"""
    
    def __init__(self, name: str, peers: list[str]):
        self.name = name
        self.peers = peers
        self.message_queue = asyncio.Queue()
    
    async def send(self, target: str, message: dict):
        """发送消息给指定Agent"""
        await message_bus.send(target, {
            "from": self.name,
            **message
        })
    
    async def broadcast(self, message: dict):
        """广播给所有peer"""
        await asyncio.gather(*[
            self.send(peer, message)
            for peer in self.peers
        ])
    
    async def run(self):
        """主循环：接收消息并处理"""
        while True:
            msg = await self.message_queue.get()
            await self.handle_message(msg)
    
    async def handle_message(self, msg: dict):
        """处理收到的消息"""
        if msg["type"] == "request_collaboration":
            result = await self.process(msg["task"])
            await self.send(msg["from"], {
                "type": "collaboration_result",
                "result": result
            })
```

### 2.3 流水线架构（Pipeline/Workflow）

```
输入 ──► [Agent 1] ──► [Agent 2] ──► [Agent 3] ──► 输出
        (提取信息)    (分析推理)    (生成输出)
        
特点：
- 数据单向流动，像工厂流水线
- 每个Agent专注一个处理阶段
- 易于理解和监控
- 不适合需要循环迭代的任务
```

```python
class PipelineMultiAgent:
    """流水线多Agent系统"""
    
    def __init__(self, stages: list["Agent"]):
        self.stages = stages
    
    async def execute(self, input_data: str) -> str:
        current = input_data
        for i, stage in enumerate(self.stages):
            current = await stage.process(current)
            print(f"Stage {i+1} ({stage.name}): {current[:100]}...")
        return current

# 使用：文章生成流水线
pipeline = PipelineMultiAgent([
    ResearchAgent(),      # 阶段1：研究收集资料
    OutlineAgent(),       # 阶段2：生成大纲
    DraftAgent(),         # 阶段3：撰写初稿
    EditAgent(),          # 阶段4：编辑润色
    FactCheckAgent(),     # 阶段5：事实核查
])
```

### 2.4 混合架构

实际系统通常是多种模式的组合：

```
                    ┌──────────────┐
                    │  Supervisor  │
                    └──────┬───────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
    │  Pipeline   │ │ Peer Group  │ │  Single     │
    │  (Writing)  │ │ (Reviewers) │ │  (Search)   │
    │             │ │             │ │             │
    │ [Research]  │ │  Reviewer A │ │             │
    │     │       │ │     ◄►      │ │             │
    │ [Outline]   │ │  Reviewer B │ │             │
    │     │       │ │             │ │             │
    │ [Draft]     │ │  Reviewer C │ │             │
    │     │       │ │             │ │             │
    │ [Edit]      │ └──────┬──────┘ │             │
    └─────────────┘        │        └─────────────┘
                           │
                    ┌──────▼──────┐
                    │  Synthesis  │
                    └─────────────┘
```

---

## 第3章 Agent角色设计与分工

### 3.1 角色定义：Persona与职责边界

```python
from dataclasses import dataclass, field
from typing import Literal

@dataclass
class AgentRole:
    """
    Agent角色定义模板
    
    每个角色包含：
    - 身份定位（我是谁）
    - 核心职责（我做什么）
    - 能力边界（我不做什么）
    - 协作接口（我和谁协作）
    - 质量标准（什么算做好）
    """
    name: str
    title: str
    description: str
    responsibilities: list[str]
    boundaries: list[str]  # 明确不做的事情
    collaborators: list[str]  # 协作对象
    quality_criteria: list[str]
    model: str = "gpt-4o"
    temperature: float = 0.3

# 软件开发团队角色定义
PRODUCT_MANAGER = AgentRole(
    name="pm",
    title="产品经理",
    description="负责理解用户需求，拆解功能点，制定开发计划",
    responsibilities=[
        "与用户沟通，澄清需求",
        "编写用户故事和验收标准",
        "拆解任务并分配给开发团队",
        "验收最终交付物"
    ],
    boundaries=[
        "不写代码",
        "不做技术架构决策",
        "不直接操作数据库"
    ],
    collaborators=["architect", "frontend_dev", "backend_dev"],
    quality_criteria=[
        "需求描述清晰无歧义",
        "验收标准可测试",
        "任务拆解粒度适中"
    ]
)

ARCHITECT = AgentRole(
    name="architect",
    title="系统架构师",
    description="负责技术选型、系统架构设计、接口定义",
    responsibilities=[
        "设计系统整体架构",
        "定义模块间接口",
        "技术选型（框架、数据库等）",
        "制定开发规范"
    ],
    boundaries=[
        "不编写业务逻辑代码",
        "不做UI设计"
    ],
    collaborators=["pm", "backend_dev", "database_dev"],
    quality_criteria=[
        "架构可扩展",
        "接口定义清晰",
        "技术选型有依据"
    ]
)

CODE_REVIEWER = AgentRole(
    name="code_reviewer",
    title="代码审查员",
    description="审查代码质量、安全性、规范性",
    responsibilities=[
        "检查代码规范性",
        "发现潜在bug",
        "评估性能影响",
        "检查安全漏洞"
    ],
    boundaries=[
        "不直接修改代码",
        "不重新实现功能"
    ],
    collaborators=["frontend_dev", "backend_dev"],
    quality_criteria=[
        "发现所有明显bug",
        "提出可执行的改进建议"
    ]
)
```

### 3.2 专业Agent vs 通用Agent

| 类型 | 特点 | 适用场景 | 示例 |
|------|------|----------|------|
| **专业Agent** | 深度优化单一领域，高精度的工具集 | 核心业务模块 | 支付Agent、风控Agent |
| **通用Agent** | 灵活处理多种任务，广泛的工具集 | 协调、路由、兜底 | SupervisorAgent、客服Agent |
| **混合Agent** | 有专长但可fallback到通用处理 | 大多数实际场景 | 分析Agent（擅长数据但可处理简单请求） |

### 3.3 动态角色分配

```python
class DynamicRoleAssignment:
    """根据任务特征动态分配Agent角色"""
    
    ROLE_PATTERNS = {
        "technical_design": ["architect", "senior_dev"],
        "bug_fix": ["debugger", "tester"],
        "feature_dev": ["pm", "architect", "dev", "tester"],
        "code_review": ["code_reviewer"],
        "performance": ["performance_engineer", "architect"],
    }
    
    def assign(self, task_description: str) -> list[str]:
        # 使用LLM分类任务类型
        task_type = self.classify_task(task_description)
        return self.ROLE_PATTERNS.get(task_type, ["generalist"])
    
    def classify_task(self, description: str) -> str:
        # 简化的关键词匹配，实际可用LLM分类
        keywords = {
            "technical_design": ["设计", "架构", "选型", "方案"],
            "bug_fix": ["bug", "修复", "错误", "异常"],
            "feature_dev": ["开发", "实现", "新增", "功能"],
            "code_review": ["审查", "review", "代码检查"],
            "performance": ["性能", "优化", "慢", "卡顿"],
        }
        
        for task_type, words in keywords.items():
            if any(w in description for w in words):
                return task_type
        return "general"
```

---

## 第4-7章 内容精要

### 第4章 通信协议与消息机制
- **消息总线**：中央路由器，解耦Agent间的直接依赖
- **消息Schema**：`{msg_id, from, to, type, payload, timestamp, correlation_id}`
- **同步阻塞调用**：等待特定Agent回复（适合强依赖步骤）
- **异步事件**：fire-and-forget（适合日志、通知）
- **黑板模式**：共享的写入板，Agent读取/写入状态

### 第5章 协作模式与任务分配
- **序列协作**：A完成 → B基于A的结果继续 → C完成最终输出
- **Map-Reduce**：拆分 → 并行处理 → 汇总（适合大数据处理）
- **投票共识**：多个Agent独立给出答案，取多数或平均
- **辩论模式**：正方Agent vs 反方Agent，最后由Judge裁决
- **竞争模式**：多个Agent尝试同一任务，取最优结果

### 第6章 调度与编排
- **静态工作流**：预定义的DAG（如LangGraph的StateGraph）
- **动态编排**：Supervisor根据中间结果决定下一步
- **死锁避免**：超时机制 + 资源排序 + 循环检测
- **回滚机制**：某步失败时回退到上一稳定状态

### 第7章 实战：软件开发多Agent团队
- 团队配置：PM + 架构师 + 前端 + 后端 + 测试 + Reviewer
- 需求分析 → 技术方案 → 任务分配 → 并行开发 → 代码审查 → 集成测试
- 每个阶段的输出作为下一阶段输入
- 质量门控：Reviewer不通过则打回修改

---

## 本章小结

| 知识点 | Agent开发应用 |
|--------|--------------|
| 层级架构 | 复杂任务的分层管理，Supervisor统一协调 |
| 对等网络 | Agent间直接协作，适合去中心化场景 |
| 流水线架构 | 单向数据流，适合内容创作等流程化任务 |
| 角色定义 | 明确职责边界，减少冲突，提升专业性 |
| 动态分配 | 根据任务特征自动组建Agent团队 |
| 通信协议 | 可靠的消息传递是多Agent协作的基础 |
| 协作模式 | 选择适合任务的协作策略（序列/并行/投票/辩论） |

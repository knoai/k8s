# 05. Function Calling与Tool Use：Agent的"手"与"脑"

> **目标读者**：已了解Agent基础，希望深入掌握工具调用机制的开发工程师  
> **核心目标**：掌握Function Calling协议、工具Schema设计、调用链路与错误处理

---

## 目录

### 第1章 为什么Agent需要工具（已详细编写）
1.1 LLM的固有能力边界  
1.2 工具调用：扩展LLM的"执行半径"  
1.3 Agent = LLM + 工具 + 记忆 + 规划

### 第2章 Function Calling协议深度解析（已详细编写）
2.1 OpenAI Function Calling协议  
2.2 Claude Tool Use协议  
2.3 通用工具调用接口设计  
2.4 流式工具调用处理

### 第3章 工具Schema设计与定义（已详细编写）
3.1 JSON Schema基础  
3.2 参数类型系统：string/number/integer/boolean/array/object  
3.3 参数约束：enum、pattern、min/max  
3.4 工具描述的最佳实践  
3.5 自动生成Schema的技巧

### 第4章 工具实现与注册
4.1 同步工具与异步工具  
4.2 工具状态管理  
4.3 工具组合与嵌套调用  
4.4 工具权限与安全控制

### 第5章 调用链路与执行引擎
5.1 Tool Calling的执行流程  
5.2 并行工具调用  
5.3 工具结果回传与上下文更新  
5.4 调用超时与重试机制

### 第6章 错误处理与容错设计
6.1 工具调用失败的分类  
6.2 优雅降级策略  
6.3 错误信息回传LLM  
6.4 断路器模式与限流

### 第7章 实战：构建企业级工具平台
7.1 工具注册中心设计  
7.2 动态工具发现与加载  
7.3 工具调用审计日志  
7.4 完整案例：数据分析Agent的工具系统

---

## 第1章 为什么Agent需要工具

### 1.1 LLM的固有能力边界

LLM虽然强大，但存在根本性限制：

| 限制类型 | 具体表现 | 工具解决方案 |
|----------|----------|-------------|
| **知识时效性** | 训练数据有截止日期 | 搜索工具获取实时信息 |
| **计算精确性** | 数学计算容易出错 | 计算器工具 |
| **外部交互** | 无法访问数据库/API | 数据库查询工具 |
| **状态持久化** | 无法保存文件 | 文件系统工具 |
| **代码执行** | 不能实际运行代码 | 代码解释器工具 |
| **感知能力** | 无法获取当前环境信息 | 传感器/API工具 |

**没有工具的LLM vs 有工具的Agent：**

```
用户："北京今天多少度？下周三呢？"

没有工具：
  LLM: "我无法获取实时天气数据，因为我的知识截止到2024年4月..."
  （❌ 无法解决用户问题）

有工具：
  LLM: 需要获取天气信息 → 调用 weather_query(city="北京", date="today")
  Tool: {"temperature": 25, "condition": "晴"}
  LLM: 需要获取下周三天气 → 调用 weather_query(city="北京", date="2024-05-08")
  Tool: {"temperature": 22, "condition": "多云"}
  LLM: "北京今天25°C，晴天。下周三预计22°C，多云。"
  （✅ 完美解决问题）
```

### 1.2 工具调用：扩展LLM的"执行半径"

```
        ┌─────────────────────────────────────┐
        │            LLM 核心                 │
        │   理解、推理、规划、生成            │
        └─────────────────┬─────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐   ┌──────────┐   ┌──────────┐
    │  搜索工具 │   │ 计算工具  │   │ API工具  │
    │  🔍      │   │  🧮      │   │  🔌      │
    └──────────┘   └──────────┘   └──────────┘
          │               │               │
          └───────────────┼───────────────┘
                          ▼
                   ┌──────────────┐
                   │   外部世界    │
                   │  互联网/DB/   │
                   │  文件/API    │
                   └──────────────┘
```

### 1.3 Agent = LLM + 工具 + 记忆 + 规划

```python
from dataclasses import dataclass
from typing import Callable, Any

@dataclass
class Tool:
    name: str
    description: str
    parameters: dict  # JSON Schema
    func: Callable[..., Any]
    is_async: bool = False

@dataclass
class Agent:
    llm: Any                    # 大语言模型
    tools: list[Tool]           # 可用工具集
    memory: list[dict]          # 对话历史/工作记忆
    planner: Callable           # 规划器（可选）
    max_iterations: int = 10    # 最大思考-行动循环次数
    
    def get_tools_description(self) -> str:
        """为LLM生成工具描述文本"""
        lines = ["## 可用工具"]
        for tool in self.tools:
            lines.append(f"\n### {tool.name}")
            lines.append(f"描述：{tool.description}")
            lines.append(f"参数：{tool.parameters}")
        return "\n".join(lines)
```

---

## 第2章 Function Calling协议深度解析

### 2.1 OpenAI Function Calling协议

**请求格式：**

```python
import openai

client = openai.OpenAI()

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[
        {"role": "system", "content": "你是一个天气助手"},
        {"role": "user", "content": "北京今天天气怎么样？"}
    ],
    tools=[
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "获取指定城市的天气信息",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "city": {
                            "type": "string",
                            "description": "城市名称，如'北京'"
                        },
                        "date": {
                            "type": "string",
                            "enum": ["today", "tomorrow"],
                            "description": "查询日期"
                        }
                    },
                    "required": ["city", "date"]
                }
            }
        }
    ],
    tool_choice="auto"  # "auto" | "none" | {"type": "function", "function": {"name": "xxx"}}
)
```

**响应格式（工具调用）：**

```python
# response.choices[0].message 可能是：
{
    "role": "assistant",
    "content": None,
    "tool_calls": [
        {
            "id": "call_abc123",
            "type": "function",
            "function": {
                "name": "get_weather",
                "arguments": '{"city": "北京", "date": "today"}'
            }
        }
    ]
}
```

**工具结果回传：**

```python
# 执行工具后，将结果作为 tool 消息回传
messages.append({
    "role": "tool",
    "tool_call_id": "call_abc123",
    "name": "get_weather",
    "content": '{"temperature": 25, "condition": "晴"}'
})

# 再次调用LLM，获取最终回答
response = client.chat.completions.create(
    model="gpt-4o",
    messages=messages,
    tools=tools
)
```

### 2.2 Claude Tool Use协议

```python
import anthropic

client = anthropic.Anthropic()

response = client.messages.create(
    model="claude-3-5-sonnet-20241022",
    max_tokens=1024,
    tools=[
        {
            "name": "get_weather",
            "description": "获取指定城市的天气信息",
            "input_schema": {
                "type": "object",
                "properties": {
                    "city": {"type": "string"},
                    "date": {"type": "string", "enum": ["today", "tomorrow"]}
                },
                "required": ["city"]
            }
        }
    ],
    messages=[{"role": "user", "content": "北京今天天气怎么样？"}]
)

# Claude 的 tool_use block
for content in response.content:
    if content.type == "tool_use":
        print(f"调用工具：{content.name}")
        print(f"参数：{content.input}")
        
        # 执行工具
        result = execute_tool(content.name, content.input)
        
        # 回传结果（使用 tool_result block）
        follow_up = client.messages.create(
            model="claude-3-5-sonnet-20241022",
            max_tokens=1024,
            tools=tools,
            messages=[
                {"role": "user", "content": "北京今天天气怎么样？"},
                {"role": "assistant", "content": response.content},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": content.id,
                            "content": str(result)
                        }
                    ]
                }
            ]
        )
```

### 2.3 通用工具调用接口设计

```python
from abc import ABC, abstractmethod
from typing import Any, AsyncIterator
from dataclasses import dataclass

@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict[str, Any]

@dataclass
class ToolResult:
    call_id: str
    output: Any
    error: str | None = None
    execution_time_ms: float = 0.0

class BaseLLMProvider(ABC):
    """统一的LLM提供商接口，屏蔽OpenAI/Claude差异"""
    
    @abstractmethod
    async def chat_with_tools(
        self,
        messages: list[dict],
        tools: list[dict],
        tool_choice: str = "auto"
    ) -> tuple[str | None, list[ToolCall]]:
        """
        返回：(直接回答内容, 工具调用列表)
        如果有工具调用，content为None
        """
        pass
    
    @abstractmethod
    async def chat_with_tool_results(
        self,
        messages: list[dict],
        tools: list[dict],
        tool_results: list[ToolResult]
    ) -> str:
        """传入工具执行结果，获取最终回答"""
        pass

class OpenAIProvider(BaseLLMProvider):
    def __init__(self, client: openai.AsyncOpenAI, model: str = "gpt-4o"):
        self.client = client
        self.model = model
    
    async def chat_with_tools(self, messages, tools, tool_choice="auto"):
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            tools=tools,
            tool_choice=tool_choice
        )
        msg = response.choices[0].message
        
        tool_calls = []
        if msg.tool_calls:
            for tc in msg.tool_calls:
                tool_calls.append(ToolCall(
                    id=tc.id,
                    name=tc.function.name,
                    arguments=json.loads(tc.function.arguments)
                ))
        
        return msg.content, tool_calls
    
    async def chat_with_tool_results(self, messages, tools, tool_results):
        for tr in tool_results:
            messages.append({
                "role": "tool",
                "tool_call_id": tr.call_id,
                "name": tr.name if hasattr(tr, 'name') else "",
                "content": str(tr.output) if tr.error is None else f"ERROR: {tr.error}"
            })
        
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            tools=tools
        )
        return response.choices[0].message.content
```

### 2.4 流式工具调用处理

```python
async def stream_chat_with_tools(client, messages, tools):
    """流式处理工具调用，实时展示思考过程"""
    stream = await client.chat.completions.create(
        model="gpt-4o",
        messages=messages,
        tools=tools,
        stream=True
    )
    
    current_content = []
    current_tool_calls = {}
    
    async for chunk in stream:
        delta = chunk.choices[0].delta
        
        # 处理文本内容
        if delta.content:
            current_content.append(delta.content)
            print(delta.content, end="", flush=True)
        
        # 处理工具调用（流式增量更新）
        if delta.tool_calls:
            for tc_delta in delta.tool_calls:
                idx = tc_delta.index
                if idx not in current_tool_calls:
                    current_tool_calls[idx] = {"id": "", "name": "", "arguments": ""}
                
                if tc_delta.id:
                    current_tool_calls[idx]["id"] += tc_delta.id
                if tc_delta.function.name:
                    current_tool_calls[idx]["name"] += tc_delta.function.name
                if tc_delta.function.arguments:
                    current_tool_calls[idx]["arguments"] += tc_delta.function.arguments
    
    # 解析完整工具调用
    tool_calls = []
    for tc in current_tool_calls.values():
        tool_calls.append(ToolCall(
            id=tc["id"],
            name=tc["name"],
            arguments=json.loads(tc["arguments"])
        ))
    
    return "".join(current_content), tool_calls
```

---

## 第3章 工具Schema设计与定义

### 3.1 JSON Schema基础

工具参数使用JSON Schema定义，这是Function Calling的核心：

```python
{
    "type": "object",  # 根必须是object
    "properties": {
        # 参数定义
    },
    "required": ["param1", "param2"]  # 必填参数
}
```

### 3.2 参数类型系统

| JSON Schema类型 | Python对应 | 示例 | 适用场景 |
|----------------|------------|------|----------|
| `string` | `str` | 城市名、URL | 文本输入 |
| `number` | `float` | 温度、价格 | 浮点数值 |
| `integer` | `int` | 数量、页码 | 整数值 |
| `boolean` | `bool` | 是否发送邮件 | 开关选项 |
| `array` | `list` | 标签列表、ID列表 | 批量操作 |
| `object` | `dict` | 配置项、复杂查询 | 结构化数据 |

```python
# 复杂Schema示例：数据库查询工具
database_query_schema = {
    "type": "object",
    "properties": {
        "table": {
            "type": "string",
            "description": "要查询的表名"
        },
        "columns": {
            "type": "array",
            "items": {"type": "string"},
            "description": "要查询的列名，为空则查询所有"
        },
        "where": {
            "type": "object",
            "properties": {
                "column": {"type": "string"},
                "operator": {
                    "type": "string",
                    "enum": ["=", "!=", ">", "<", "LIKE", "IN"]
                },
                "value": {"type": "string"}
            },
            "description": "WHERE条件（仅支持简单条件）"
        },
        "limit": {
            "type": "integer",
            "minimum": 1,
            "maximum": 100,
            "default": 10,
            "description": "返回结果数量限制"
        }
    },
    "required": ["table"]
}
```

### 3.3 参数约束

```python
# 枚举约束：限定可选值
{
    "type": "string",
    "enum": ["high", "medium", "low"],
    "description": "优先级级别"
}

# 正则约束：验证格式
{
    "type": "string",
    "pattern": "^\\d{4}-\\d{2}-\\d{2}$",
    "description": "日期格式：YYYY-MM-DD"
}

# 数值范围
{
    "type": "integer",
    "minimum": 1,
    "maximum": 100,
    "description": "分页大小"
}

# 数组长度约束
{
    "type": "array",
    "minItems": 1,
    "maxItems": 5,
    "items": {"type": "string"},
    "description": "最多5个标签"
}
```

### 3.4 工具描述的最佳实践

**不好的描述：**
```python
{
    "name": "search",
    "description": "搜索功能",
    "parameters": {
        "properties": {
            "q": {"type": "string"}
        }
    }
}
```

**好的描述：**
```python
{
    "name": "web_search",
    "description": "在搜索引擎中查询实时信息。当用户询问当前事件、天气、股价、名人动态等时效性信息时使用。不要用于用户已提供的已知事实查询。",
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "搜索查询语句，应简洁明确，包含关键信息。例如：'2024年奥斯卡最佳影片'"
            },
            "num_results": {
                "type": "integer",
                "minimum": 1,
                "maximum": 10,
                "default": 3,
                "description": "返回的搜索结果数量"
            }
        },
        "required": ["query"]
    }
}
```

**工具描述设计原则：**

1. **说明何时使用该工具**：帮助模型正确判断调用时机
2. **说明何时不该使用**：减少误调用
3. **参数描述包含示例**：降低模型理解偏差
4. **保持简洁**：过长的描述会占用宝贵的上下文空间

### 3.5 自动生成Schema的技巧

```python
from typing import Annotated
from pydantic import BaseModel, Field
import inspect

class SearchInput(BaseModel):
    """搜索工具的输入参数"""
    query: str = Field(description="搜索查询语句")
    num_results: int = Field(
        default=3,
        ge=1,
        le=10,
        description="返回结果数量"
    )

# 从Pydantic模型自动生成工具定义
def pydantic_to_tool_schema(model: type[BaseModel], name: str, description: str) -> dict:
    schema = model.model_json_schema()
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": schema
        }
    }

# 从函数自动生成（Python 3.9+）
def auto_tool(func):
    """装饰器：自动从函数签名生成工具定义"""
    sig = inspect.signature(func)
    
    properties = {}
    required = []
    
    for name, param in sig.parameters.items():
        if name == "self":
            continue
        
        param_type = "string"  # 默认
        if param.annotation != inspect.Parameter.empty:
            if param.annotation == int:
                param_type = "integer"
            elif param.annotation == float:
                param_type = "number"
            elif param.annotation == bool:
                param_type = "boolean"
        
        properties[name] = {"type": param_type}
        
        if param.default == inspect.Parameter.empty:
            required.append(name)
        else:
            properties[name]["default"] = param.default
    
    tool_def = {
        "name": func.__name__,
        "description": func.__doc__ or "",
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": required
        }
    }
    
    func._tool_definition = tool_def
    return func

@auto_tool
def get_stock_price(symbol: str, exchange: str = "NASDAQ"):
    """获取股票当前价格。当用户询问特定股票行情时使用。"""
    pass

print(get_stock_price._tool_definition)
```

---

## 第4-7章 内容精要

### 第4章 工具实现与注册
- 同步工具用 `def`，异步工具用 `async def`
- 工具共享状态：使用类方法或闭包
- 嵌套调用：一个工具内部调用其他工具
- 权限控制：基于角色的工具可见性

### 第5章 调用链路与执行引擎
- 标准执行流程：`User Input → LLM → Tool Call → Execution → LLM → Response`
- OpenAI支持单轮多工具并行调用（`tool_calls`数组）
- 结果回传时保持调用ID的对应关系
- 上下文更新：将工具结果加入messages后再次调用LLM

### 第6章 错误处理与容错设计
- 错误分类：参数错误、执行错误、超时、权限不足、服务不可用
- 优雅降级：搜索失败 → 使用本地知识 → 告知用户限制
- 错误信息结构化回传：`{"error": "...", "suggestion": "..."}`
- 断路器：连续失败N次后暂时禁用工具

### 第7章 实战：企业级工具平台
- 工具注册中心：统一注册、发现、版本管理
- 动态加载：基于配置热加载新工具
- 审计日志：记录谁在什么时候调用了什么工具
- 数据分析Agent案例：SQL查询 + 可视化 + 报告生成

---

## 本章小结

| 知识点 | Agent开发应用 |
|--------|--------------|
| Function Calling协议 | Agent与外部世界交互的标准语言 |
| JSON Schema设计 | 定义工具的"接口契约"，直接影响调用准确率 |
| 通用Provider接口 | 屏蔽模型差异，支持多模型无缝切换 |
| 流式工具调用 | 实时展示Agent的思考过程，提升用户体验 |
| Schema约束 | 减少模型幻觉导致的错误参数 |
| 自动生成Schema | 降低工具开发成本，保持代码和定义同步 |
| 错误处理 | 健壮Agent系统的必备能力 |

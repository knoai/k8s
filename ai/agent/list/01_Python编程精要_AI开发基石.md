# 01. Python编程精要：AI开发基石

> **目标读者**：具备基础编程经验，希望系统提升Python能力以从事Agent开发的工程师  
> **核心目标**：掌握Agent开发所需的Python高级特性、异步编程、类型系统和工程化能力  
> **预计阅读时间**：40小时  
> **配套代码**：每章均提供完整可运行代码

---

## 目录

- [第1章 Agent开发为什么需要扎实的Python功底](#第1章-agent开发为什么需要扎实的python功底)
- [第2章 Python高级语法与特性](#第2章-python高级语法与特性)
- [第3章 异步编程：Agent高并发的核心](#第3章-异步编程agent高并发的核心)
- [第4章 类型系统与代码质量](#第4章-类型系统与代码质量)
- [第5章 函数式编程与数据处理](#第5章-函数式编程与数据处理)
- [第6章 测试驱动开发与工程化](#第6章-测试驱动开发与工程化)
- [第7章 Python与LLM SDK集成](#第7章-python与llm-sdk集成)

---

## 第1章 Agent开发为什么需要扎实的Python功底

### 1.1 Agent系统的技术栈全景

构建一个生产级的AI Agent系统，远不止是调用OpenAI API那么简单。一个完整的Agent技术栈涉及多个层次，而Python贯穿其中每一层：

```
┌─────────────────────────────────────────────────────────────────┐
│                        应用交互层                                │
│   Streamlit / Gradio / React + FastAPI / Flask                  │
├─────────────────────────────────────────────────────────────────┤
│                        Agent编排层                               │
│   LangChain / LangGraph / CrewAI / AutoGen / 自研框架           │
├─────────────────────────────────────────────────────────────────┤
│                        核心能力层                                │
│   Prompt工程 │ 工具调用 │ 记忆系统 │ 规划推理 │ 多Agent协作       │
├─────────────────────────────────────────────────────────────────┤
│                        模型接口层                                │
│   OpenAI / Anthropic / Azure / 本地模型 (Ollama / vLLM)        │
├─────────────────────────────────────────────────────────────────┤
│                        基础设施层                                │
│   Docker / K8s │ Redis │ PostgreSQL │ 向量数据库 │ 消息队列      │
└─────────────────────────────────────────────────────────────────┘
```

Python之所以成为Agent开发的首选语言，原因不仅仅是拥有丰富的AI库。更重要的是：

1. **异步生态成熟**：Agent需要并发处理大量LLM调用和工具调用，Python的`asyncio`生态提供了完整的解决方案
2. **类型系统现代**：Python 3.9+的类型系统配合Pydantic，能够构建高度可靠的Agent数据流
3. **LLM SDK原生支持**：所有主流LLM提供商的Python SDK都是一等公民
4. **元编程能力**：装饰器、描述符等机制为Agent框架的动态工具注册提供了语言级支持

### 1.2 本书知识地图

本书按照Agent开发的实际需求组织，而非传统的Python语法顺序。每一章解决Agent开发中遇到的具体问题：

| Agent开发场景 | 所需Python能力 | 对应章节 |
|--------------|--------------|---------|
| 流式处理LLM输出 | 迭代器、生成器 | 第2章 |
| 动态注册工具 | 装饰器、元类 | 第2章 |
| 管理会话生命周期 | 上下文管理器 | 第2章 |
| 并发调用多个工具 | asyncio、并发控制 | 第3章 |
| 解析LLM结构化输出 | TypeHints、Pydantic | 第4章 |
| 处理工具结果管道 | 函数式编程 | 第5章 |
| 保证Agent逻辑正确 | 测试、Mock | 第6章 |
| 统一多模型接口 | SDK封装、抽象基类 | 第7章 |

---

## 第2章 Python高级语法与特性

### 2.1 迭代器协议与生成器：流式Agent的基础

#### 2.1.1 迭代器协议的本质

Python的迭代器协议是`for`循环背后的核心机制。理解它对于处理Agent中的流式数据至关重要——因为LLM的流式输出本质上就是一个迭代器。

```python
# 迭代器协议：任何实现了 __iter__ 和 __next__ 的对象
class CountDown:
    def __init__(self, start: int):
        self.start = start
    
    def __iter__(self):
        return self
    
    def __next__(self):
        if self.start <= 0:
            raise StopIteration
        self.start -= 1
        return self.start + 1

# 使用
for num in CountDown(5):
    print(num)  # 5, 4, 3, 2, 1
```

**深入理解**：当Python执行`for x in obj`时，实际发生的是：
1. 调用`iter(obj)` → 获取迭代器（调用`obj.__iter__()`）
2. 重复调用`next(iterator)` → 获取下一个值（调用`iterator.__next__()`）
3. 捕获`StopIteration`异常 → 循环结束

这个机制的美妙之处在于：**迭代器是惰性的**。它只在需要时才计算下一个值，而不是一次性把所有数据加载到内存。

#### 2.1.2 生成器函数：yield的魔力

生成器函数是编写迭代器的最简单方式——它自动实现了迭代器协议。

```python
def token_stream(text: str, chunk_size: int = 4):
    """
    模拟LLM的token流式输出。
    
    为什么Agent需要这个？
    LLM API（如OpenAI）支持stream=True，返回的就是一个生成器。
    我们需要能够消费、转换、甚至拦截这个流。
    """
    for i in range(0, len(text), chunk_size):
        chunk = text[i:i + chunk_size]
        # 模拟网络延迟
        import time
        time.sleep(0.1)
        yield chunk

# 消费流
for token in token_stream("Hello, this is an AI Agent speaking!"):
    print(token, end="", flush=True)
```

**生成器的状态机模型**：

生成器函数的执行不是一次性完成的。每次`yield`时，函数的状态（局部变量、指令指针）被冻结；下次`next()`被调用时，从冻结处继续执行。这在底层通过Python的`PyFrameObject`和`f_lasti`（最后执行的指令索引）实现。

```python
def stateful_generator():
    print("State 1: 初始化")
    value = yield "Ready"
    print(f"State 2: 收到 {value}")
    value = yield f"Processed {value}"
    print(f"State 3: 收到 {value}")
    yield "Done"

gen = stateful_generator()
print(next(gen))        # State 1: 初始化 → "Ready"
print(gen.send("foo"))  # State 2: 收到 foo → "Processed foo"
print(gen.send("bar"))  # State 3: 收到 bar → "Done"
```

`send()`方法让生成器变成了**双向通信通道**——这是构建复杂Agent管道的关键。你可以向生成器发送控制指令，它可以根据指令改变行为。

#### 2.1.3 yield from：委托与组合

当Agent需要组合多个数据源时，`yield from`提供了优雅的委托机制。

```python
def multi_tool_stream(tools: list[dict]):
    """
    Agent同时调用了多个工具，需要合并它们的结果流。
    yield from 让我们可以像处理单层生成器一样处理嵌套结构。
    """
    for tool in tools:
        yield from execute_single_tool(tool)

def execute_single_tool(tool: dict):
    """单个工具的执行流"""
    yield {"status": "started", "tool": tool["name"], "timestamp": time.time()}
    
    # 模拟执行
    import time
    time.sleep(tool.get("duration", 1))
    
    result = f"Result of {tool['name']}"
    yield {"status": "completed", "tool": tool["name"], "result": result}

# 使用
tools = [
    {"name": "web_search", "duration": 2},
    {"name": "database_query", "duration": 1},
]

for event in multi_tool_stream(tools):
    print(event)
```

**`yield from`的底层行为**：
1. 迭代子生成器，将所有`yield`的值转发给调用方
2. 当子生成器`return`时，`yield from`表达式的值就是`return`的值
3. 自动处理`send()`和`throw()`的委托

```python
def delegated():
    value = yield "inner start"
    yield f"inner got: {value}"
    return "inner result"

def delegator():
    result = yield from delegated()
    yield f"delegator got: {result}"

for value in delegator():
    print(value)
# inner start
# inner got: None
# delegator got: inner result
```

#### 2.1.4 生成器表达式：内存高效的管道

Agent处理大量消息历史时，经常需要过滤和转换。生成器表达式提供了内存高效的解决方案。

```python
messages = [
    {"role": "system", "content": "You are a helpful assistant"},
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi there!"},
    {"role": "user", "content": "What's the weather?"},
    {"role": "tool", "content": '{"temp": 25}'},
    {"role": "assistant", "content": "It's 25°C"},
]

# ❌ 列表推导：创建中间列表，占用内存
user_messages_list = [m for m in messages if m["role"] == "user"]

# ✅ 生成器表达式：惰性求值，不占用额外内存
user_messages_gen = (m for m in messages if m["role"] == "user")

# 可以组合多个操作，形成处理管道
recent_user_queries = (
    m["content"] for m in messages
    if m["role"] == "user"
)

query_lengths = (
    len(q) for q in recent_user_queries
)

avg_length = sum(query_lengths) / len([m for m in messages if m["role"] == "user"])
print(f"平均查询长度: {avg_length}")
```

#### 2.1.5 实战：构建Agent消息流处理器

```python
from typing import Iterator, Callable, Any
import time

class AgentMessageStream:
    """
    Agent消息流处理器：用于处理LLM的流式输出，支持中间转换和拦截。
    
    核心能力：
    - 逐token消费LLM输出
    - 实时统计token数量
    - 检测停止词
    - 触发工具调用解析
    """
    
    def __init__(self, raw_stream: Iterator[str]):
        self.raw_stream = raw_stream
        self.buffer = ""
        self.token_count = 0
        self.start_time = time.time()
    
    def with_token_count(self) -> Iterator[tuple[str, int]]:
        """在返回每个token的同时返回累计token数"""
        for token in self.raw_stream:
            self.token_count += self._estimate_tokens(token)
            yield token, self.token_count
    
    def with_latency(self) -> Iterator[tuple[str, float]]:
        """返回每个token及其接收延迟"""
        for token in self.raw_stream:
            latency = time.time() - self.start_time
            yield token, latency
    
    def with_tool_detection(self, tool_prefix: str = "TOOL:") -> Iterator[dict]:
        """
        检测流中是否包含工具调用指令。
        当检测到工具调用时，yield一个特殊事件。
        """
        for token in self.raw_stream:
            self.buffer += token
            
            # 检查是否触发了工具调用
            if tool_prefix in self.buffer:
                # 提取工具调用部分
                parts = self.buffer.split(tool_prefix, 1)
                if parts[0]:
                    yield {"type": "text", "content": parts[0]}
                
                tool_call = parts[1].strip()
                yield {"type": "tool_call", "content": tool_call}
                self.buffer = ""
            else:
                yield {"type": "text", "content": token}
        
        # 输出剩余buffer
        if self.buffer:
            yield {"type": "text", "content": self.buffer}
    
    def _estimate_tokens(self, text: str) -> int:
        """粗略估算token数：英文约4字符/token，中文约1字符/token"""
        return max(len(text) // 4, 1)
    
    def collect(self, timeout: float = 30.0) -> str:
        """收集所有token为完整字符串（非流式场景的fallback）"""
        import signal
        
        def timeout_handler(signum, frame):
            raise TimeoutError(f"Stream collection timed out after {timeout}s")
        
        signal.signal(signal.SIGALRM, timeout_handler)
        signal.setitimer(signal.ITIMER_REAL, timeout)
        
        try:
            return "".join(self.raw_stream)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)


# 测试
def mock_llm_stream():
    """模拟LLM流式输出"""
    chunks = ["I", " will", " search", " for", " that", " information", "."]
    for chunk in chunks:
        time.sleep(0.05)
        yield chunk

stream = AgentMessageStream(mock_llm_stream())
print("带token计数:")
for token, count in stream.with_token_count():
    print(f"  '{token}' (累计: {count} tokens)")
```

### 2.2 装饰器与元编程：动态Agent能力注册

#### 2.2.1 装饰器的执行时机

装饰器是Python中实现**横切关注点**（cross-cutting concerns）的核心工具。在Agent框架中，它被用于工具注册、日志记录、重试逻辑、性能监控等。

理解装饰器的关键是：**装饰器在模块导入时执行，而不是函数调用时**。

```python
# 装饰器的执行流程
def my_decorator(func):
    print(f"[模块导入时] 装饰 {func.__name__}")
    def wrapper(*args, **kwargs):
        print(f"[函数调用时] 调用 {func.__name__}")
        return func(*args, **kwargs)
    return wrapper

@my_decorator
def say_hello():
    print("Hello!")

# 输出：
# [模块导入时] 装饰 say_hello

say_hello()
# 输出：
# [函数调用时] 调用 say_hello
# Hello!
```

#### 2.2.2 参数化装饰器：Agent工具注册系统

```python
import functools
import inspect
from typing import Callable, Any, Optional

class AgentToolRegistry:
    """
    Agent工具注册中心。
    
    设计目标：
    1. 开发者用装饰器注册工具，零样板代码
    2. 自动从函数签名提取参数Schema
    3. 支持同步和异步工具
    4. 运行时动态发现和调用
    """
    
    def __init__(self):
        self._tools: dict[str, dict] = {}
        self._categories: dict[str, list[str]] = {}
    
    def register(
        self,
        name: Optional[str] = None,
        description: Optional[str] = None,
        category: str = "general",
        enabled: bool = True
    ) -> Callable:
        """
        参数化装饰器：注册工具到Agent。
        
        用法：
            @registry.register(
                name="web_search",
                description="搜索互联网获取实时信息",
                category="search"
            )
            def web_search(query: str, max_results: int = 5) -> list[dict]:
                ...
        """
        def decorator(func: Callable) -> Callable:
            tool_name = name or func.__name__
            tool_desc = description or (func.__doc__ or "").strip()
            
            # 自动提取参数Schema
            schema = self._extract_schema(func)
            
            # 检测是否是异步函数
            is_async = inspect.iscoroutinefunction(func)
            
            self._tools[tool_name] = {
                "name": tool_name,
                "description": tool_desc,
                "schema": schema,
                "func": func,
                "is_async": is_async,
                "category": category,
                "enabled": enabled,
            }
            
            if category not in self._categories:
                self._categories[category] = []
            self._categories[category].append(tool_name)
            
            @functools.wraps(func)
            def wrapper(*args, **kwargs):
                return func(*args, **kwargs)
            
            # 附加元数据到函数对象
            wrapper._tool_name = tool_name
            wrapper._tool_registry = self
            
            return wrapper
        return decorator
    
    def _extract_schema(self, func: Callable) -> dict:
        """从函数签名自动提取JSON Schema风格的参数定义"""
        sig = inspect.signature(func)
        properties = {}
        required = []
        
        type_map = {
            str: {"type": "string"},
            int: {"type": "integer"},
            float: {"type": "number"},
            bool: {"type": "boolean"},
            list: {"type": "array"},
            dict: {"type": "object"},
        }
        
        for param_name, param in sig.parameters.items():
            if param_name in ("self", "cls"):
                continue
            
            prop = {"description": ""}
            
            # 类型注解
            if param.annotation != inspect.Parameter.empty:
                origin = getattr(param.annotation, "__origin__", None)
                if origin is list or param.annotation is list:
                    prop["type"] = "array"
                    args = getattr(param.annotation, "__args__", None)
                    if args:
                        prop["items"] = {"type": type_map.get(args[0], {}).get("type", "string")}
                elif param.annotation in type_map:
                    prop.update(type_map[param.annotation])
                elif hasattr(param.annotation, "__name__"):
                    # 自定义类型，默认string
                    prop["type"] = "string"
            else:
                prop["type"] = "string"
            
            # 默认值
            if param.default == inspect.Parameter.empty:
                required.append(param_name)
            else:
                prop["default"] = param.default
            
            properties[param_name] = prop
        
        return {
            "type": "object",
            "properties": properties,
            "required": required,
        }
    
    def get_tool(self, name: str) -> dict:
        if name not in self._tools:
            raise KeyError(f"Tool '{name}' not registered")
        return self._tools[name]
    
    def list_tools(self, category: Optional[str] = None) -> list[dict]:
        """列出所有或指定分类的工具"""
        if category:
            names = self._categories.get(category, [])
            return [self._tools[n] for n in names if self._tools[n]["enabled"]]
        return [t for t in self._tools.values() if t["enabled"]]
    
    def get_openai_tools_format(self) -> list[dict]:
        """转换为OpenAI Function Calling格式"""
        return [
            {
                "type": "function",
                "function": {
                    "name": t["name"],
                    "description": t["description"],
                    "parameters": t["schema"],
                }
            }
            for t in self._tools.values() if t["enabled"]
        ]

# 使用示例
registry = AgentToolRegistry()

@registry.register(
    name="web_search",
    description="使用搜索引擎查询互联网上的实时信息。当用户询问新闻、天气、股价、事件等时效性信息时使用。",
    category="search"
)
def web_search(query: str, max_results: int = 5) -> list[dict]:
    """执行网络搜索"""
    # 实际实现会调用搜索引擎API
    return [{"title": f"Result for {query}", "url": "http://example.com"}]

@registry.register(
    name="calculate",
    description="执行数学计算。当用户需要进行精确数学运算时使用。",
    category="math"
)
def calculate(expression: str) -> float:
    """安全执行数学表达式"""
    # 使用安全eval或ast.literal_eval
    import ast
    import operator
    
    allowed_ops = {
        ast.Add: operator.add,
        ast.Sub: operator.sub,
        ast.Mult: operator.mul,
        ast.Div: operator.truediv,
        ast.Pow: operator.pow,
    }
    
    def eval_node(node):
        if isinstance(node, ast.Num):
            return node.n
        elif isinstance(node, ast.BinOp):
            op = allowed_ops.get(type(node.op))
            if not op:
                raise ValueError(f"Unsupported operation: {type(node.op)}")
            return op(eval_node(node.left), eval_node(node.right))
        else:
            raise ValueError(f"Unsupported node type: {type(node)}")
    
    tree = ast.parse(expression, mode='eval')
    return eval_node(tree.body)

# 查看注册结果
print("已注册工具:")
for tool in registry.list_tools():
    print(f"  - {tool['name']}: {tool['description']}")

print("\nOpenAI格式:")
import json
print(json.dumps(registry.get_openai_tools_format(), indent=2, ensure_ascii=False))
```

#### 2.2.3 类装饰器：Agent状态机

```python
def agent_state_machine(states: list[str], initial: Optional[str] = None):
    """
    类装饰器：为Agent类添加状态机能力。
    
    Agent的执行是一个状态转换过程：
    idle → thinking → acting → observing → (循环) → finished
    """
    def decorator(cls):
        valid_states = set(states)
        _initial = initial or states[0]
        
        # 保存原始__init__
        original_init = cls.__init__
        
        @functools.wraps(original_init)
        def new_init(self, *args, **kwargs):
            self._state = _initial
            self._state_history = [(_initial, time.time())]
            original_init(self, *args, **kwargs)
        
        cls.__init__ = new_init
        
        # 添加状态管理方法
        def get_state(self) -> str:
            return self._state
        
        def set_state(self, new_state: str) -> None:
            if new_state not in valid_states:
                raise ValueError(
                    f"Invalid state '{new_state}'. "
                    f"Valid states: {valid_states}"
                )
            old_state = self._state
            self._state = new_state
            self._state_history.append((new_state, time.time()))
            
            # 触发状态变更回调（如果存在）
            if hasattr(self, f"on_{new_state}"):
                getattr(self, f"on_{new_state}")(old_state)
        
        def get_state_history(self) -> list[tuple[str, float]]:
            return self._state_history.copy()
        
        cls.get_state = get_state
        cls.set_state = set_state
        cls.get_state_history = get_state_history
        cls.VALID_STATES = valid_states
        
        return cls
    return decorator

import time

@agent_state_machine(
    states=["idle", "planning", "executing", "observing", "reflecting", "completed", "error"],
    initial="idle"
)
class ReActAgent:
    def __init__(self, llm_client):
        self.llm = llm_client
        self.memory = []
    
    def on_executing(self, old_state: str):
        """进入executing状态的回调"""
        print(f"[{time.strftime('%H:%M:%S')}] 开始执行工具 (从 {old_state})")
    
    def on_error(self, old_state: str):
        """进入error状态的回调"""
        print(f"[{time.strftime('%H:%M:%S')}] 执行出错 (从 {old_state})")

# 使用
agent = ReActAgent(None)
print(f"初始状态: {agent.get_state()}")

agent.set_state("planning")
agent.set_state("executing")
agent.set_state("observing")

print("\n状态历史:")
for state, ts in agent.get_state_history():
    print(f"  {state} @ {time.strftime('%H:%M:%S', time.localtime(ts))}")
```

#### 2.2.4 描述符：属性控制的底层机制

```python
class ValidatedProperty:
    """
    描述符：用于对Agent属性进行类型验证和约束。
    
    这是@property的装饰器版本，但可复用。
    """
    def __init__(self, name: str, expected_type: type, min_val=None, max_val=None):
        self.name = name
        self.expected_type = expected_type
        self.min_val = min_val
        self.max_val = max_val
    
    def __set_name__(self, owner, name):
        self.storage_name = f"_{name}"
    
    def __get__(self, instance, owner):
        if instance is None:
            return self
        return getattr(instance, self.storage_name, None)
    
    def __set__(self, instance, value):
        if not isinstance(value, self.expected_type):
            raise TypeError(
                f"{self.name} must be {self.expected_type.__name__}, "
                f"got {type(value).__name__}"
            )
        if self.min_val is not None and value < self.min_val:
            raise ValueError(f"{self.name} must be >= {self.min_val}")
        if self.max_val is not None and value > self.max_val:
            raise ValueError(f"{self.name} must be <= {self.max_val}")
        setattr(instance, self.storage_name, value)

class ConfiguredAgent:
    """使用描述符进行属性验证的Agent基类"""
    
    max_iterations = ValidatedProperty("max_iterations", int, min_val=1, max_val=100)
    temperature = ValidatedProperty("temperature", float, min_val=0.0, max_val=2.0)
    timeout = ValidatedProperty("timeout", (int, float), min_val=0.1)
    
    def __init__(self):
        self.max_iterations = 10
        self.temperature = 0.7
        self.timeout = 30.0

agent = ConfiguredAgent()
agent.max_iterations = 15  # OK
# agent.max_iterations = -1  # ValueError
# agent.temperature = "hot"  # TypeError
```

### 2.3 上下文管理器：Agent会话生命周期

#### 2.3.1 上下文管理器协议

Agent与外部资源（数据库连接、HTTP会话、文件句柄）交互时，必须保证资源的正确释放。上下文管理器是Python中处理这种"获取-使用-释放"模式的标准方式。

```python
class AgentSession:
    """
    Agent会话上下文管理器。
    
    管理以下资源的生命周期：
    - HTTP连接池（复用TCP连接）
    - Token使用量统计
    - 执行时间追踪
    """
    
    def __init__(self, session_id: str, budget_tokens: int = 10000):
        self.session_id = session_id
        self.budget_tokens = budget_tokens
        self.tokens_used = 0
        self.start_time = None
        self._http_session = None
        self._closed = False
    
    def __enter__(self):
        import aiohttp
        import time
        
        self.start_time = time.time()
        self._http_session = aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(
                limit=20,           # 总连接数限制
                limit_per_host=5,   # 单主机连接限制
                ttl_dns_cache=300,  # DNS缓存5分钟
                use_dns_cache=True,
            ),
            timeout=aiohttp.ClientTimeout(total=60),
            headers={
                "User-Agent": "AgentBot/1.0",
                "X-Session-ID": self.session_id,
            }
        )
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        import time
        
        duration = time.time() - self.start_time
        
        # 确保会话关闭
        if self._http_session and not self._http_session.closed:
            # 同步关闭（__exit__是同步的）
            import asyncio
            try:
                loop = asyncio.get_event_loop()
                if loop.is_running():
                    # 在异步环境中，需要特殊处理
                    pass
                else:
                    loop.run_until_complete(self._http_session.close())
            except RuntimeError:
                pass
        
        self._closed = True
        
        # 记录会话统计
        print(f"\n[Session {self.session_id}] 结束")
        print(f"  持续时间: {duration:.2f}s")
        print(f"  Token使用: {self.tokens_used}/{self.budget_tokens}")
        print(f"  预算剩余: {self.budget_tokens - self.tokens_used}")
        
        if exc_type:
            print(f"  ⚠️ 异常退出: {exc_type.__name__}: {exc_val}")
        
        # 不吞掉异常
        return False
    
    def record_tokens(self, count: int):
        """记录token使用量"""
        self.tokens_used += count
        if self.tokens_used > self.budget_tokens * 0.9:
            print(f"⚠️ Token预算告警: {self.tokens_used}/{self.budget_tokens}")
        if self.tokens_used > self.budget_tokens:
            raise RuntimeError(
                f"Token预算已耗尽: {self.tokens_used}/{self.budget_tokens}"
            )
    
    @property
    def http_session(self):
        if self._closed:
            raise RuntimeError("Session已关闭")
        return self._http_session

# 使用
with AgentSession("sess_001", budget_tokens=5000) as session:
    session.record_tokens(1200)
    session.record_tokens(800)
    # 模拟工作...
    print("Agent工作中...")
```

#### 2.3.2 异步上下文管理器

Agent服务通常是异步的，因此异步上下文管理器更为实用。

```python
class AsyncAgentSession:
    """异步版本Agent会话管理器"""
    
    def __init__(self, session_id: str, budget_tokens: int = 10000):
        self.session_id = session_id
        self.budget_tokens = budget_tokens
        self.tokens_used = 0
        self.start_time = None
        self._http_session = None
        self._lock = None
    
    async def __aenter__(self):
        import aiohttp
        import asyncio
        
        self.start_time = asyncio.get_event_loop().time()
        self._lock = asyncio.Lock()
        self._http_session = aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit=20, limit_per_host=5),
            timeout=aiohttp.ClientTimeout(total=60),
        )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        import asyncio
        
        duration = asyncio.get_event_loop().time() - self.start_time
        
        if self._http_session and not self._http_session.closed:
            await self._http_session.close()
        
        print(f"\n[Async Session {self.session_id}] 结束")
        print(f"  持续时间: {duration:.2f}s")
        print(f"  Token使用: {self.tokens_used}/{self.budget_tokens}")
        
        return False
    
    async def record_tokens(self, count: int):
        async with self._lock:
            self.tokens_used += count
            if self.tokens_used > self.budget_tokens:
                raise RuntimeError("Token预算已耗尽")
    
    async def request(self, method: str, url: str, **kwargs):
        """发送HTTP请求"""
        async with self._http_session.request(method, url, **kwargs) as resp:
            return await resp.json()

# 使用
async def main():
    async with AsyncAgentSession("sess_002") as session:
        await session.record_tokens(500)
        # await session.request("GET", "https://api.example.com/data")

# asyncio.run(main())
```

#### 2.3.3 contextlib：简化上下文管理器

```python
from contextlib import contextmanager, asynccontextmanager
import time

@contextmanager
def timed_execution(operation_name: str):
    """测量代码块执行时间的上下文管理器"""
    start = time.time()
    try:
        yield  # 将控制权交给with块内的代码
    finally:
        duration = time.time() - start
        print(f"[Timer] {operation_name}: {duration:.3f}s")

# 使用
with timed_execution("LLM调用"):
    time.sleep(0.5)  # 模拟LLM调用

@asynccontextmanager
async def tool_execution_guard(tool_name: str, timeout: float = 30.0):
    """工具执行守卫：超时保护和异常包装"""
    import asyncio
    
    start = asyncio.get_event_loop().time()
    print(f"[Guard] 开始执行工具: {tool_name}")
    
    try:
        yield
    except asyncio.TimeoutError:
        elapsed = asyncio.get_event_loop().time() - start
        raise ToolTimeoutError(f"工具 {tool_name} 超时 ({elapsed:.1f}s > {timeout}s)")
    except Exception as e:
        elapsed = asyncio.get_event_loop().time() - start
        print(f"[Guard] 工具 {tool_name} 失败: {e} (耗时{elapsed:.1f}s)")
        raise ToolExecutionError(f"工具 {tool_name} 执行失败: {e}") from e
    finally:
        elapsed = asyncio.get_event_loop().time() - start
        print(f"[Guard] 工具 {tool_name} 结束 (耗时{elapsed:.1f}s)")

class ToolTimeoutError(TimeoutError):
    pass

class ToolExecutionError(RuntimeError):
    pass

# 使用
async def demo_guard():
    async with tool_execution_guard("web_search", timeout=5.0):
        await asyncio.sleep(0.1)
        print("搜索完成")

# asyncio.run(demo_guard())
```

### 2.4 dataclass与Pydantic模型：Agent数据层

#### 2.4.1 dataclass的深度使用

```python
from dataclasses import dataclass, field, asdict, astuple
from typing import Optional, List
from datetime import datetime

@dataclass(frozen=True)  # 不可变对象，适合作为字典键
class ToolCall:
    """
    工具调用的不可变标识。
    frozen=True 确保hashable，可用于集合和字典键。
    """
    id: str
    name: str
    arguments: str  # JSON字符串
    
    def parsed_arguments(self) -> dict:
        import json
        return json.loads(self.arguments)

@dataclass
class AgentAction:
    """
    Agent执行的一个动作。
    包含思考过程、选择的工具和预期观察。
    """
    thought: str
    tool_call: Optional[ToolCall] = None
    is_final: bool = False
    final_answer: Optional[str] = None
    
    # field() 用于需要默认值工厂的字段
    created_at: datetime = field(default_factory=datetime.now)
    metadata: dict = field(default_factory=dict)
    
    def __post_init__(self):
        """数据验证和派生属性计算"""
        if self.is_final and not self.final_answer:
            raise ValueError("Final action must have final_answer")
        if not self.is_final and not self.tool_call:
            raise ValueError("Non-final action must have tool_call")
    
    def to_observation_key(self) -> str:
        """生成观察结果的存储键"""
        if self.tool_call:
            return f"obs:{self.tool_call.id}"
        return "obs:final"
    
    def to_message_format(self) -> dict:
        """转换为LLM消息格式"""
        if self.is_final:
            return {"role": "assistant", "content": self.final_answer}
        return {
            "role": "assistant",
            "content": None,
            "tool_calls": [{
                "id": self.tool_call.id,
                "type": "function",
                "function": {
                    "name": self.tool_call.name,
                    "arguments": self.tool_call.arguments
                }
            }]
        }

@dataclass
class AgentStep:
    """Agent执行循环中的一个完整步骤"""
    action: AgentAction
    observation: Optional[str] = None
    error: Optional[str] = None
    latency_ms: float = 0.0
    
    # 递归结构：前序步骤
    previous_steps: List["AgentStep"] = field(default_factory=list)
    
    @property
    def is_successful(self) -> bool:
        return self.error is None
    
    def to_react_format(self) -> str:
        """转换为ReAct论文中的文本格式"""
        lines = [f"Thought: {self.action.thought}"]
        if self.action.tool_call:
            lines.append(f"Action: {self.action.tool_call.name}[{self.action.tool_call.arguments}]")
            lines.append(f"Observation: {self.observation or 'None'}")
        return "\n".join(lines)

# 使用
action = AgentAction(
    thought="用户想知道天气，我需要调用天气查询工具",
    tool_call=ToolCall(
        id="call_001",
        name="weather_query",
        arguments='{"city": "北京"}'
    )
)

step = AgentStep(
    action=action,
    observation='{"temperature": 25, "condition": "晴"}',
    latency_ms=350.0
)

print(step.to_react_format())
print(asdict(action))  # 转为字典
```

#### 2.4.2 Pydantic：Agent数据验证的终极方案

Pydantic是Agent开发中最重要的库之一。它不仅验证数据，还自动生成文档、处理序列化、支持复杂类型。

```python
from pydantic import (
    BaseModel, Field, validator, root_validator,
    conint, confloat, constr, Json
)
from typing import Literal, Optional, List
from enum import Enum

class MessageRole(str, Enum):
    """消息角色枚举"""
    SYSTEM = "system"
    USER = "user"
    ASSISTANT = "assistant"
    TOOL = "tool"

class ChatMessage(BaseModel):
    """标准聊天消息模型"""
    role: MessageRole
    content: Optional[str] = Field(
        None,
        description="消息内容，tool角色时可能为None"
    )
    name: Optional[str] = Field(None, description="发送者名称")
    tool_calls: Optional[List[dict]] = None
    tool_call_id: Optional[str] = None
    
    class Config:
        # 允许从ORM对象创建
        orm_mode = True
        # 额外字段拒绝（防止拼写错误）
        extra = "forbid"
        # 示例值（用于文档）
        schema_extra = {
            "example": {
                "role": "user",
                "content": "Hello!"
            }
        }

class ToolFunction(BaseModel):
    """工具函数定义（OpenAI格式）"""
    name: str = Field(..., min_length=1, max_length=64)
    description: str = Field(..., min_length=1, max_length=1024)
    parameters: dict = Field(default_factory=dict)
    
    @validator("name")
    def name_must_be_valid(cls, v):
        if not v.replace("_", "").isalnum():
            raise ValueError("Tool name must be alphanumeric with underscores")
        return v

class AgentOutput(BaseModel):
    """
    Agent的结构化输出。
    这是连接LLM非确定性输出与程序确定性逻辑的关键桥梁。
    """
    thought: str = Field(
        ...,
        description="Agent的逐步思考过程",
        min_length=1
    )
    action: Optional[str] = Field(
        None,
        description="选择的动作：tool_call 或 final_answer"
    )
    tool_name: Optional[str] = Field(None, description="要调用的工具名")
    tool_input: Optional[Json] = Field(None, description="工具参数（JSON对象）")
    final_answer: Optional[str] = Field(None, description="最终答案")
    confidence: confloat(ge=0.0, le=1.0) = Field(
        0.8,
        description="Agent对答案的置信度"
    )
    
    @root_validator
    def check_action_or_answer(cls, values):
        """验证：必须有action或final_answer之一"""
        action = values.get("action")
        final = values.get("final_answer")
        
        if action == "final_answer" and not final:
            raise ValueError("final_answer action requires final_answer field")
        
        if action == "tool_call":
            if not values.get("tool_name"):
                raise ValueError("tool_call action requires tool_name")
            if values.get("tool_input") is None:
                values["tool_input"] = {}
        
        return values
    
    @validator("thought")
    def thought_must_not_be_empty(cls, v):
        if not v.strip():
            raise ValueError("thought cannot be empty")
        return v

# 从LLM输出安全解析
raw_llm_output = '''
{
    "thought": "用户询问北京天气，我需要查询天气工具",
    "action": "tool_call",
    "tool_name": "weather_query",
    "tool_input": {"city": "北京", "date": "today"},
    "confidence": 0.95
}
'''

try:
    parsed = AgentOutput.parse_raw(raw_llm_output)
    print(f"✅ 解析成功: {parsed.tool_name}({parsed.tool_input})")
except Exception as e:
    print(f"❌ 解析失败: {e}")

# 生成JSON Schema（可用于OpenAI function calling）
print("\n生成的Schema:")
import json
print(json.dumps(AgentOutput.schema(), indent=2, ensure_ascii=False))
```

---

## 第3章 异步编程：Agent高并发的核心

### 3.1 为什么Agent必须掌握asyncio

#### 3.1.1 Agent系统的并发场景

一个典型的Agent请求涉及大量的IO等待：

```
用户请求 ──► Agent思考（调用LLM）──► 等待 2-5s
                │
                ▼
            调用工具A（搜索）──► 等待 1-3s
                │
                ▼
            Agent再思考（调用LLM）──► 等待 2-5s
                │
                ▼
            调用工具B（数据库）──► 等待 0.5-2s
                │
                ▼
            Agent最终回答（调用LLM）──► 等待 2-5s
                │
                ▼
            返回给用户

总耗时（同步串行）: 7.5-20s
总耗时（异步优化）: max(2-5, 1-3, 0.5-2) + 2-5 ≈ 5-8s
```

Agent系统的核心瓶颈不是CPU计算，而是**IO等待**。这正是asyncio的甜点。

#### 3.1.2 同步 vs 异步的直观对比

```python
import time
import asyncio

# ===== 同步方式：串行执行，总耗时 = 各步骤之和 =====
def sync_agent_workflow(query: str):
    """同步Agent工作流：每步阻塞等待"""
    start = time.time()
    
    # 步骤1：LLM思考
    time.sleep(2)  # 模拟LLM调用
    print(f"[{time.time()-start:.1f}s] LLM思考完成")
    
    # 步骤2：工具A
    time.sleep(1)  # 模拟工具调用
    print(f"[{time.time()-start:.1f}s] 工具A完成")
    
    # 步骤3：LLM再思考
    time.sleep(2)
    print(f"[{time.time()-start:.1f}s] LLM再思考完成")
    
    # 步骤4：工具B
    time.sleep(0.5)
    print(f"[{time.time()-start:.1f}s] 工具B完成")
    
    # 步骤5：最终回答
    time.sleep(1.5)
    print(f"[{time.time()-start:.1f}s] 最终回答完成")
    
    return f"[{time.time()-start:.1f}s] 完成"

# sync_agent_workflow("test")

# ===== 异步方式：非阻塞，事件循环调度 =====
async def async_llm_call(prompt: str, delay: float) -> str:
    """模拟异步LLM调用"""
    await asyncio.sleep(delay)
    return f"LLM response for: {prompt}"

async def async_tool_call(tool_name: str, delay: float) -> str:
    """模拟异步工具调用"""
    await asyncio.sleep(delay)
    return f"Tool {tool_name} result"

async def async_agent_workflow(query: str):
    """异步Agent工作流：IO等待时让出控制权"""
    start = time.time()
    
    # 步骤1：LLM思考
    thought = await async_llm_call(f"思考: {query}", 2)
    print(f"[{time.time()-start:.1f}s] {thought}")
    
    # 步骤2&3：如果工具间无依赖，可以并行
    tool_a_task = asyncio.create_task(async_tool_call("search", 1))
    tool_b_task = asyncio.create_task(async_tool_call("db_query", 0.5))
    
    # 等待两者都完成
    results = await asyncio.gather(tool_a_task, tool_b_task)
    print(f"[{time.time()-start:.1f}s] 工具结果: {results}")
    
    # 步骤4：最终LLM调用
    answer = await async_llm_call("生成回答", 1.5)
    print(f"[{time.time()-start:.1f}s] {answer}")
    
    return f"[{time.time()-start:.1f}s] 完成"

# asyncio.run(async_agent_workflow("test"))
```

### 3.2 async/await核心机制

#### 3.2.1 事件循环的本质

```python
import asyncio

# 事件循环是asyncio的心脏
loop = asyncio.new_event_loop()
asyncio.set_event_loop(loop)

"""
事件循环的核心逻辑（简化版）：

while 还有任务:
    1. 从就绪队列取出一个任务
    2. 运行该任务直到遇到await
    3. 任务挂起，控制权交还事件循环
    4. 检查是否有IO完成/超时/新事件
    5. 将完成的任务唤醒，放入就绪队列
    6. 回到步骤1

关键概念：
- Task（任务）：对coroutine的包装，调度执行单元
- Future（未来）：表示异步操作最终结果的对象
- Handle（句柄）：回调函数的包装，用于延迟执行
"""

async def demonstrate_event_loop():
    """展示事件循环如何调度任务"""
    
    async def task(name: str, delay: float):
        print(f"  [{name}] 开始")
        await asyncio.sleep(delay)
        print(f"  [{name}] 完成 (等待了{delay}s)")
        return f"{name}_result"
    
    print("创建任务（此时不执行）:")
    t1 = asyncio.create_task(task("A", 0.3))
    t2 = asyncio.create_task(task("B", 0.2))
    t3 = asyncio.create_task(task("C", 0.1))
    print("  3个任务已创建\n")
    
    print("等待所有任务完成:")
    results = await asyncio.gather(t1, t2, t3)
    print(f"\n结果: {results}")
    # 输出顺序：C(0.1s) → B(0.2s) → A(0.3s)
    # 证明它们是并发执行的，不是串行

demonstrate_event_loop()
# asyncio.run(demonstrate_event_loop())
```

#### 3.2.2 并发原语：Semaphore、Lock、Queue

```python
import asyncio
from typing import Any

class RateLimitedLLMClient:
    """
    带速率限制的LLM客户端。
    
    为什么需要这个？
    - OpenAI等API有RPM（Requests Per Minute）限制
    - 并发太高会导致429错误
    - 需要排队和退避机制
    """
    
    def __init__(
        self,
        max_concurrent: int = 5,
        max_per_minute: int = 60,
        provider: str = "openai"
    ):
        self.provider = provider
        # 信号量：控制同时进行的请求数
        self.concurrency_sem = asyncio.Semaphore(max_concurrent)
        # 限流桶：控制每分钟请求数
        self.rate_bucket = asyncio.Semaphore(max_per_minute)
        self.max_per_minute = max_per_minute
        self.request_times: list[float] = []
        self._rate_lock = asyncio.Lock()
    
    async def _acquire_rate(self):
        """获取速率限制许可"""
        async with self._rate_lock:
            now = asyncio.get_event_loop().time()
            # 清理60秒前的记录
            cutoff = now - 60
            self.request_times = [t for t in self.request_times if t > cutoff]
            
            if len(self.request_times) >= self.max_per_minute:
                # 需要等待
                oldest = min(self.request_times)
                wait_time = 60 - (now - oldest) + 0.1
                print(f"  [RateLimit] 等待 {wait_time:.1f}s")
                await asyncio.sleep(wait_time)
            
            self.request_times.append(now)
    
    async def call(self, prompt: str, timeout: float = 30.0) -> str:
        """执行限流的LLM调用"""
        async with self.concurrency_sem:
            await self._acquire_rate()
            
            # 实际调用（模拟）
            print(f"  [LLM] 调用: {prompt[:30]}...")
            await asyncio.sleep(0.5)
            return f"Response for: {prompt[:20]}"

# 测试并发限制
async def test_rate_limit():
    client = RateLimitedLLMClient(max_concurrent=2, max_per_minute=5)
    
    # 发起10个并发请求
    tasks = [client.call(f"Prompt {i}") for i in range(10)]
    results = await asyncio.gather(*tasks)
    print(f"\n完成 {len(results)} 个请求")

# asyncio.run(test_rate_limit())
```

### 3.3 异步HTTP客户端与连接管理

```python
import aiohttp
import asyncio
from typing import Any, Optional
from dataclasses import dataclass

@dataclass
class HttpResponse:
    status: int
    data: Any
    headers: dict
    latency_ms: float

class AsyncHttpClient:
    """
    Agent专用的异步HTTP客户端。
    
    特性：
    - 连接池复用
    - 自动重试（指数退避 + 抖动）
    - 请求/响应拦截
    - 超时精细控制
    """
    
    def __init__(
        self,
        max_connections: int = 100,
        max_connections_per_host: int = 10,
        timeout: float = 30.0,
        retries: int = 3,
        retry_statuses: tuple = (500, 502, 503, 504),
    ):
        self.timeout = aiohttp.ClientTimeout(
            total=timeout,
            connect=5.0,
            sock_read=timeout - 5.0
        )
        self.connector = aiohttp.TCPConnector(
            limit=max_connections,
            limit_per_host=max_connections_per_host,
            enable_cleanup_closed=True,
            force_close=False,  # 保持连接复用
            ttl_dns_cache=300,
        )
        self.session: Optional[aiohttp.ClientSession] = None
        self.retries = retries
        self.retry_statuses = retry_statuses
        self._request_count = 0
        self._error_count = 0
    
    async def __aenter__(self):
        self.session = aiohttp.ClientSession(
            connector=self.connector,
            timeout=self.timeout,
            headers={"Accept": "application/json"},
        )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()
        await self.connector.close()
    
    async def request(
        self,
        method: str,
        url: str,
        retries: Optional[int] = None,
        **kwargs
    ) -> HttpResponse:
        """
        执行HTTP请求，自动重试。
        
        重试策略：
        - 指数退避：2^attempt 秒
        - 抖动：增加随机性避免惊群
        - 只重试幂等操作（GET/PUT/DELETE）和特定状态码
        """
        max_attempts = retries or self.retries
        import random
        import time
        
        for attempt in range(max_attempts):
            start = time.time()
            try:
                async with self.session.request(method, url, **kwargs) as resp:
                    latency = (time.time() - start) * 1000
                    self._request_count += 1
                    
                    # 检查是否需要重试
                    if resp.status in self.retry_statuses and attempt < max_attempts - 1:
                        wait = (2 ** attempt) + random.uniform(0, 1)
                        print(f"  [Retry] {method} {url} 状态{resp.status}, {attempt+1}/{max_attempts} 后等待{wait:.1f}s")
                        await asyncio.sleep(wait)
                        continue
                    
                    resp.raise_for_status()
                    
                    # 解析响应
                    content_type = resp.headers.get("Content-Type", "")
                    if "application/json" in content_type:
                        data = await resp.json()
                    else:
                        data = await resp.text()
                    
                    return HttpResponse(
                        status=resp.status,
                        data=data,
                        headers=dict(resp.headers),
                        latency_ms=latency
                    )
                    
            except aiohttp.ClientError as e:
                self._error_count += 1
                if attempt < max_attempts - 1:
                    wait = (2 ** attempt) + random.uniform(0, 1)
                    await asyncio.sleep(wait)
                else:
                    raise
    
    async def get(self, url: str, **kwargs) -> HttpResponse:
        return await self.request("GET", url, **kwargs)
    
    async def post(self, url: str, **kwargs) -> HttpResponse:
        return await self.request("POST", url, **kwargs)
    
    @property
    def stats(self) -> dict:
        return {
            "requests": self._request_count,
            "errors": self._error_count,
            "error_rate": self._error_count / max(self._request_count, 1),
        }

# 使用示例
async def demo_http_client():
    async with AsyncHttpClient(max_connections=20) as client:
        resp = await client.get("https://httpbin.org/get")
        print(f"Status: {resp.status}, Latency: {resp.latency_ms:.0f}ms")
        print(f"Stats: {client.stats}")

# asyncio.run(demo_http_client())
```

### 3.4 实战：构建异步Agent执行引擎

```python
import asyncio
from dataclasses import dataclass, field
from typing import Callable, Any, Coroutine, Optional
from datetime import datetime
import time

@dataclass
class TaskResult:
    task_id: str
    status: str  # success / failed / timeout / cancelled
    result: Any = None
    error: Optional[str] = None
    duration_ms: float = 0.0
    retries: int = 0

@dataclass
class ExecutionMetrics:
    total_tasks: int = 0
    successful: int = 0
    failed: int = 0
    timeouts: int = 0
    total_duration_ms: float = 0.0
    avg_duration_ms: float = 0.0

class AsyncAgentExecutor:
    """
    生产级异步Agent执行引擎。
    
    核心能力：
    1. 并发工具调用控制（防止资源耗尽）
    2. 任务超时和取消
    3. 指数退避重试
    4. 执行链路追踪
    5. 竞速执行（race mode）
    """
    
    def __init__(
        self,
        max_workers: int = 10,
        default_timeout: float = 30.0,
        max_retries: int = 3,
    ):
        self.max_workers = max_workers
        self.default_timeout = default_timeout
        self.max_retries = max_retries
        self.tool_registry: dict[str, Callable] = {}
        self.execution_log: list[dict] = field(default_factory=list)
        self.metrics = ExecutionMetrics()
    
    def register_tool(self, name: str, func: Callable):
        """注册工具函数"""
        self.tool_registry[name] = func
    
    async def execute_tool(
        self,
        tool_name: str,
        params: dict,
        task_id: str,
        timeout: Optional[float] = None,
        retries: Optional[int] = None,
    ) -> TaskResult:
        """
        执行单个工具调用，带超时、重试和错误处理。
        """
        timeout = timeout or self.default_timeout
        retries = retries or self.max_retries
        tool = self.tool_registry.get(tool_name)
        
        if not tool:
            return TaskResult(
                task_id=task_id,
                status="failed",
                error=f"Tool '{tool_name}' not found in registry"
            )
        
        start = time.time()
        last_error = None
        
        for attempt in range(retries):
            try:
                if asyncio.iscoroutinefunction(tool):
                    # 异步函数：直接await，带超时
                    result = await asyncio.wait_for(
                        tool(**params),
                        timeout=timeout
                    )
                else:
                    # 同步函数：在线程池中执行，避免阻塞事件循环
                    loop = asyncio.get_event_loop()
                    result = await asyncio.wait_for(
                        loop.run_in_executor(None, lambda: tool(**params)),
                        timeout=timeout
                    )
                
                duration = (time.time() - start) * 1000
                
                # 记录成功日志
                self.execution_log.append({
                    "task_id": task_id,
                    "tool": tool_name,
                    "status": "success",
                    "duration_ms": duration,
                    "attempt": attempt + 1,
                    "timestamp": datetime.now().isoformat(),
                })
                
                self.metrics.successful += 1
                
                return TaskResult(
                    task_id=task_id,
                    status="success",
                    result=result,
                    duration_ms=duration,
                    retries=attempt
                )
                
            except asyncio.TimeoutError:
                last_error = f"Timeout after {timeout}s"
                wait = 2 ** attempt
                await asyncio.sleep(wait)
                
            except Exception as e:
                last_error = str(e)
                wait = 2 ** attempt + 0.5
                await asyncio.sleep(wait)
        
        # 所有重试都失败了
        duration = (time.time() - start) * 1000
        self.execution_log.append({
            "task_id": task_id,
            "tool": tool_name,
            "status": "failed",
            "error": last_error,
            "duration_ms": duration,
            "timestamp": datetime.now().isoformat(),
        })
        self.metrics.failed += 1
        
        return TaskResult(
            task_id=task_id,
            status="failed",
            error=f"All {retries} attempts failed. Last: {last_error}",
            duration_ms=duration,
            retries=retries
        )
    
    async def execute_parallel(
        self,
        tasks: list[tuple[str, dict, str]],
        timeout: Optional[float] = None,
    ) -> list[TaskResult]:
        """
        并行执行多个工具调用。
        
        Args:
            tasks: [(tool_name, params, task_id), ...]
            timeout: 每个任务的超时时间
        
        Returns:
            每个任务的执行结果
        """
        semaphore = asyncio.Semaphore(self.max_workers)
        
        async def bounded_execute(tool, params, tid):
            async with semaphore:
                return await self.execute_tool(tool, params, tid, timeout)
        
        coros = [
            bounded_execute(tool, params, tid)
            for tool, params, tid in tasks
        ]
        
        return await asyncio.gather(*coros)
    
    async def execute_race(
        self,
        tasks: list[tuple[str, dict, str]],
        timeout: Optional[float] = None,
    ) -> TaskResult:
        """
        竞速模式：多个Agent策略同时执行，取最快成功的结果。
        
        应用场景：
        - 多个检索策略并行，取最快返回的结果
        - 多个模型并行生成，取最快完成的回答
        - 主路径 + 快速fallback路径
        """
        semaphore = asyncio.Semaphore(self.max_workers)
        
        async def bounded_execute(tool, params, tid):
            async with semaphore:
                return await self.execute_tool(tool, params, tid, timeout)
        
        # 创建任务
        pending = {
            asyncio.create_task(bounded_execute(t[0], t[1], t[2]))
            for t in tasks
        }
        
        while pending:
            # 等待第一个完成的任务
            done, pending = await asyncio.wait(
                pending,
                return_when=asyncio.FIRST_COMPLETED
            )
            
            for task in done:
                result = task.result()
                if result.status == "success":
                    # 取消剩余任务
                    for t in pending:
                        t.cancel()
                    return result
        
        # 所有任务都失败了
        return TaskResult(
            task_id="race",
            status="failed",
            error="All race tasks failed"
        )
    
    def get_metrics(self) -> ExecutionMetrics:
        total = self.metrics.successful + self.metrics.failed
        self.metrics.total_tasks = total
        self.metrics.avg_duration_ms = (
            self.metrics.total_duration_ms / max(total, 1)
        )
        return self.metrics


# ===== 完整测试 =====
async def test_executor():
    executor = AsyncAgentExecutor(max_workers=3)
    
    # 注册测试工具
    async def fast_tool(x: str):
        await asyncio.sleep(0.1)
        return f"fast:{x}"
    
    async def slow_tool(x: str):
        await asyncio.sleep(0.5)
        return f"slow:{x}"
    
    async def error_tool(x: str):
        await asyncio.sleep(0.05)
        raise ValueError("模拟错误")
    
    executor.register_tool("fast", fast_tool)
    executor.register_tool("slow", slow_tool)
    executor.register_tool("error", error_tool)
    
    print("=== 测试1：并行执行 ===")
    tasks = [
        ("fast", {"x": "a"}, "task_1"),
        ("slow", {"x": "b"}, "task_2"),
        ("fast", {"x": "c"}, "task_3"),
        ("error", {"x": "d"}, "task_4"),
    ]
    
    results = await executor.execute_parallel(tasks)
    for r in results:
        print(f"  {r.task_id}: {r.status} -> {r.result or r.error}")
    
    print("\n=== 测试2：竞速执行 ===")
    race_tasks = [
        ("slow", {"x": "slow"}, "race_1"),
        ("fast", {"x": "fast"}, "race_2"),
    ]
    winner = await executor.execute_race(race_tasks)
    print(f"  获胜者: {winner.task_id} -> {winner.result}")

# 运行测试
asyncio.run(test_executor())
```

---

## 第4章 类型系统与代码质量

### 4.1 TypeHints与静态类型检查

Python的动态类型带来了灵活性，但在Agent这种复杂系统中，类型错误可能导致严重的后果——比如LLM输出的JSON字段名拼写错误，导致后续所有处理逻辑崩溃。

```python
from typing import (
    TypedDict, Literal, Union, Optional, NotRequired,
    Protocol, TypeVar, Generic, Callable, Coroutine,
    Any, cast
)

# ===== TypedDict：为字典赋予精确类型 =====

class ChatMessageTD(TypedDict):
    """使用TypedDict定义消息结构"""
    role: Literal["system", "user", "assistant", "tool"]
    content: str
    name: NotRequired[str]  # Python 3.11+，可选字段
    tool_calls: NotRequired[list[dict]]

# 错误检测
def process_message(msg: ChatMessageTD) -> str:
    role = msg["role"]  # ✅ 类型安全
    # typo = msg["rolle"]  # ❌ mypy会报错：TypedDict "ChatMessageTD" has no key "rolle"
    return msg["content"]

# ===== Union / Optional =====

AgentOutput = Union[str, dict, list[dict]]  # Agent输出可能是多种类型

def handle_output(output: AgentOutput) -> str:
    if isinstance(output, str):
        return output
    elif isinstance(output, dict):
        return output.get("content", "")
    else:
        return "\n".join(str(item) for item in output)

# ===== 函数类型签名 =====

# 工具函数的签名
ToolFunction = Callable[..., Any]
AsyncToolFunction = Callable[..., Coroutine[Any, Any, Any]]

# Agent推理函数的签名
AgentThinker = Callable[
    [list[ChatMessageTD]],  # 输入：消息历史
    Coroutine[Any, Any, str]  # 输出：协程返回字符串
]

# ===== 类型守卫（Type Guard） =====

from typing import TypeGuard

def is_tool_message(msg: ChatMessageTD) -> TypeGuard[ChatMessageTD]:
    """类型守卫函数：narrowing类型"""
    return msg.get("role") == "tool"

def process_messages(messages: list[ChatMessageTD]):
    for msg in messages:
        if is_tool_message(msg):
            # 在这个分支里，mypy知道msg是tool消息
            print(f"Tool result: {msg['content']}")
        else:
            print(f"Regular message: {msg['content']}")
```

### 4.2 Protocol：结构化子类型

```python
from typing import Protocol, runtime_checkable

@runtime_checkable
class LLMProvider(Protocol):
    """
    LLM提供商协议。
    
    任何实现了name、supports_tools和chat方法的类，
    无论是否显式继承LLMProvider，都被认为是LLMProvider。
    """
    name: str
    supports_tools: bool
    
    async def chat(
        self,
        messages: list[dict],
        temperature: float = 0.7,
        max_tokens: int = 1000
    ) -> str:
        ...

# 实现1：OpenAI
class OpenAIProvider:
    name = "openai"
    supports_tools = True
    
    async def chat(self, messages, temperature=0.7, max_tokens=1000):
        # 实际实现...
        return "OpenAI response"

# 实现2：本地Ollama
class OllamaProvider:
    name = "ollama"
    supports_tools = False
    
    async def chat(self, messages, temperature=0.7, max_tokens=1000):
        return "Ollama response"

# 使用：任何符合协议的对象都可以传入
async def use_provider(provider: LLMProvider, query: str):
    print(f"Using provider: {provider.name}")
    response = await provider.chat([{"role": "user", "content": query}])
    return response

# 两者都可以传入，无需继承关系
# asyncio.run(use_provider(OpenAIProvider(), "hello"))
# asyncio.run(use_provider(OllamaProvider(), "hello"))
```

### 4.3 Generic：泛型与类型参数化

```python
from typing import TypeVar, Generic, Type

T = TypeVar("T")  # 任意类型
K = TypeVar("K", str, int)  # 受限类型
Comparable = TypeVar("Comparable", bound=int)  # 有上界

class MemoryStore(Generic[T]):
    """
    类型安全的记忆存储。
    
    泛型参数T在实例化时确定，编译期即可发现类型错误。
    """
    
    def __init__(self, max_size: int = 1000):
        self._items: list[T] = []
        self._max_size = max_size
    
    def add(self, item: T) -> None:
        self._items.append(item)
        if len(self._items) > self._max_size:
            self._items.pop(0)  # FIFO淘汰
    
    def get_recent(self, n: int) -> list[T]:
        return self._items[-n:]
    
    def find(self, predicate: Callable[[T], bool]) -> Optional[T]:
        for item in reversed(self._items):
            if predicate(item):
                return item
        return None

# 使用：消息存储
message_store: MemoryStore[ChatMessageTD] = MemoryStore(max_size=100)
message_store.add({"role": "user", "content": "hi"})  # ✅
# message_store.add("invalid")  # ❌ mypy报错

# 使用：向量存储
from dataclasses import dataclass

@dataclass
class VectorRecord:
    id: str
    embedding: list[float]
    text: str

vector_store: MemoryStore[VectorRecord] = MemoryStore()
```

### 4.4 Pydantic深度实践

```python
from pydantic import (
    BaseModel, Field, validator, root_validator,
    field_validator, model_validator,  # V2风格
    ConfigDict,
)
from typing import Literal, Annotated
from datetime import datetime

class ToolCallV2(BaseModel):
    """Pydantic V2风格的工具调用模型"""
    model_config = ConfigDict(
        frozen=True,  # 不可变
        str_strip_whitespace=True,
        validate_assignment=True,
    )
    
    id: str = Field(pattern=r"^call_[a-zA-Z0-9]+$")
    type: Literal["function"] = "function"
    name: str = Field(min_length=1, max_length=64)
    arguments: str = Field(description="JSON字符串格式的参数")
    
    @field_validator("arguments")
    @classmethod
    def validate_json(cls, v: str) -> str:
        import json
        try:
            parsed = json.loads(v)
            if not isinstance(parsed, dict):
                raise ValueError("arguments must be a JSON object")
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON: {e}")
        return v
    
    def parsed_args(self) -> dict:
        import json
        return json.loads(self.arguments)

class ReActStepV2(BaseModel):
    """ReAct执行步骤（Pydantic V2）"""
    model_config = ConfigDict(
        extra="forbid",
        json_schema_extra={
            "example": {
                "thought": "我需要搜索信息",
                "action": "search",
                "action_input": {"query": "Python asyncio"}
            }
        }
    )
    
    thought: str = Field(min_length=1)
    action: str = Field(min_length=1)
    action_input: dict = Field(default_factory=dict)
    observation: str = ""
    
    @model_validator(mode="after")
    def check_consistency(self):
        if self.action == "finish" and not self.observation:
            self.observation = "Task completed"
        return self

# 使用
step = ReActStepV2(
    thought="用户询问天气",
    action="weather_query",
    action_input={"city": "北京"}
)
print(step.model_dump_json(indent=2))

# 从LLM输出解析（容错模式）
raw = '{"thought": "test", "action": "test", "extra_field": "ignored"}'
try:
    # extra="forbid"会报错
    step_bad = ReActStepV2.model_validate_json(raw)
except Exception as e:
    print(f"验证失败: {e}")
```

---

## 第5章 函数式编程与数据处理

### 5.1 高阶函数与数据处理管道

Agent经常需要处理消息流：过滤、映射、聚合。

```python
from functools import reduce, partial
from operator import itemgetter, attrgetter
import itertools

messages = [
    {"role": "system", "content": "You are helpful", "tokens": 15},
    {"role": "user", "content": "Hello", "tokens": 5},
    {"role": "assistant", "content": "Hi there!", "tokens": 8},
    {"role": "user", "content": "How are you?", "tokens": 7},
    {"role": "tool", "content": '{"result": "ok"}', "tokens": 12},
]

# 过滤 + 映射 + 聚合管道
pipeline = (
    msg for msg in messages
    if msg["role"] in ("user", "assistant")
)

contents = (msg["content"] for msg in pipeline)
total_tokens = sum(msg["tokens"] for msg in messages)

# functools.partial：预绑定参数
from typing import Callable

def format_message(role: str, content: str, prefix: str = "") -> str:
    return f"{prefix}[{role.upper()}] {content}"

format_user = partial(format_message, prefix=">> ")
format_system = partial(format_message, prefix="!! ")

print(format_user("user", "Hello"))
print(format_system("system", "Be helpful"))

# itertools：高效迭代工具
from itertools import chain, groupby, islice

# chain：合并多个消息源
history_a = [{"role": "user", "content": "Q1"}]
history_b = [{"role": "assistant", "content": "A1"}]
merged = list(chain(history_a, history_b))

# groupby：按角色分组消息（需先排序）
sorted_msgs = sorted(messages, key=itemgetter("role"))
for role, group in groupby(sorted_msgs, key=itemgetter("role")):
    count = len(list(group))
    print(f"{role}: {count} messages")

# islice：取最近N条（不创建副本）
recent = list(islice(
    (m for m in messages if m["role"] != "system"),
    10
))
```

### 5.2 不可变数据与状态管理

Agent的状态管理是bug的高发区。不可变数据可以减少意外修改。

```python
from dataclasses import dataclass, replace
from typing import Tuple

@dataclass(frozen=True)
class AgentState:
    """不可变的Agent状态"""
    messages: Tuple[dict, ...] = ()
    iteration: int = 0
    total_tokens: int = 0
    
    def with_message(self, msg: dict) -> "AgentState":
        """返回添加消息后的新状态（不修改原状态）"""
        return replace(self, messages=self.messages + (msg,))
    
    def with_iteration(self, n: int) -> "AgentState":
        return replace(self, iteration=n)
    
    def with_tokens(self, tokens: int) -> "AgentState":
        return replace(self, total_tokens=self.total_tokens + tokens)

# 使用：状态转换
state = AgentState()
state = state.with_message({"role": "user", "content": "hi"})
state = state.with_iteration(1)
state = state.with_tokens(50)

print(state)
```

---

## 第6章 测试驱动开发与工程化

### 6.1 pytest与异步测试

```python
# test_agent.py
import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

@pytest.mark.asyncio
async def test_agent_thinking():
    """测试Agent思考逻辑"""
    from agent import SimpleAgent
    
    mock_llm = AsyncMock()
    mock_llm.return_value = '{"thought": "test", "action": "finish", "final_answer": "done"}'
    
    agent = SimpleAgent(llm=mock_llm)
    result = await agent.run("hello")
    
    assert result == "done"
    mock_llm.assert_called_once()

@pytest.fixture
async def mock_tool_registry():
    """Fixture：提供测试用的工具注册表"""
    registry = AgentToolRegistry()
    registry.register_tool("mock_search", lambda q: ["result"])
    return registry

# 参数化测试
@pytest.mark.parametrize("query,expected_tool", [
    ("天气怎么样", "weather_query"),
    ("2+2等于几", "calculate"),
    ("搜索新闻", "web_search"),
])
def test_intent_classification(query, expected_tool):
    classifier = IntentClassifier()
    result = classifier.classify(query)
    assert result == expected_tool
```

### 6.2 Mock外部依赖

```python
from unittest.mock import patch, MagicMock
import responses  # 用于mock HTTP请求

# Mock LLM API调用
@patch("openai.AsyncOpenAI.chat.completions.create")
async def test_with_mocked_openai(mock_create):
    mock_create.return_value = MagicMock(
        choices=[MagicMock(message=MagicMock(content='{"action": "finish"}'))]
    )
    
    result = await my_agent.run("test")
    assert result is not None

# Mock HTTP请求（工具调用）
@responses.activate
def test_web_search_tool():
    responses.add(
        responses.GET,
        "https://api.search.com/query",
        json={"results": [{"title": "Test"}]},
        status=200
    )
    
    tool = WebSearchTool()
    result = tool.execute(query="test")
    assert len(result) == 1

# 使用vcrpy录制/回放真实请求
import vcr

my_vcr = vcr.VCR(cassette_library_dir="tests/cassettes/")

@my_vcr.use_cassette("test_llm_call.yaml")
def test_with_recorded_response():
    # 第一次运行时发送真实请求并录制
    # 后续运行时使用录制的响应
    result = call_llm("test prompt")
    assert "expected" in result
```

### 6.3 项目结构最佳实践

```
agent_project/
├── pyproject.toml           # 项目配置（Poetry/PDM）
├── Makefile                 # 常用命令
├── README.md
├── .env.example             # 环境变量示例
├── src/
│   └── my_agent/
│       ├── __init__.py
│       ├── core/
│       │   ├── __init__.py
│       │   ├── agent.py      # Agent核心逻辑
│       │   ├── state.py      # 状态管理
│       │   └── executor.py   # 执行引擎
│       ├── models/
│       │   ├── __init__.py
│       │   ├── schemas.py    # Pydantic模型
│       │   └── messages.py   # 消息类型
│       ├── tools/
│       │   ├── __init__.py
│       │   ├── registry.py   # 工具注册
│       │   ├── base.py       # 工具基类
│       │   ├── search.py     # 搜索工具
│       │   └── calc.py       # 计算工具
│       ├── memory/
│       │   ├── __init__.py
│       │   ├── base.py
│       │   ├── buffer.py
│       │   └── vector.py
│       ├── providers/
│       │   ├── __init__.py
│       │   ├── base.py
│       │   ├── openai.py
│       │   └── anthropic.py
│       └── utils/
│           ├── __init__.py
│           ├── async_utils.py
│           └── validators.py
├── tests/
│   ├── __init__.py
│   ├── conftest.py           # pytest fixtures
│   ├── unit/
│   │   ├── test_agent.py
│   │   ├── test_tools.py
│   │   └── test_memory.py
│   ├── integration/
│   │   └── test_end_to_end.py
│   └── fixtures/
│       └── sample_data.json
└── scripts/
    └── benchmark.py
```

---

## 第7章 Python与LLM SDK集成

### 7.1 统一LLM客户端封装

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import AsyncIterator, Optional
import asyncio

@dataclass
class LLMResponse:
    content: str
    model: str
    input_tokens: int
    output_tokens: int
    finish_reason: Optional[str] = None

class BaseLLMProvider(ABC):
    """统一的LLM提供商抽象基类"""
    
    @property
    @abstractmethod
    def name(self) -> str:
        pass
    
    @property
    @abstractmethod
    def supports_tools(self) -> bool:
        pass
    
    @abstractmethod
    async def chat(
        self,
        messages: list[dict],
        temperature: float = 0.7,
        max_tokens: int = 1000,
        tools: Optional[list[dict]] = None,
    ) -> LLMResponse:
        pass
    
    @abstractmethod
    async def stream_chat(
        self,
        messages: list[dict],
        temperature: float = 0.7,
        max_tokens: int = 1000,
    ) -> AsyncIterator[str]:
        pass

class OpenAIProvider(BaseLLMProvider):
    def __init__(self, api_key: str, model: str = "gpt-4o"):
        from openai import AsyncOpenAI
        self.client = AsyncOpenAI(api_key=api_key)
        self.model = model
    
    @property
    def name(self) -> str:
        return f"openai:{self.model}"
    
    @property
    def supports_tools(self) -> bool:
        return True
    
    async def chat(self, messages, temperature=0.7, max_tokens=1000, tools=None):
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            tools=tools,
        )
        
        choice = response.choices[0]
        return LLMResponse(
            content=choice.message.content or "",
            model=self.model,
            input_tokens=response.usage.prompt_tokens,
            output_tokens=response.usage.completion_tokens,
            finish_reason=choice.finish_reason,
        )
    
    async def stream_chat(self, messages, temperature=0.7, max_tokens=1000):
        stream = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            stream=True,
        )
        async for chunk in stream:
            if chunk.choices[0].delta.content:
                yield chunk.choices[0].delta.content

# 使用
async def demo_provider():
    # provider = OpenAIProvider("your-key")
    # response = await provider.chat([{"role": "user", "content": "hello"}])
    # print(response)
    pass

# asyncio.run(demo_provider())
```

### 7.2 自动重试与容错

```python
import asyncio
import random
from functools import wraps

def retry_with_backoff(
    max_retries: int = 3,
    base_delay: float = 1.0,
    max_delay: float = 60.0,
    exceptions: tuple = (Exception,),
    on_retry: Optional[Callable] = None,
):
    """
    装饰器：指数退避重试 + 抖动。
    
    公式：delay = min(base_delay * 2^attempt + random jitter, max_delay)
    """
    def decorator(func):
        @wraps(func)
        async def async_wrapper(*args, **kwargs):
            for attempt in range(max_retries):
                try:
                    return await func(*args, **kwargs)
                except exceptions as e:
                    if attempt == max_retries - 1:
                        raise
                    
                    delay = min(
                        base_delay * (2 ** attempt) + random.uniform(0, 1),
                        max_delay
                    )
                    
                    if on_retry:
                        on_retry(attempt, delay, e)
                    
                    await asyncio.sleep(delay)
            
            return None  # 不可达，但类型检查需要
        
        @wraps(func)
        def sync_wrapper(*args, **kwargs):
            # 同步版本...
            return func(*args, **kwargs)
        
        return async_wrapper if asyncio.iscoroutinefunction(func) else sync_wrapper
    return decorator

# 使用
@retry_with_backoff(
    max_retries=3,
    base_delay=2.0,
    exceptions=(ConnectionError, TimeoutError),
    on_retry=lambda attempt, delay, err: print(f"Retry {attempt+1}, wait {delay:.1f}s: {err}")
)
async def call_unstable_api():
    """模拟不稳定的API"""
    if random.random() < 0.7:
        raise ConnectionError("API timeout")
    return "success"

# asyncio.run(call_unstable_api())
```

---

## 本章小结

| 技能点 | Agent应用场景 | 关键API/工具 |
|--------|------------|-------------|
| 生成器/迭代器 | 流式处理LLM输出 | `yield`, `yield from`, 生成器表达式 |
| 装饰器 | 工具注册、横切逻辑 | `@register`, `functools.wraps` |
| 上下文管理器 | 会话生命周期管理 | `__enter__`, `__aenter__`, `@contextmanager` |
| asyncio | 并发工具调用、高并发服务 | `async/await`, `Semaphore`, `gather` |
| TypeHints | 代码可维护性、IDE支持 | `TypedDict`, `Protocol`, `Generic` |
| Pydantic | LLM输出解析、API参数验证 | `BaseModel`, `Field`, `validator` |
| 函数式编程 | 消息管道处理 | `itertools`, `functools.partial` |
| pytest | Agent逻辑测试 | `pytest.mark.asyncio`, `AsyncMock` |
| SDK封装 | 多模型统一接口 | 抽象基类、适配器模式 |

#!/usr/bin/env python3
"""
KubeSphere-Jenkins 角色同步检测与修复 Web 工具

功能：
1. 扫描所有 KubeSphere 用户
2. 检测哪些用户未在 Jenkins 中分配 admin 角色
3. 一键修复缺失的角色分配
4. 支持批量操作和日志记录
"""

import os
import sys
import json
import base64
import asyncio
import logging
from typing import List, Dict, Optional
from dataclasses import dataclass, asdict
from datetime import datetime

import httpx
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse
from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

# 日志配置
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# ============ 配置 ============

JENKINS_HOST = os.getenv("JENKINS_HOST", "http://jenkins.kubesphere-devops-system:8080")
JENKINS_USER = os.getenv("JENKINS_USER", "admin")
JENKINS_PASS = os.getenv("JENKINS_PASS", "")
JENKINS_TIMEOUT = int(os.getenv("JENKINS_TIMEOUT", "30"))

K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "kubesphere-system")
ROLE_NAME = os.getenv("ROLE_NAME", "admin")
ROLE_TYPE = os.getenv("ROLE_TYPE", "globalRoles")

# ============ 数据模型 ============

@dataclass
class UserSyncStatus:
    username: str
    email: str
    display_name: str
    state: str
    has_jenkins_role: bool
    last_login_time: Optional[str] = None
    fixed_at: Optional[str] = None
    error_message: Optional[str] = None


@dataclass
class SyncReport:
    total_users: int
    synced_users: int
    missing_users: int
    checked_at: str
    users: List[Dict]


# ============ K8s 客户端 ============

class K8sClient:
    def __init__(self):
        self._load_config()
        self.custom_api = client.CustomObjectsApi()
        self.core_api = client.CoreV1Api()

    def _load_config(self):
        try:
            config.load_incluster_config()
            logger.info("使用 in-cluster K8s 配置")
        except config.ConfigException:
            try:
                config.load_kube_config()
                logger.info("使用本地 kubeconfig")
            except config.ConfigException:
                logger.error("无法加载 K8s 配置")
                raise

    def list_kubesphere_users(self) -> List[Dict]:
        """获取所有 KubeSphere User CRD"""
        try:
            result = self.custom_api.list_cluster_custom_object(
                group="iam.kubesphere.io",
                version="v1alpha2",
                plural="users"
            )
            users = []
            for item in result.get("items", []):
                metadata = item.get("metadata", {})
                spec = item.get("spec", {})
                status = item.get("status", {})
                users.append({
                    "username": metadata.get("name", ""),
                    "email": spec.get("email", ""),
                    "display_name": metadata.get("annotations", {}).get(
                        "iam.kubesphere.io/display-name", ""
                    ) or metadata.get("name", ""),
                    "state": status.get("state", "Unknown"),
                    "last_login_time": metadata.get("annotations", {}).get(
                        "iam.kubesphere.io/last-login-time", ""
                    ),
                })
            logger.info(f"从 K8s 获取到 {len(users)} 个用户")
            return users
        except ApiException as e:
            logger.error(f"K8s API 调用失败: {e}")
            raise


# ============ Jenkins 客户端 ============

class JenkinsClient:
    def __init__(self):
        self.host = JENKINS_HOST.rstrip("/")
        self.auth = (JENKINS_USER, JENKINS_PASS)
        self.timeout = JENKINS_TIMEOUT

    async def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        """发送 HTTP 请求到 Jenkins"""
        url = f"{self.host}{path}"
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            try:
                response = await client.request(
                    method, url, auth=self.auth, **kwargs
                )
                return response
            except httpx.ConnectError as e:
                logger.error(f"无法连接到 Jenkins: {e}")
                raise HTTPException(status_code=503, detail=f"无法连接到 Jenkins: {e}")
            except httpx.TimeoutException:
                logger.error("Jenkins 请求超时")
                raise HTTPException(status_code=504, detail="Jenkins 请求超时")

    async def get_role_sids(self, role_name: str = ROLE_NAME, role_type: str = ROLE_TYPE) -> List[str]:
        """获取指定角色下的所有 SID（用户名）"""
        path = f"/role-strategy/strategy/getRole?type={role_type}&roleName={role_name}"
        response = await self._request("GET", path)

        if response.status_code == 404:
            logger.warning(f"Role Strategy 插件未启用或角色不存在: {role_name}")
            return []

        if response.status_code != 200:
            logger.error(f"Jenkins API 返回错误: {response.status_code} {response.text}")
            raise HTTPException(
                status_code=502,
                detail=f"Jenkins API 错误: {response.status_code}"
            )

        try:
            data = response.json()
            sids = data.get("sids", [])
            logger.info(f"Jenkins 角色 '{role_name}' 下共有 {len(sids)} 个 SID")
            return sids
        except json.JSONDecodeError:
            logger.error(f"Jenkins 返回非 JSON 响应: {response.text[:200]}")
            raise HTTPException(status_code=502, detail="Jenkins 返回无效响应")

    async def assign_role(self, sid: str, role_name: str = ROLE_NAME, role_type: str = ROLE_TYPE) -> bool:
        """为用户分配 Jenkins 角色"""
        path = "/role-strategy/strategy/assignRole"
        data = {
            "type": role_type,
            "roleName": role_name,
            "sid": sid
        }
        response = await self._request("POST", path, data=data)

        if response.status_code == 200:
            logger.info(f"成功为用户 '{sid}' 分配角色 '{role_name}'")
            return True
        else:
            logger.error(f"为用户 '{sid}' 分配角色失败: {response.status_code} {response.text}")
            return False

    async def unassign_role(self, sid: str, role_name: str = ROLE_NAME, role_type: str = ROLE_TYPE) -> bool:
        """撤销用户的 Jenkins 角色"""
        path = "/role-strategy/strategy/unassignRole"
        data = {
            "type": role_type,
            "roleName": role_name,
            "sid": sid
        }
        response = await self._request("POST", path, data=data)
        return response.status_code == 200

    async def health_check(self) -> Dict:
        """检查 Jenkins 健康状态"""
        try:
            response = await self._request("GET", "/api/json")
            if response.status_code == 200:
                data = response.json()
                return {
                    "healthy": True,
                    "version": data.get("jenkins-version", "unknown"),
                    "mode": data.get("mode", "unknown"),
                }
            return {"healthy": False, "error": f"HTTP {response.status_code}"}
        except Exception as e:
            return {"healthy": False, "error": str(e)}


# ============ 业务逻辑 ============

class SyncService:
    def __init__(self):
        self.k8s = K8sClient()
        self.jenkins = JenkinsClient()
        self.last_report: Optional[SyncReport] = None

    async def scan_users(self) -> SyncReport:
        """扫描所有用户，对比 KubeSphere 和 Jenkins 的角色状态"""
        logger.info("开始扫描用户角色同步状态...")

        # 获取 KubeSphere 用户
        ks_users = self.k8s.list_kubesphere_users()

        # 获取 Jenkins 角色 SID 列表
        jenkins_sids = await self.jenkins.get_role_sids()
        jenkins_sid_set = set(jenkins_sids)

        # 对比
        users_status = []
        synced_count = 0
        missing_count = 0

        for user in ks_users:
            has_role = user["username"] in jenkins_sid_set
            if has_role:
                synced_count += 1
            else:
                missing_count += 1

            users_status.append(UserSyncStatus(
                username=user["username"],
                email=user["email"],
                display_name=user["display_name"],
                state=user["state"],
                has_jenkins_role=has_role,
                last_login_time=user.get("last_login_time") or None,
            ))

        report = SyncReport(
            total_users=len(ks_users),
            synced_users=synced_count,
            missing_users=missing_count,
            checked_at=datetime.now().isoformat(),
            users=[asdict(u) for u in users_status]
        )
        self.last_report = report
        logger.info(f"扫描完成: 总共 {report.total_users} 用户, 已同步 {report.synced_users}, 缺失 {report.missing_users}")
        return report

    async def fix_user(self, username: str) -> Dict:
        """为单个用户修复 Jenkins 角色"""
        logger.info(f"开始修复用户: {username}")

        success = await self.jenkins.assign_role(username)
        result = {
            "username": username,
            "success": success,
            "fixed_at": datetime.now().isoformat() if success else None,
            "message": "修复成功" if success else "修复失败，请检查 Jenkins 状态和日志"
        }

        if success and self.last_report:
            # 更新本地缓存
            for user in self.last_report.users:
                if user["username"] == username:
                    user["has_jenkins_role"] = True
                    user["fixed_at"] = result["fixed_at"]
                    self.last_report.synced_users += 1
                    self.last_report.missing_users -= 1
                    break

        return result

    async def fix_all_missing(self) -> Dict:
        """批量修复所有缺失角色的用户"""
        if self.last_report is None:
            await self.scan_users()

        missing_users = [
            u for u in self.last_report.users
            if not u["has_jenkins_role"]
        ]

        results = []
        success_count = 0
        fail_count = 0

        for user in missing_users:
            result = await self.fix_user(user["username"])
            results.append(result)
            if result["success"]:
                success_count += 1
            else:
                fail_count += 1
            # 短暂延迟，避免压垮 Jenkins
            await asyncio.sleep(0.5)

        return {
            "total": len(missing_users),
            "success": success_count,
            "failed": fail_count,
            "results": results
        }


# ============ FastAPI 应用 ============

app = FastAPI(
    title="KubeSphere-Jenkins 角色同步工具",
    description="检测并修复 KubeSphere 用户在 Jenkins 中的角色同步问题",
    version="1.0.0"
)

sync_service = SyncService()
operation_logs: List[Dict] = []


@app.get("/", response_class=HTMLResponse)
async def index():
    """返回前端页面"""
    return INDEX_HTML


@app.get("/api/health")
async def health():
    """健康检查"""
    jenkins_health = await sync_service.jenkins.health_check()
    return {
        "status": "ok",
        "jenkins": jenkins_health,
        "config": {
            "jenkins_host": JENKINS_HOST,
            "jenkins_user": JENKINS_USER,
            "role_name": ROLE_NAME,
            "role_type": ROLE_TYPE,
        }
    }


@app.get("/api/users")
async def list_users(force_refresh: bool = False):
    """获取所有用户的同步状态"""
    try:
        if force_refresh or sync_service.last_report is None:
            report = await sync_service.scan_users()
        else:
            report = sync_service.last_report
        return asdict(report)
    except Exception as e:
        logger.exception("获取用户列表失败")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/users/{username}/fix")
async def fix_single_user(username: str, background_tasks: BackgroundTasks):
    """修复单个用户的 Jenkins 角色"""
    try:
        result = await sync_service.fix_user(username)
        operation_logs.append({
            "action": "fix_single",
            "username": username,
            "result": result,
            "timestamp": datetime.now().isoformat()
        })
        return result
    except Exception as e:
        logger.exception(f"修复用户 {username} 失败")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/users/fix-all")
async def fix_all_users(background_tasks: BackgroundTasks):
    """批量修复所有缺失角色的用户"""
    try:
        result = await sync_service.fix_all_missing()
        operation_logs.append({
            "action": "fix_all",
            "result": result,
            "timestamp": datetime.now().isoformat()
        })
        return result
    except Exception as e:
        logger.exception("批量修复失败")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/logs")
async def get_logs(limit: int = 50):
    """获取操作日志"""
    return {"logs": operation_logs[-limit:]}


# ============ 前端页面 ============

INDEX_HTML = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KubeSphere-Jenkins 角色同步工具</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #f5f7fa;
            color: #333;
            line-height: 1.6;
        }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        h1 { color: #1a73e8; margin-bottom: 8px; }
        .subtitle { color: #666; margin-bottom: 24px; }
        .card {
            background: #fff;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 16px;
            margin-bottom: 20px;
        }
        .stat-card {
            background: #fff;
            border-radius: 8px;
            padding: 20px;
            text-align: center;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .stat-value {
            font-size: 36px;
            font-weight: bold;
            color: #1a73e8;
        }
        .stat-value.danger { color: #e53935; }
        .stat-value.success { color: #43a047; }
        .stat-label { color: #666; font-size: 14px; margin-top: 4px; }
        .toolbar {
            display: flex;
            gap: 12px;
            margin-bottom: 16px;
            flex-wrap: wrap;
            align-items: center;
        }
        .btn {
            padding: 10px 20px;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 500;
            transition: all 0.2s;
            display: inline-flex;
            align-items: center;
            gap: 6px;
        }
        .btn:hover { opacity: 0.9; transform: translateY(-1px); }
        .btn:active { transform: translateY(0); }
        .btn-primary { background: #1a73e8; color: #fff; }
        .btn-success { background: #43a047; color: #fff; }
        .btn-danger { background: #e53935; color: #fff; }
        .btn:disabled { opacity: 0.5; cursor: not-allowed; }
        .search-box {
            padding: 10px 14px;
            border: 1px solid #ddd;
            border-radius: 6px;
            font-size: 14px;
            width: 280px;
        }
        .search-box:focus { outline: none; border-color: #1a73e8; }
        .filter-tabs {
            display: flex;
            gap: 8px;
            margin-bottom: 16px;
        }
        .filter-tab {
            padding: 6px 16px;
            border-radius: 20px;
            cursor: pointer;
            font-size: 13px;
            background: #f0f0f0;
            border: none;
        }
        .filter-tab.active {
            background: #1a73e8;
            color: #fff;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 14px;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #eee;
        }
        th {
            background: #f8f9fa;
            font-weight: 600;
            color: #555;
        }
        tr:hover { background: #f8f9fa; }
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 12px;
            font-weight: 500;
        }
        .status-ok { background: #e8f5e9; color: #2e7d32; }
        .status-missing { background: #ffebee; color: #c62828; }
        .status-fixed { background: #e3f2fd; color: #1565c0; }
        .dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            display: inline-block;
        }
        .dot-green { background: #43a047; }
        .dot-red { background: #e53935; }
        .dot-blue { background: #1a73e8; }
        .user-state {
            font-size: 12px;
            color: #888;
        }
        .actions { display: flex; gap: 8px; }
        .btn-small {
            padding: 4px 12px;
            font-size: 12px;
            border-radius: 4px;
        }
        .alert {
            padding: 12px 16px;
            border-radius: 6px;
            margin-bottom: 16px;
            display: none;
        }
        .alert.show { display: block; }
        .alert-info { background: #e3f2fd; color: #1565c0; border: 1px solid #bbdefb; }
        .alert-success { background: #e8f5e9; color: #2e7d32; border: 1px solid #c8e6c9; }
        .alert-error { background: #ffebee; color: #c62828; border: 1px solid #ffcdd2; }
        .loading {
            display: inline-block;
            width: 16px;
            height: 16px;
            border: 2px solid #fff;
            border-top-color: transparent;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        .progress-bar {
            height: 4px;
            background: #e0e0e0;
            border-radius: 2px;
            overflow: hidden;
            margin-top: 8px;
        }
        .progress-fill {
            height: 100%;
            background: #1a73e8;
            transition: width 0.3s;
        }
        .empty-state {
            text-align: center;
            padding: 60px 20px;
            color: #999;
        }
        .config-info {
            background: #f8f9fa;
            padding: 12px 16px;
            border-radius: 6px;
            font-size: 13px;
            color: #666;
            margin-bottom: 16px;
        }
        .config-info code {
            background: #e8eaf6;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: monospace;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔧 KubeSphere-Jenkins 角色同步工具</h1>
        <p class="subtitle">检测 KubeSphere 用户是否在 Jenkins 中正确同步 admin 角色，支持一键修复</p>

        <div class="config-info" id="configInfo">
            正在加载配置信息...
        </div>

        <div class="stats" id="stats">
            <div class="stat-card">
                <div class="stat-value" id="statTotal">-</div>
                <div class="stat-label">总用户数</div>
            </div>
            <div class="stat-card">
                <div class="stat-value success" id="statSynced">-</div>
                <div class="stat-label">已同步</div>
            </div>
            <div class="stat-card">
                <div class="stat-value danger" id="statMissing">-</div>
                <div class="stat-label">缺失角色</div>
            </div>
        </div>

        <div class="alert" id="alert"></div>

        <div class="card">
            <div class="toolbar">
                <button class="btn btn-primary" onclick="refreshData()" id="btnRefresh">
                    🔄 刷新扫描
                </button>
                <button class="btn btn-success" onclick="fixAll()" id="btnFixAll">
                    🔧 一键修复全部
                </button>
                <input type="text" class="search-box" id="searchInput"
                       placeholder="搜索用户名..." oninput="filterUsers()">
            </div>

            <div class="filter-tabs">
                <button class="filter-tab active" onclick="setFilter('all')">全部</button>
                <button class="filter-tab" onclick="setFilter('missing')">缺失角色</button>
                <button class="filter-tab" onclick="setFilter('synced')">已同步</button>
            </div>

            <div class="progress-bar" id="progressBar" style="display:none;">
                <div class="progress-fill" id="progressFill" style="width:0%"></div>
            </div>

            <table id="userTable">
                <thead>
                    <tr>
                        <th>用户名</th>
                        <th>显示名称</th>
                        <th>邮箱</th>
                        <th>状态</th>
                        <th>Jenkins 角色</th>
                        <th>操作</th>
                    </tr>
                </thead>
                <tbody id="userTableBody">
                    <tr>
                        <td colspan="6" class="empty-state">点击"刷新扫描"加载数据</td>
                    </tr>
                </tbody>
            </table>
        </div>
    </div>

    <script>
        let allUsers = [];
        let currentFilter = 'all';

        async function showAlert(message, type = 'info') {
            const alert = document.getElementById('alert');
            alert.className = `alert alert-${type} show`;
            alert.textContent = message;
            setTimeout(() => alert.classList.remove('show'), 5000);
        }

        function setLoading(id, loading) {
            const btn = document.getElementById(id);
            if (loading) {
                btn.disabled = true;
                btn.dataset.originalText = btn.innerHTML;
                btn.innerHTML = '<span class="loading"></span> 处理中...';
            } else {
                btn.disabled = false;
                btn.innerHTML = btn.dataset.originalText || btn.innerHTML;
            }
        }

        async function loadConfig() {
            try {
                const res = await fetch('/api/health');
                const data = await res.json();
                const cfg = data.config;
                document.getElementById('configInfo').innerHTML = `
                    Jenkins: <code>${cfg.jenkins_host}</code> |
                    用户: <code>${cfg.jenkins_user}</code> |
                    角色: <code>${cfg.role_type}/${cfg.role_name}</code> |
                    状态: <span style="color:${data.jenkins.healthy?'#43a047':'#e53935'}">
                        ${data.jenkins.healthy?'✅ 正常':'❌ 异常'}
                    </span>
                `;
            } catch (e) {
                document.getElementById('configInfo').innerHTML =
                    '<span style="color:#e53935">❌ 无法连接到后端服务</span>';
            }
        }

        async function refreshData() {
            setLoading('btnRefresh', true);
            try {
                const res = await fetch('/api/users?force_refresh=true');
                const data = await res.json();
                allUsers = data.users || [];

                document.getElementById('statTotal').textContent = data.total_users;
                document.getElementById('statSynced').textContent = data.synced_users;
                document.getElementById('statMissing').textContent = data.missing_users;

                renderUsers();
                showAlert(`扫描完成！共 ${data.total_users} 个用户，${data.missing_users} 个缺失角色`, 'success');
            } catch (e) {
                showAlert('刷新失败: ' + e.message, 'error');
            } finally {
                setLoading('btnRefresh', false);
            }
        }

        function renderUsers() {
            const search = document.getElementById('searchInput').value.toLowerCase();
            const tbody = document.getElementById('userTableBody');

            let filtered = allUsers.filter(u => {
                if (currentFilter === 'missing') return !u.has_jenkins_role;
                if (currentFilter === 'synced') return u.has_jenkins_role;
                return true;
            }).filter(u => {
                return !search ||
                    u.username.toLowerCase().includes(search) ||
                    u.display_name.toLowerCase().includes(search) ||
                    u.email.toLowerCase().includes(search);
            });

            if (filtered.length === 0) {
                tbody.innerHTML = '<tr><td colspan="6" class="empty-state">暂无数据</td></tr>';
                return;
            }

            tbody.innerHTML = filtered.map(u => {
                const statusClass = u.fixed_at ? 'status-fixed' :
                    (u.has_jenkins_role ? 'status-ok' : 'status-missing');
                const statusText = u.fixed_at ? '已修复' :
                    (u.has_jenkins_role ? '已同步' : '缺失角色');
                const dotClass = u.fixed_at ? 'dot-blue' :
                    (u.has_jenkins_role ? 'dot-green' : 'dot-red');

                return `
                    <tr>
                        <td><strong>${escapeHtml(u.username)}</strong></td>
                        <td>${escapeHtml(u.display_name || '-')}</td>
                        <td>${escapeHtml(u.email || '-')}</td>
                        <td>
                            <span class="status-badge ${statusClass}">
                                <span class="dot ${dotClass}"></span>
                                ${statusText}
                            </span>
                            ${u.state !== 'Active' ? `<div class="user-state">K8s状态: ${u.state}</div>` : ''}
                        </td>
                        <td>${u.has_jenkins_role ? '✅ admin' : '❌ 无'}</td>
                        <td class="actions">
                            ${!u.has_jenkins_role ? `
                                <button class="btn btn-success btn-small" onclick="fixUser('${u.username}')">
                                    修复
                                </button>
                            ` : '<span style="color:#888;font-size:12px;">无需操作</span>'}
                        </td>
                    </tr>
                `;
            }).join('');
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function filterUsers() {
            renderUsers();
        }

        function setFilter(filter) {
            currentFilter = filter;
            document.querySelectorAll('.filter-tab').forEach(t => t.classList.remove('active'));
            event.target.classList.add('active');
            renderUsers();
        }

        async function fixUser(username) {
            const btn = event.target;
            btn.disabled = true;
            btn.innerHTML = '<span class="loading"></span>';

            try {
                const res = await fetch(`/api/users/${encodeURIComponent(username)}/fix`, {
                    method: 'POST'
                });
                const data = await res.json();

                if (data.success) {
                    showAlert(`用户 ${username} 修复成功！`, 'success');
                    // 更新本地数据
                    const user = allUsers.find(u => u.username === username);
                    if (user) {
                        user.has_jenkins_role = true;
                        user.fixed_at = data.fixed_at;
                    }
                    // 更新统计
                    const missing = allUsers.filter(u => !u.has_jenkins_role).length;
                    document.getElementById('statMissing').textContent = missing;
                    document.getElementById('statSynced').textContent = allUsers.length - missing;
                    renderUsers();
                } else {
                    showAlert(`用户 ${username} 修复失败: ${data.message}`, 'error');
                    btn.disabled = false;
                    btn.textContent = '修复';
                }
            } catch (e) {
                showAlert('修复失败: ' + e.message, 'error');
                btn.disabled = false;
                btn.textContent = '修复';
            }
        }

        async function fixAll() {
            const missingCount = allUsers.filter(u => !u.has_jenkins_role).length;
            if (missingCount === 0) {
                showAlert('没有需要修复的用户', 'info');
                return;
            }

            if (!confirm(`确定要修复 ${missingCount} 个缺失角色的用户吗？`)) {
                return;
            }

            setLoading('btnFixAll', true);
            const progressBar = document.getElementById('progressBar');
            const progressFill = document.getElementById('progressFill');
            progressBar.style.display = 'block';

            try {
                const res = await fetch('/api/users/fix-all', { method: 'POST' });
                const data = await res.json();

                progressFill.style.width = '100%';

                if (data.success > 0) {
                    showAlert(`修复完成！成功 ${data.success} 个，失败 ${data.failed} 个`, 'success');
                } else {
                    showAlert(`修复失败！0 个成功，${data.failed} 个失败`, 'error');
                }

                // 刷新数据
                await refreshData();
            } catch (e) {
                showAlert('批量修复失败: ' + e.message, 'error');
            } finally {
                setLoading('btnFixAll', false);
                progressBar.style.display = 'none';
                progressFill.style.width = '0%';
            }
        }

        // 初始化
        loadConfig();
        refreshData();
    </script>
</body>
</html>
"""

# ============ 入口 ============

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)

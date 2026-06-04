<!--
 * Copyright 2025 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
-->

<template>
  <el-aside
    :width="collapsed ? '56px' : '320px'"
    class="chat-session-sidebar"
    :class="{ collapsed }"
  >
    <!-- 收起时只显示展开按钮 -->
    <div v-if="collapsed" class="sidebar-collapsed">
      <el-tooltip content="展开会话列表" placement="right">
        <el-button circle class="expand-btn" @click="collapsed = false">
          <el-icon><DArrowRight /></el-icon>
        </el-button>
      </el-tooltip>
      <el-tooltip content="返回" placement="right"></el-tooltip>
    </div>

    <!-- 展开时显示完整内容 -->
    <template v-else>
      <!-- 顶部操作栏 -->
      <div class="sidebar-header">
        <div class="header-controls">
          <!-- <el-button type="primary" @click="goBack" circle>
            <el-icon><ArrowLeft /></el-icon>
          </el-button> -->
          <!-- 头像居中 -->
          <div class="agent-profile">
            <el-avatar :src="agent.avatar" size="large" class="agent-avatar">
              {{ agent.name }}
            </el-avatar>
            <div class="agent-meta">
              <div class="agent-name">{{ agent.name || 'Agent' }}</div>
              <div class="agent-subtitle">Chat sessions</div>
            </div>
          </div>

          <div class="header-right">
            <el-tooltip content="收起会话列表" placement="bottom">
              <el-button circle size="large" class="collapse-btn" @click="collapsed = true">
                <el-icon><DArrowLeft /></el-icon>
              </el-button>
            </el-tooltip>
          </div>
        </div>
        <!-- 在一行并且左80%右20%排列 gap8px -->
        <div class="new-session-section">
          <div class="new-session-main">
            <el-button class="new-session-button" @click="createNewSession">
              <el-icon><Plus /></el-icon>
              新建会话
            </el-button>
          </div>
          <div class="clear-session-main">
            <el-button class="clear-sessions-button" @click="clearAllSessions">
              <el-icon><Delete /></el-icon>
            </el-button>
          </div>
        </div>
      </div>

      <el-divider style="margin: 0" />

      <!-- 会话列表 -->
      <div class="session-list">
        <div class="session-list-heading">Sessions</div>
        <div
          v-for="session in sessions"
          :key="session.id"
          :class="[
            'session-item',
            { active: handleGetCurrentSession()?.id === session.id, pinned: session.isPinned },
          ]"
          @click="handleSelectSession(session)"
        >
          <div class="session-header">
            <span
              class="session-title"
              @dblclick="startEditSessionTitle(session)"
              v-if="!session.editing"
            >
              {{ session.title || '新会话' }}
            </span>
            <el-input
              v-else
              v-model="session.editingTitle"
              size="small"
              @blur="saveSessionTitle(session)"
              @keyup.enter="saveSessionTitle(session)"
              @keyup.esc="cancelEditSessionTitle(session)"
              ref="sessionTitleInputRef"
            />
            <div class="session-actions">
              <el-button type="text" size="small" @click.stop="startEditSessionTitle(session)">
                <el-icon><Edit /></el-icon>
              </el-button>
              <el-button type="text" size="small" @click.stop="togglePinSession(session)">
                <el-icon>
                  <StarFilled v-if="session.isPinned" />
                  <Star v-else />
                </el-icon>
              </el-button>
              <el-button type="text" size="small" @click.stop="deleteSession(session)">
                <el-icon><Delete /></el-icon>
              </el-button>
            </div>
          </div>
          <div class="session-time">
            {{ formatTime(session.updateTime || session.createTime) }}
          </div>
        </div>
      </div>
    </template>
  </el-aside>
</template>

<script lang="ts">
  import { defineComponent, PropType } from 'vue';
  import { ref, onMounted, onUnmounted, computed, nextTick } from 'vue';
  import { useRouter, useRoute } from 'vue-router';
  import { ElMessage, ElMessageBox } from 'element-plus';
  import ChatService from '../../services/chat';
  import {
    Plus,
    Delete,
    Star,
    StarFilled,
    Edit,
    DArrowLeft,
    DArrowRight,
  } from '@element-plus/icons-vue';
  import { type Agent } from '../../services/agent';
  import { type ChatSession } from '../../services/chat';

  // 扩展ChatSession接口以包含编辑相关属性
  interface ExtendedChatSession extends ChatSession {
    editing?: boolean;
    editingTitle?: string;
  }

  interface SessionUpdateEvent {
    type: string;
    sessionId: string;
    title: string;
  }

  export default defineComponent({
    name: 'ChatSessionSidebar',
    components: {
      Plus,
      Delete,
      Star,
      StarFilled,
      Edit,
      DArrowLeft,
      DArrowRight,
    },
    props: {
      agent: {
        type: Object as PropType<Agent>,
        required: true,
      },
      handleSetCurrentSession: {
        type: Function as PropType<(session: ChatSession | null) => Promise<void>>,
        required: true,
      },
      handleGetCurrentSession: {
        type: Function as PropType<() => ChatSession | null>,
        required: true,
      },
      handleSelectSession: {
        type: Function as PropType<(session: ChatSession) => Promise<void>>,
        required: true,
      },
      handleDeleteSessionState: {
        type: Function as PropType<(sessionId: string) => void>,
        required: true,
      },
    },
    setup(props) {
      const sessions = ref<ExtendedChatSession[]>([]);
      const collapsed = ref(false);
      const sessionEventSource = ref<EventSource | null>(null);
      let reconnectTimer: number | null = null;
      let isComponentActive = true;

      const router = useRouter();
      const route = useRoute();

      const formatTime = (time: Date | string | undefined) => {
        if (!time) return '';
        const date = new Date(time);
        return date.toLocaleString('zh-CN');
      };

      const clearReconnectTimer = () => {
        if (reconnectTimer) {
          window.clearTimeout(reconnectTimer);
          reconnectTimer = null;
        }
      };

      const handleTitleUpdate = (eventData: SessionUpdateEvent) => {
        if (!eventData?.sessionId) {
          return;
        }
        const target = sessions.value.find(session => session.id === eventData.sessionId);
        if (target) {
          target.title = eventData.title;
          target.editingTitle = eventData.title;
        }
        const current = props.handleGetCurrentSession();
        if (current && current.id === eventData.sessionId) {
          current.title = eventData.title;
        }
      };

      const connectSessionStream = () => {
        clearReconnectTimer();
        const currentAgentId = agentId.value;
        if (!currentAgentId) {
          return;
        }
        if (sessionEventSource.value) {
          sessionEventSource.value.close();
        }
        const source = new EventSource(`/api/agent/${currentAgentId}/sessions/stream`);
        source.addEventListener('title-updated', event => {
          try {
            const data = JSON.parse((event as MessageEvent<string>).data) as SessionUpdateEvent;
            handleTitleUpdate(data);
          } catch (error) {
            console.error('解析会话标题更新失败', error);
          }
        });
        source.onerror = error => {
          console.error('会话推送连接异常:', error);
          source.close();
          sessionEventSource.value = null;
          if (isComponentActive) {
            reconnectTimer = window.setTimeout(() => connectSessionStream(), 3000);
          }
        };
        sessionEventSource.value = source;
      };

      // 开始编辑会话标题
      const startEditSessionTitle = (session: ExtendedChatSession) => {
        session.editing = true;
        session.editingTitle = session.title || '新会话';
        nextTick(() => {
          const input = document.querySelector('.el-input__inner') as HTMLInputElement;
          if (input) {
            input.focus();
            input.select();
          }
        });
      };

      // 保存会话标题
      const saveSessionTitle = async (session: ExtendedChatSession) => {
        if (!session.editingTitle || session.editingTitle.trim() === '') {
          ElMessage.warning('会话标题不能为空');
          return;
        }

        const newTitle = session.editingTitle.trim();
        if (newTitle === session.title) {
          session.editing = false;
          return;
        }

        try {
          await ChatService.renameSession(session.id, Number(agentId.value), newTitle);
          session.title = newTitle;
          session.editing = false;
          ElMessage.success('会话标题已更新');
        } catch (error) {
          ElMessage.error('更新会话标题失败');
          console.error('更新会话标题失败:', error);
        }
      };

      // 取消编辑会话标题
      const cancelEditSessionTitle = (session: ExtendedChatSession) => {
        session.editing = false;
      };

      // 计算属性
      const agentId = computed(() => route.params.id as string);

      const parseAgentId = (value: unknown): number | null => {
        if (typeof value === 'number' && Number.isFinite(value)) {
          return value;
        }
        if (typeof value === 'string' && value.trim()) {
          const parsed = Number(value);
          return Number.isFinite(parsed) ? parsed : null;
        }
        return null;
      };

      const getRouteAgentId = (): number | null => {
        const rawAgentId = route.params.id;
        return parseAgentId(Array.isArray(rawAgentId) ? rawAgentId[0] : rawAgentId);
      };

      const requireRouteAgentId = (): number => {
        const resolvedAgentId = getRouteAgentId();
        if (resolvedAgentId === null) {
          throw new Error('智能体ID无效，请刷新后重试');
        }
        return resolvedAgentId;
      };

      // 方法
      const goBack = () => {
        router.push(`/agent/${agentId.value}`);
      };

      const loadSessions = async () => {
        try {
          sessions.value = await ChatService.getAgentSessions(requireRouteAgentId());
          // 默认选择第一个会话或创建新会话
          if (sessions.value.length > 0) {
            await props.handleSelectSession(sessions.value[0]);
          } else {
            await createNewSession();
          }
        } catch (error) {
          ElMessage.error('加载会话列表失败');
          console.error('加载会话列表失败:', error);
        }
      };

      const createNewSession = async () => {
        try {
          const newSession = await ChatService.createSession(requireRouteAgentId(), '新会话');
          sessions.value.unshift(newSession);
          await props.handleSelectSession(newSession);
          ElMessage.success('新会话创建成功');
        } catch (error) {
          ElMessage.error('创建会话失败');
          console.error('创建会话失败:', error);
        }
      };

      const togglePinSession = async (session: ChatSession) => {
        try {
          await ChatService.pinSession(session.id, requireRouteAgentId(), !session.isPinned);
          session.isPinned = !session.isPinned;
          ElMessage.success(session.isPinned ? '会话已置顶' : '会话已取消置顶');
        } catch (error) {
          ElMessage.error('操作失败');
          console.error('置顶会话失败:', error);
        }
      };

      const deleteSession = async (session: ChatSession) => {
        try {
          await ElMessageBox.confirm('确定要删除这个会话吗？', '确认删除', {
            confirmButtonText: '确定',
            cancelButtonText: '取消',
            type: 'warning',
          });
          await ChatService.deleteSession(session.id, requireRouteAgentId());
          props.handleDeleteSessionState(session.id);
          sessions.value = sessions.value.filter((s: ChatSession) => s.id !== session.id);
          if (props.handleGetCurrentSession() == session) {
            await props.handleSetCurrentSession(null);
          }
          ElMessage.success('会话删除成功');
        } catch (error) {
          if (error !== 'cancel') {
            ElMessage.error('删除会话失败');
            console.error('删除会话失败:', error);
          }
        }
      };

      const clearAllSessions = async () => {
        try {
          await ElMessageBox.confirm('确定要清空所有会话吗？此操作不可恢复。', '确认清空', {
            confirmButtonText: '确定',
            cancelButtonText: '取消',
            type: 'warning',
          });
          await ChatService.clearAgentSessions(requireRouteAgentId());
          sessions.value.forEach((session: ChatSession) => {
            props.handleDeleteSessionState(session.id);
          });
          sessions.value = [];
          await props.handleSetCurrentSession(null);
          ElMessage.success('所有会话已清空');
        } catch (error) {
          if (error !== 'cancel') {
            ElMessage.error('清空会话失败');
            console.error('清空会话失败:', error);
          }
        }
      };

      // 生命周期
      onMounted(async () => {
        connectSessionStream();
        await loadSessions();
      });

      onUnmounted(() => {
        isComponentActive = false;
        clearReconnectTimer();
        if (sessionEventSource.value) {
          sessionEventSource.value.close();
          sessionEventSource.value = null;
        }
      });

      return {
        sessions,
        collapsed,
        formatTime,
        goBack,
        createNewSession,
        togglePinSession,
        deleteSession,
        clearAllSessions,
        startEditSessionTitle,
        saveSessionTitle,
        cancelEditSessionTitle,
      };
    },
  });
</script>

<style scoped>
  .chat-session-sidebar {
    background: #eef3ed;
    border-right: 1px solid #d7e1d3;
    transition: width 0.3s ease;
    overflow: hidden;
    box-shadow: 8px 0 24px rgba(34, 94, 58, 0.06);
  }

  .chat-session-sidebar.collapsed {
    overflow: visible;
  }

  /* 收起状态 */
  .sidebar-collapsed {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 16px 0;
    gap: 12px;
    background: #eef3ed;
    min-height: 100%;
    border-right: 1px solid #d7e1d3;
  }

  .sidebar-collapsed .expand-btn {
    flex-shrink: 0;
    width: 36px;
    height: 36px;
    color: #315846;
    background: #ffffff;
    border-color: #cdddc8;
    box-shadow: 0 6px 16px rgba(34, 94, 58, 0.1);
  }

  .sidebar-collapsed .expand-btn:hover,
  .sidebar-collapsed .expand-btn:focus {
    color: #167243;
    background: #edf8ef;
    border-color: #9fca9f;
  }

  .sidebar-collapsed .back-btn {
    flex-shrink: 0;
  }

  /* 左侧边栏样式 */
  .sidebar-header {
    padding: 18px 18px 14px;
    background: #f8faf6;
    border-bottom: 1px solid #dbe6d5;
  }

  .header-controls {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin-bottom: 14px;
  }

  .agent-profile {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .agent-avatar {
    flex: 0 0 auto;
    border: 1px solid rgba(47, 157, 85, 0.18);
    box-shadow: 0 8px 20px rgba(34, 94, 58, 0.12);
  }

  .agent-meta {
    min-width: 0;
  }

  .agent-name {
    color: #183627;
    font-size: 14px;
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .agent-subtitle {
    margin-top: 2px;
    color: #7d9184;
    font-size: 12px;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .header-right :deep(.el-button) {
    color: #315846;
    background: #ffffff;
    border-color: #cdddc8;
    box-shadow: 0 6px 16px rgba(34, 94, 58, 0.08);
  }

  .header-right :deep(.el-button:hover),
  .header-right :deep(.el-button:focus) {
    color: #167243;
    background: #edf8ef;
    border-color: #9fca9f;
  }

  .new-session-section {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 40px;
    gap: 8px;
  }

  .new-session-main,
  .clear-session-main {
    min-width: 0;
  }

  .new-session-button,
  .clear-sessions-button {
    width: 100%;
    height: 38px;
    border-radius: 8px;
    font-weight: 700;
    box-shadow: none;
  }

  .new-session-button {
    color: #173f2a;
    background: #ffffff;
    border: 1px solid #d6e2d0;
  }

  .new-session-button:hover,
  .new-session-button:focus {
    color: #167243;
    background: #edf8ef;
    border-color: #9fca9f;
  }

  .clear-sessions-button {
    color: #a94b4b;
    background: #fff3f1;
    border: 1px solid #efcbc7;
  }

  .clear-sessions-button:hover,
  .clear-sessions-button:focus {
    color: #8d3434;
    background: #ffe9e5;
    border-color: #dda6a0;
  }

  /* 会话列表样式 */
  .session-list {
    max-height: calc(100vh - 201px);
    overflow-y: auto;
    padding: 14px 13px 20px;
    background: linear-gradient(180deg, #eef3ed 0%, #f5f7f2 100%);
  }

  .session-list-heading {
    padding: 0 7px 10px;
    color: #6f8375;
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0;
  }

  .session-item {
    padding: 13px 14px;
    border: 1px solid #e6ece2;
    border-radius: 8px;
    margin-bottom: 8px;
    cursor: pointer;
    transition:
      border-color 0.2s ease,
      background 0.2s ease,
      box-shadow 0.2s ease,
      transform 0.2s ease;
    background: rgba(255, 255, 255, 0.92);
    box-shadow: 0 1px 4px rgba(34, 94, 58, 0.05);
  }

  .session-item:hover {
    border-color: #b9d3b4;
    background: #ffffff;
    transform: translateY(-1px);
  }

  .session-item.active {
    border-color: #167243;
    background: #edf8ef;
    box-shadow: 0 5px 14px rgba(22, 114, 67, 0.1);
  }

  .session-item.pinned {
    border-left: 4px solid #7b9f42;
  }

  .session-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 8px;
  }

  .session-title {
    font-weight: 600;
    font-size: 14px;
    color: #183627;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-right: 8px;
  }

  .session-actions {
    display: flex;
    gap: 4px;
    flex-shrink: 0;
  }

  .session-actions :deep(.el-button) {
    width: 24px;
    height: 24px;
    padding: 0;
    color: #79a4b1;
    border-radius: 6px;
  }

  .session-actions :deep(.el-button:hover) {
    color: #167243;
    background: #edf8ef;
  }

  .session-time {
    font-size: 12px;
    color: #7d9184;
  }

  /* 响应式设计 */
  @media (max-width: 768px) {
    .chat-session-sidebar {
      width: 280px !important;
    }

    .chat-session-sidebar.collapsed {
      width: 56px !important;
    }
  }
</style>

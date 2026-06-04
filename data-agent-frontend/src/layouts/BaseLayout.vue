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
  <div class="base-layout">
    <!-- 现代化头部导航 -->
    <header class="page-header">
      <div class="header-content">
        <div class="brand-section">
          <div class="brand-logo">
            <img src="@/assets/company-logo.jpg" alt="XX Data Agent" class="brand-logo-img" />
            <div class="brand-copy">
              <span class="brand-text">XX Data Agent</span>
              <span class="brand-subtitle">绿色循环包装数据智能体</span>
            </div>
          </div>
          <nav class="header-nav">
            <div class="nav-item" :class="{ active: isAgentPage() }" @click="goToAgentList">
              <i class="bi bi-grid-3x3-gap"></i>
              <span>智能体列表</span>
            </div>
            <div class="nav-item" :class="{ active: isModelConfigPage() }" @click="goToModelConfig">
              <i class="bi bi-gear"></i>
              <span>模型配置</span>
            </div>
          </nav>
        </div>
      </div>
    </header>

    <!-- 页面内容区域 -->
    <main class="page-content">
      <slot></slot>
    </main>
  </div>
</template>

<script>
  import { useRouter } from 'vue-router';

  export default {
    name: 'BaseLayout',
    setup() {
      const router = useRouter();

      // 导航方法
      const goToAgentList = () => {
        router.push('/agents');
      };

      const goToModelConfig = () => {
        router.push('/model-config');
      };

      const isAgentPage = () => {
        return (
          router.currentRoute.value.name === 'AgentList' ||
          router.currentRoute.value.name === 'AgentDetail' ||
          router.currentRoute.value.name === 'AgentCreate' ||
          router.currentRoute.value.name === 'AgentRun'
        );
      };

      const isModelConfigPage = () => {
        return router.currentRoute.value.name === 'ModelConfig';
      };

      return {
        goToAgentList,
        goToModelConfig,
        isAgentPage,
        isModelConfigPage,
      };
    },
  };
</script>

<style scoped>
  .base-layout {
    min-height: 100vh;
    background:
      radial-gradient(circle at 0 0, rgba(18, 124, 75, 0.08), transparent 34%),
      linear-gradient(135deg, #f7faf4 0%, #eef5ea 100%);
  }

  .page-header {
    background: rgba(255, 255, 255, 0.92);
    border-bottom: 1px solid #d7e7d6;
    box-shadow: 0 8px 24px rgba(34, 94, 58, 0.08);
    backdrop-filter: blur(12px);
    position: sticky;
    top: 0;
    z-index: 100;
  }

  .header-content {
    width: 100%;
    padding: 0 1.5rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 4rem;
  }

  .brand-section {
    display: flex;
    align-items: center;
    gap: 2rem;
  }

  .brand-logo {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .brand-logo-img {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    box-shadow: 0 6px 16px rgba(0, 178, 57, 0.18);
  }

  .brand-copy {
    display: flex;
    flex-direction: column;
    line-height: 1.15;
  }

  .brand-text {
    font-size: 1.2rem;
    font-weight: 700;
    color: #173f2a;
  }

  .brand-subtitle {
    margin-top: 3px;
    font-size: 12px;
    font-weight: 500;
    color: #5f7d66;
  }

  .header-nav {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 1rem;
    border-radius: 8px;
    cursor: pointer;
    transition: all 0.2s ease;
    color: #52685a;
    font-weight: 500;
  }

  .nav-item:hover {
    background: #eef7ee;
    color: #1f6b42;
  }

  .nav-item.active {
    background: #dff1df;
    color: #0f5b36;
  }

  .nav-item i {
    font-size: 1rem;
  }

  .page-content {
    flex: 1;
    padding: 0;
  }
</style>

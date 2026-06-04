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
  <div style="padding: 20px">
    <div style="margin-bottom: 20px">
      <h2>语义模型管理</h2>
    </div>
    <el-divider />

    <div style="margin-bottom: 30px">
      <el-row style="display: flex; justify-content: space-between; align-items: center">
        <el-col :span="12">
          <h3>语义模型列表</h3>
          <el-button
            v-if="selectedModels.length > 0"
            :icon="Delete"
            plain
            size="default"
            style="margin-left: 10px"
            type="danger"
            @click="batchDeleteModels"
          >
            批量删除 ({{ selectedModels.length }})
          </el-button>
        </el-col>
        <el-col :span="12" style="text-align: right">
          <el-input
            v-model="searchKeyword"
            clearable
            placeholder="请输入关键词后回车搜索"
            size="large"
            style="width: 250px; margin-right: 10px"
            @clear="handleSearch"
            @keyup.enter="handleSearch"
          >
            <template #prefix>
              <el-icon><Search /></el-icon>
            </template>
          </el-input>
          <el-button round size="large" type="success" @click="openBatchImportDialog">
            <el-icon><UploadFilled /></el-icon>
            批量导入
          </el-button>
          <el-button :icon="Plus" round size="large" type="primary" @click="openCreateDialog">
            添加语义模型
          </el-button>
        </el-col>
      </el-row>
    </div>

    <el-table
      :data="semanticModelList"
      border
      style="width: 100%"
      @selection-change="handleSelectionChange"
    >
      <el-table-column type="selection" width="55" />
      <el-table-column label="ID" min-width="60px" prop="id" />
      <el-table-column label="表名" min-width="120px" prop="tableName" />
      <el-table-column label="字段名" min-width="120px" prop="columnName" />
      <el-table-column label="业务名称" min-width="120px" prop="businessName" />
      <el-table-column label="同义词" min-width="120px" prop="synonyms" />
      <el-table-column label="数据类型" min-width="80px" prop="dataType" />
      <el-table-column label="状态" min-width="80px">
        <template #default="scope">
          <el-tag :type="scope.row.status ? 'success' : 'info'" round>
            {{ scope.row.status ? '启用' : '停用' }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="创建时间" min-width="160px">
        <template #default="scope">
          {{ formatModelCreatedTime(scope.row) }}
        </template>
      </el-table-column>
      <el-table-column label="操作" min-width="180px">
        <template #default="scope">
          <el-button plain round size="small" type="primary" @click="editModel(scope.row)">
            编辑
          </el-button>
          <el-button
            v-if="!scope.row.status"
            plain
            round
            size="small"
            type="success"
            @click="toggleStatus(scope.row, true)"
          >
            启用
          </el-button>
          <el-button
            v-else
            plain
            round
            size="small"
            type="warning"
            @click="toggleStatus(scope.row, false)"
          >
            停用
          </el-button>
          <el-button plain round size="small" type="danger" @click="deleteModel(scope.row)">
            删除
          </el-button>
        </template>
      </el-table-column>
    </el-table>
  </div>

  <el-dialog v-model="dialogVisible" :title="isEdit ? '编辑语义模型' : '添加语义模型'" width="800">
    <el-form ref="modelFormRef" :model="modelForm" label-width="120px">
      <el-form-item label="表名" prop="tableName" required>
        <el-input v-model="modelForm.tableName" :disabled="isEdit" placeholder="请输入表名" />
      </el-form-item>

      <el-form-item label="数据库字段名" prop="columnName" required>
        <el-input
          v-model="modelForm.columnName"
          :disabled="isEdit"
          placeholder="请输入数据库字段名"
        />
      </el-form-item>

      <el-form-item label="业务名称" prop="businessName" required>
        <el-input v-model="modelForm.businessName" placeholder="请输入业务名称" />
      </el-form-item>

      <el-form-item label="同义词" prop="synonyms">
        <el-input
          v-model="modelForm.synonyms"
          :rows="2"
          placeholder="请输入同义词，多个同义词使用逗号分隔"
          type="textarea"
        />
      </el-form-item>

      <el-form-item label="业务描述" prop="businessDescription">
        <el-input
          v-model="modelForm.businessDescription"
          :rows="3"
          placeholder="请输入业务描述，用于帮助模型理解字段含义"
          type="textarea"
        />
      </el-form-item>

      <el-form-item label="字段注释" prop="columnComment">
        <el-input
          v-model="modelForm.columnComment"
          :rows="2"
          placeholder="请输入数据库字段原始注释"
          type="textarea"
        />
      </el-form-item>

      <el-form-item label="数据类型" prop="dataType" required>
        <el-input
          v-model="modelForm.dataType"
          placeholder="请输入数据类型，例如 int、varchar(20)"
        />
      </el-form-item>
    </el-form>

    <template #footer>
      <div style="text-align: right">
        <el-button @click="dialogVisible = false">取消</el-button>
        <el-button type="primary" @click="saveModel">
          {{ isEdit ? '更新' : '创建' }}
        </el-button>
      </div>
    </template>
  </el-dialog>

  <BatchImportDialog
    v-model="batchImportDialogVisible"
    :json-template="jsonTemplate"
    :on-download-excel-template="downloadExcelTemplate"
    :on-excel-import="executeExcelImport"
    :on-json-import="executeBatchImport"
    :validate-excel-file="validateExcelFile"
    :validate-json="validateJson"
    title="批量导入语义模型"
    @imported="handleBatchImported"
  />
</template>

<script lang="ts">
  import { defineComponent, onMounted, ref, type Ref } from 'vue';
  import { Delete, Plus, Search, UploadFilled } from '@element-plus/icons-vue';
  import { ElMessage, ElMessageBox } from 'element-plus';
  import BatchImportDialog from './BatchImportDialog.vue';
  import agentDatasourceService from '@/services/agentDatasource';
  import semanticModelService, {
    type SemanticModel,
    type SemanticModelAddDto,
    type SemanticModelImportItem,
    type SemanticModelUpdateDto,
  } from '@/services/semanticModel';

  type SemanticModelView = SemanticModel & {
    createTime?: string;
  };

  const createEmptyModel = (agentId: number): SemanticModel => ({
    tableName: '',
    columnName: '',
    businessName: '',
    synonyms: '',
    businessDescription: '',
    columnComment: '',
    dataType: '',
    status: true,
    agentId,
  });

  export default defineComponent({
    name: 'AgentSemanticsConfig',
    components: {
      BatchImportDialog,
      UploadFilled,
      Search,
    },
    props: {
      agentId: {
        type: Number,
        required: true,
      },
    },
    setup(props) {
      const semanticModelList: Ref<SemanticModel[]> = ref([]);
      const dialogVisible = ref(false);
      const batchImportDialogVisible = ref(false);
      const isEdit = ref(false);
      const searchKeyword = ref('');
      const selectedModels: Ref<SemanticModel[]> = ref([]);
      const currentEditId = ref<number | null>(null);
      const modelForm: Ref<SemanticModel> = ref(createEmptyModel(props.agentId));

      const jsonTemplate = [
        {
          tableName: 'work_order',
          columnName: 'order_type',
          businessName: '工单类型',
          synonyms: '类型,工单种类',
          businessDesc: '用于区分工单种类，例如 1=资产工单, 2=账号工单',
          dataType: 'int',
        },
        {
          tableName: 'work_order',
          columnName: 'status',
          businessName: '工单状态',
          synonyms: '状态,处理状态',
          businessDesc: '工单当前处理状态，例如 0=待处理, 1=处理中, 2=已完成, 3=已关闭',
          dataType: 'int',
        },
      ];

      const getErrorMessage = (error: unknown, fallback: string): string => {
        if (error instanceof Error && error.message.trim()) {
          return error.message;
        }
        return fallback;
      };

      const getActiveDatasourceId = async (): Promise<number> => {
        const activeAgentDatasource = await agentDatasourceService.getActiveAgentDatasource(
          props.agentId,
        );
        if (!activeAgentDatasource.datasourceId) {
          throw new Error('当前未找到启用的数据源');
        }
        return activeAgentDatasource.datasourceId;
      };

      const loadSemanticModels = async () => {
        try {
          semanticModelList.value = await semanticModelService.list(
            props.agentId,
            searchKeyword.value || undefined,
          );
        } catch (error) {
          ElMessage.error(getErrorMessage(error, '加载语义模型列表失败'));
          console.error('Failed to load semantic models:', error);
        }
      };

      const handleSearch = () => {
        loadSemanticModels();
      };

      const openCreateDialog = () => {
        isEdit.value = false;
        currentEditId.value = null;
        modelForm.value = createEmptyModel(props.agentId);
        dialogVisible.value = true;
      };

      const openBatchImportDialog = () => {
        batchImportDialogVisible.value = true;
      };

      const handleSelectionChange = (selection: SemanticModel[]) => {
        selectedModels.value = selection;
      };

      const editModel = (model: SemanticModel) => {
        isEdit.value = true;
        currentEditId.value = model.id || null;
        modelForm.value = { ...model };
        dialogVisible.value = true;
      };

      const deleteModel = async (model: SemanticModel) => {
        if (!model.id) {
          return;
        }

        try {
          await ElMessageBox.confirm(`确定要删除语义模型“${model.businessName}”吗？`, '确认删除', {
            confirmButtonText: '确定',
            cancelButtonText: '取消',
            type: 'warning',
          });

          const result = await semanticModelService.delete(model.id);
          if (!result) {
            ElMessage.error('删除失败');
            return;
          }

          ElMessage.success('删除成功');
          await loadSemanticModels();
        } catch (error) {
          if (error !== 'cancel') {
            console.error('Failed to delete semantic model:', error);
          }
        }
      };

      const batchDeleteModels = async () => {
        if (selectedModels.value.length === 0) {
          ElMessage.warning('请先选择要删除的语义模型');
          return;
        }

        try {
          await ElMessageBox.confirm(
            `确定要删除选中的 ${selectedModels.value.length} 个语义模型吗？`,
            '确认批量删除',
            {
              confirmButtonText: '确定',
              cancelButtonText: '取消',
              type: 'warning',
            },
          );

          const ids = selectedModels.value
            .map(model => model.id)
            .filter((id): id is number => id !== undefined);
          const result = await semanticModelService.batchDelete(ids);
          if (!result) {
            ElMessage.error('批量删除失败');
            return;
          }

          ElMessage.success(`成功删除 ${ids.length} 个语义模型`);
          selectedModels.value = [];
          await loadSemanticModels();
        } catch (error) {
          if (error !== 'cancel') {
            console.error('Failed to batch delete semantic models:', error);
          }
        }
      };

      const toggleStatus = async (model: SemanticModel, status: boolean) => {
        if (!model.id) {
          return;
        }

        try {
          const ids = [model.id];
          const result =
            status
              ? await semanticModelService.enable(ids)
              : await semanticModelService.disable(ids);

          if (!result) {
            ElMessage.error(`${status ? '启用' : '停用'}失败`);
            return;
          }

          ElMessage.success(`${status ? '启用' : '停用'}成功`);
          model.status = status;
        } catch (error) {
          ElMessage.error(getErrorMessage(error, `${status ? '启用' : '停用'}失败`));
          console.error('Failed to toggle status:', error);
        }
      };

      const saveModel = async () => {
        try {
          if (isEdit.value && currentEditId.value) {
            const formData: SemanticModelUpdateDto = {
              businessName: modelForm.value.businessName,
              synonyms: modelForm.value.synonyms,
              businessDescription: modelForm.value.businessDescription,
              columnComment: modelForm.value.columnComment,
              dataType: modelForm.value.dataType,
            };
            const result = await semanticModelService.update(currentEditId.value, formData);
            if (!result) {
              ElMessage.error('更新失败');
              return;
            }
            ElMessage.success('更新成功');
          } else {
            const datasourceId = await getActiveDatasourceId();
            const formData: SemanticModelAddDto = {
              agentId: props.agentId,
              datasourceId,
              tableName: modelForm.value.tableName,
              columnName: modelForm.value.columnName,
              businessName: modelForm.value.businessName,
              synonyms: modelForm.value.synonyms,
              businessDescription: modelForm.value.businessDescription,
              columnComment: modelForm.value.columnComment,
              dataType: modelForm.value.dataType,
            };
            const result = await semanticModelService.create(formData);
            if (!result) {
              ElMessage.error('创建失败');
              return;
            }
            ElMessage.success('创建成功');
          }

          dialogVisible.value = false;
          await loadSemanticModels();
        } catch (error) {
          ElMessage.error(getErrorMessage(error, isEdit.value ? '更新失败' : '创建失败'));
          console.error('Failed to save model:', error);
        }
      };

      const validateJson = (jsonText: string) => {
        try {
          const data = JSON.parse(jsonText);
          if (!Array.isArray(data)) {
            ElMessage.error('JSON 格式错误：数据必须是数组');
            return false;
          }
          if (data.length === 0) {
            ElMessage.error('导入数据不能为空');
            return false;
          }

          for (let i = 0; i < data.length; i++) {
            const item = data[i];
            if (!item.tableName || !item.columnName || !item.businessName || !item.dataType) {
              ElMessage.error(
                `第 ${i + 1} 条记录缺少必填字段（tableName、columnName、businessName、dataType）`,
              );
              return false;
            }
          }

          ElMessage.success('JSON 格式校验通过');
          return true;
        } catch (error) {
          ElMessage.error(`JSON 格式错误：${(error as Error).message}`);
          return false;
        }
      };

      const executeBatchImport = async (items: SemanticModelImportItem[]) => {
        try {
          const datasourceId = await getActiveDatasourceId();
          return await semanticModelService.batchImport({
            agentId: props.agentId,
            datasourceId,
            items,
          });
        } catch (error) {
          ElMessage.error(`批量导入失败：${getErrorMessage(error, '导入失败')}`);
          console.error('Failed to batch import:', error);
          throw error;
        }
      };

      const validateExcelFile = (file: File | null) => {
        if (!file) {
          ElMessage.error('请先选择 Excel 文件');
          return false;
        }
        return true;
      };

      const downloadExcelTemplate = async () => {
        try {
          await semanticModelService.downloadTemplate();
          ElMessage.success('模板下载成功');
        } catch (error) {
          ElMessage.error(`模板下载失败：${getErrorMessage(error, '下载失败')}`);
          console.error('Failed to download template:', error);
        }
      };

      const executeExcelImport = async (file: File) => {
        try {
          const datasourceId = await getActiveDatasourceId();
          return await semanticModelService.importExcel(file, props.agentId, datasourceId);
        } catch (error) {
          ElMessage.error(`Excel 导入失败：${getErrorMessage(error, '导入失败')}`);
          console.error('Failed to import excel:', error);
          throw error;
        }
      };

      const handleBatchImported = async () => {
        await loadSemanticModels();
      };

      const formatDateTime = (dateTime?: string) => {
        if (!dateTime) {
          return '-';
        }
        try {
          const date = new Date(dateTime);
          return date.toLocaleString('zh-CN', {
            year: 'numeric',
            month: '2-digit',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit',
            hour12: false,
          });
        } catch {
          return dateTime;
        }
      };

      const formatModelCreatedTime = (model: SemanticModelView) =>
        formatDateTime(model.createdTime || model.createTime);

      onMounted(() => {
        loadSemanticModels();
      });

      return {
        Plus,
        Search,
        Delete,
        semanticModelList,
        dialogVisible,
        batchImportDialogVisible,
        isEdit,
        searchKeyword,
        selectedModels,
        modelForm,
        jsonTemplate,
        openCreateDialog,
        openBatchImportDialog,
        handleSelectionChange,
        batchDeleteModels,
        handleSearch,
        editModel,
        deleteModel,
        toggleStatus,
        saveModel,
        validateJson,
        validateExcelFile,
        executeBatchImport,
        downloadExcelTemplate,
        executeExcelImport,
        handleBatchImported,
        formatModelCreatedTime,
      };
    },
  });
</script>

<style scoped></style>

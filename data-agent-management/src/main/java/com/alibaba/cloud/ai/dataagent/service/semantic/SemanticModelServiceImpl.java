/*
 * Copyright 2024-2026 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.alibaba.cloud.ai.dataagent.service.semantic;

import com.alibaba.cloud.ai.dataagent.dto.schema.SemanticModelAddDTO;
import com.alibaba.cloud.ai.dataagent.dto.schema.SemanticModelBatchImportDTO;
import com.alibaba.cloud.ai.dataagent.dto.schema.SemanticModelImportItem;
import com.alibaba.cloud.ai.dataagent.dto.schema.SemanticModelUpdateDTO;
import com.alibaba.cloud.ai.dataagent.entity.AgentDatasource;
import com.alibaba.cloud.ai.dataagent.entity.SemanticModel;
import com.alibaba.cloud.ai.dataagent.mapper.AgentDatasourceMapper;
import com.alibaba.cloud.ai.dataagent.mapper.SemanticModelMapper;
import com.alibaba.cloud.ai.dataagent.vo.BatchImportResult;
import java.io.InputStream;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Locale;
import lombok.AllArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

@Service
@AllArgsConstructor
@Slf4j
public class SemanticModelServiceImpl implements SemanticModelService {

	private static final String DUPLICATE_SEMANTIC_MODEL_MESSAGE = "当前数据源下该表字段的语义模型已存在，请修改已有语义模型后再新增";

	private final SemanticModelMapper semanticModelMapper;

	private final AgentDatasourceMapper agentDatasourceMapper;

	private final SemanticModelExcelService excelService;

	@Override
	public List<SemanticModel> getAll() {
		return semanticModelMapper.selectAll();
	}

	@Override
	public List<SemanticModel> getEnabledByAgentId(Long agentId) {
		return semanticModelMapper.selectEnabledByAgentId(agentId);
	}

	@Override
	public List<SemanticModel> getEnabledByAgentIdAndDatasourceId(Long agentId, Integer datasourceId) {
		if (agentId == null || datasourceId == null) {
			return List.of();
		}
		return semanticModelMapper.selectEnabledByAgentIdAndDatasourceId(agentId, datasourceId);
	}

	@Override
	public List<SemanticModel> getByAgentIdAndTableNames(Long agentId, List<String> tableNames) {
		if (agentId == null || tableNames == null || tableNames.isEmpty()) {
			return List.of();
		}

		return semanticModelMapper.selectEnabledByAgentIdAndTableNames(agentId, normalizeTableNames(tableNames));
	}

	@Override
	public List<SemanticModel> getEnabledByAgentIdAndDatasourceIdAndTableNames(Long agentId, Integer datasourceId,
			List<String> tableNames) {
		if (agentId == null || datasourceId == null || tableNames == null || tableNames.isEmpty()) {
			return List.of();
		}
		return semanticModelMapper.selectEnabledByAgentIdAndDatasourceIdAndTableNames(agentId, datasourceId,
				normalizeTableNames(tableNames));
	}

	@Override
	public SemanticModel getById(Long id) {
		return semanticModelMapper.selectById(id);
	}

	@Override
	public void addSemanticModel(SemanticModel semanticModel) {
		insertSemanticModel(semanticModel, DUPLICATE_SEMANTIC_MODEL_MESSAGE);
	}

	@Override
	public boolean addSemanticModel(SemanticModelAddDTO dto) {
		validateAgentDatasourceBinding(dto.getAgentId(), dto.getDatasourceId());

		SemanticModel existing = semanticModelMapper.selectByAgentIdAndDatasourceIdAndTableNameAndColumnName(
				dto.getAgentId(), dto.getDatasourceId(), dto.getTableName(), dto.getColumnName());
		if (existing != null) {
			throw new IllegalArgumentException(DUPLICATE_SEMANTIC_MODEL_MESSAGE);
		}

		SemanticModel semanticModel = SemanticModel.builder()
			.agentId(dto.getAgentId())
			.datasourceId(dto.getDatasourceId())
			.tableName(dto.getTableName())
			.columnName(dto.getColumnName())
			.businessName(dto.getBusinessName())
			.synonyms(dto.getSynonyms())
			.businessDescription(dto.getBusinessDescription())
			.columnComment(dto.getColumnComment())
			.dataType(dto.getDataType())
			.status(true)
			.build();

		insertSemanticModel(semanticModel, DUPLICATE_SEMANTIC_MODEL_MESSAGE);
		return true;
	}

	private AgentDatasource validateAgentDatasourceBinding(Long agentId, Integer datasourceId) {
		if (agentId == null) {
			throw new IllegalArgumentException("agentId不能为空");
		}
		if (datasourceId == null) {
			throw new IllegalArgumentException("datasourceId不能为空");
		}
		AgentDatasource agentDatasource = agentDatasourceMapper.selectByAgentIdAndDatasourceId(agentId, datasourceId);
		if (agentDatasource == null) {
			throw new IllegalArgumentException(
					"未找到对应的智能体与数据源绑定关系: agentId=%s, datasourceId=%s".formatted(agentId, datasourceId));
		}
		return agentDatasource;
	}

	@Override
	public void enableSemanticModel(Long id) {
		semanticModelMapper.enableById(id);
	}

	@Override
	public void disableSemanticModel(Long id) {
		semanticModelMapper.disableById(id);
	}

	@Override
	public List<SemanticModel> getByAgentId(Long agentId) {
		return semanticModelMapper.selectByAgentId(agentId);
	}

	@Override
	public List<SemanticModel> search(String keyword) {
		return semanticModelMapper.searchByKeyword(keyword);
	}

	@Override
	public List<SemanticModel> searchByAgentId(Long agentId, String keyword) {
		if (agentId == null) {
			return List.of();
		}
		return semanticModelMapper.searchByKeywordAndAgentId(agentId, keyword);
	}

	@Override
	public void deleteSemanticModel(Long id) {
		semanticModelMapper.deleteById(id);
	}

	@Override
	public BatchImportResult batchImport(SemanticModelBatchImportDTO dto) {
		BatchImportResult result = BatchImportResult.builder()
			.total(dto.getItems().size())
			.successCount(0)
			.failCount(0)
			.build();

		try {
			validateAgentDatasourceBinding(dto.getAgentId(), dto.getDatasourceId());
		}
		catch (Exception e) {
			log.error("校验智能体数据源绑定失败: agentId={}, datasourceId={}", dto.getAgentId(), dto.getDatasourceId(), e);
			result.setFailCount(dto.getItems().size());
			result.addError("校验智能体数据源绑定失败: " + e.getMessage());
			return result;
		}

		for (int i = 0; i < dto.getItems().size(); i++) {
			SemanticModelImportItem item = dto.getItems().get(i);
			try {
				SemanticModel existing = semanticModelMapper.selectByAgentIdAndDatasourceIdAndTableNameAndColumnName(
						dto.getAgentId(), dto.getDatasourceId(), item.getTableName(), item.getColumnName());

				if (existing != null) {
					result.setFailCount(result.getFailCount() + 1);
					result.addError(buildDuplicateImportMessage(i + 1, item));
					continue;
				}

				SemanticModel newModel = SemanticModel.builder()
					.agentId(dto.getAgentId())
					.datasourceId(dto.getDatasourceId())
					.tableName(item.getTableName())
					.columnName(item.getColumnName())
					.businessName(item.getBusinessName())
					.synonyms(item.getSynonyms())
					.businessDescription(item.getBusinessDescription())
					.columnComment(item.getColumnComment())
					.dataType(item.getDataType())
					.status(true)
					.createdTime(item.getCreateTime() != null ? item.getCreateTime() : LocalDateTime.now())
					.build();
				insertSemanticModel(newModel, buildDuplicateImportMessage(i + 1, item));
				log.info("插入语义模型: agentId={}, datasourceId={}, tableName={}, columnName={}", dto.getAgentId(),
						dto.getDatasourceId(), item.getTableName(), item.getColumnName());

				result.setSuccessCount(result.getSuccessCount() + 1);
			}
			catch (Exception e) {
				log.error("导入第{}条记录失败: datasourceId={}, tableName={}, columnName={}", i + 1, dto.getDatasourceId(),
						item.getTableName(), item.getColumnName(), e);
				result.setFailCount(result.getFailCount() + 1);
				result.addError(String.format("第%d条记录导入失败（%s.%s）: %s", i + 1, item.getTableName(), item.getColumnName(),
						e.getMessage()));
			}
		}

		return result;
	}

	@Override
	public BatchImportResult importFromExcel(InputStream inputStream, String filename, Long agentId,
			Integer datasourceId) {
		log.info("开始Excel导入: agentId={}, datasourceId={}, 文件={}", agentId, datasourceId, filename);

		try {
			List<SemanticModelImportItem> items = excelService.parseExcel(inputStream, filename);

			SemanticModelBatchImportDTO dto = SemanticModelBatchImportDTO.builder()
				.agentId(agentId)
				.datasourceId(datasourceId)
				.items(items)
				.build();

			BatchImportResult result = batchImport(dto);
			log.info("Excel导入完成: 总数={}, 成功={}, 失败={}", result.getTotal(), result.getSuccessCount(),
					result.getFailCount());

			return result;
		}
		catch (Exception e) {
			log.error("Excel导入失败", e);
			BatchImportResult result = BatchImportResult.builder().total(0).successCount(0).failCount(0).build();
			result.addError("Excel导入失败: " + e.getMessage());
			return result;
		}
	}

	@Override
	public void updateSemanticModel(Long id, SemanticModelUpdateDTO semanticModelUpdateDto) {
		SemanticModel existing = semanticModelMapper.selectById(id);
		if (existing == null) {
			throw new IllegalArgumentException("Semantic model not found");
		}
		existing.setBusinessName(semanticModelUpdateDto.getBusinessName());
		existing.setSynonyms(semanticModelUpdateDto.getSynonyms());
		existing.setBusinessDescription(semanticModelUpdateDto.getBusinessDescription());
		existing.setColumnComment(semanticModelUpdateDto.getColumnComment());
		existing.setDataType(semanticModelUpdateDto.getDataType());
		semanticModelMapper.updateById(existing);
	}

	private List<String> normalizeTableNames(List<String> tableNames) {
		return tableNames.stream()
			.filter(StringUtils::hasText)
			.map(String::trim)
			.map(tableName -> tableName.toLowerCase(Locale.ROOT))
			.distinct()
			.toList();
	}

	private void insertSemanticModel(SemanticModel semanticModel, String duplicateMessage) {
		try {
			semanticModelMapper.insert(semanticModel);
		}
		catch (DuplicateKeyException e) {
			throw new IllegalArgumentException(duplicateMessage, e);
		}
	}

	private String buildDuplicateImportMessage(int rowNumber, SemanticModelImportItem item) {
		return String.format("第%d条记录已存在，请修改后再导入（%s.%s）", rowNumber, item.getTableName(), item.getColumnName());
	}

}

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
package com.alibaba.cloud.ai.dataagent.controller;

import com.alibaba.cloud.ai.dataagent.dto.ChatMessageDTO;
import com.alibaba.cloud.ai.dataagent.dto.ModelConfigDTO;
import com.alibaba.cloud.ai.dataagent.entity.ChatMessage;
import com.alibaba.cloud.ai.dataagent.entity.ChatSession;
import com.alibaba.cloud.ai.dataagent.enums.ModelType;
import com.alibaba.cloud.ai.dataagent.exception.InvalidInputException;
import com.alibaba.cloud.ai.dataagent.observability.AnswerTraceExplainStore;
import com.alibaba.cloud.ai.dataagent.observability.SessionTraceStore;
import com.alibaba.cloud.ai.dataagent.service.aimodelconfig.ModelConfigDataService;
import com.alibaba.cloud.ai.dataagent.service.chat.ChatMessageService;
import com.alibaba.cloud.ai.dataagent.service.chat.ChatSessionService;
import com.alibaba.cloud.ai.dataagent.service.chat.SessionTitleService;
import com.alibaba.cloud.ai.dataagent.util.ReportTemplateUtil;
import com.alibaba.cloud.ai.dataagent.vo.ApiResponse;
import com.alibaba.cloud.ai.dataagent.vo.SessionContextUsageVO;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.knuddels.jtokkit.Encodings;
import com.knuddels.jtokkit.api.Encoding;
import com.knuddels.jtokkit.api.EncodingType;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;
import java.util.Map;

/**
 * Chat Controller
 */
@Slf4j
@RestController
@RequestMapping("/api")
@CrossOrigin(origins = "*")
@RequiredArgsConstructor
public class ChatController {

	private static final String ANSWER_EXPLAIN_MESSAGE_TYPE = "answer-explain";

	private static final long DEFAULT_CONTEXT_WINDOW_TOKENS = 32768L;

	private static final Encoding TOKEN_ENCODING = Encodings.newDefaultEncodingRegistry()
		.getEncoding(EncodingType.CL100K_BASE);

	private final ChatSessionService chatSessionService;

	private final ChatMessageService chatMessageService;

	private final ModelConfigDataService modelConfigDataService;

	private final SessionTitleService sessionTitleService;

	private final ReportTemplateUtil reportTemplateUtil;

	private final SessionTraceStore sessionTraceStore;

	private final AnswerTraceExplainStore answerTraceExplainStore;

	private final ObjectMapper objectMapper;

	/**
	 * Get session list for an agent
	 */
	@GetMapping("/agent/{id}/sessions")
	public ResponseEntity<List<ChatSession>> getAgentSessions(@PathVariable(value = "id") Integer id) {
		List<ChatSession> sessions = chatSessionService.findByAgentId(id);
		return ResponseEntity.ok(sessions);
	}

	/**
	 * Create a new session
	 */
	@PostMapping("/agent/{id}/sessions")
	public ResponseEntity<ChatSession> createSession(@PathVariable(value = "id") Integer id,
			@RequestBody(required = false) Map<String, Object> request) {
		String title = request != null ? (String) request.get("title") : null;
		Long userId = request != null ? parseUserId(request.get("userId")) : null;

		ChatSession session = chatSessionService.createSession(id, title, userId);
		return ResponseEntity.ok(session);
	}

	private Long parseUserId(Object rawUserId) {
		if (rawUserId == null) {
			return null;
		}
		if (rawUserId instanceof Number number) {
			return number.longValue();
		}
		if (rawUserId instanceof String value) {
			String trimmedValue = value.trim();
			if (!StringUtils.hasText(trimmedValue)) {
				return null;
			}
			try {
				return Long.valueOf(trimmedValue);
			}
			catch (NumberFormatException ex) {
				throw new InvalidInputException("userId 必须是数字", rawUserId);
			}
		}
		throw new InvalidInputException("userId 类型不合法", rawUserId);
	}

	/**
	 * Clear all sessions for an agent
	 */
	@DeleteMapping("/agent/{id}/sessions")
	public ResponseEntity<ApiResponse> clearAgentSessions(@PathVariable(value = "id") Integer id) {
		chatSessionService.clearSessionsByAgentId(id);
		return ResponseEntity.ok(ApiResponse.success("会话已清空"));
	}

	/**
	 * Get message list for a session
	 */
	@GetMapping("/sessions/{sessionId}/messages")
	public ResponseEntity<List<ChatMessage>> getSessionMessages(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId) {
		List<ChatMessage> messages = chatMessageService.findVisibleBySessionId(sessionId, agentId);
		return ResponseEntity.ok(messages);
	}

	@GetMapping("/sessions/{sessionId}/context")
	public ResponseEntity<SessionContextUsageVO> getSessionContextUsage(
			@PathVariable(value = "sessionId") String sessionId, @RequestParam(value = "agentId") Long agentId,
			@RequestParam(value = "chatModelConfigId", required = false) Integer chatModelConfigId) {
		chatSessionService.requireSessionForAgent(sessionId, agentId);
		List<ChatMessage> messages = chatMessageService.findVisibleBySessionId(sessionId, agentId);
		ModelConfigDTO modelConfig = resolveChatModelConfig(chatModelConfigId);
		long usedTokens = messages.stream().mapToLong(this::countMessageTokens).sum();
		long limitTokens = resolveContextWindowTokens(modelConfig);
		double usageRatio = limitTokens > 0 ? Math.min(1D, usedTokens / (double) limitTokens) : 0D;
		return ResponseEntity.ok(SessionContextUsageVO.builder()
			.usedTokens(usedTokens)
			.limitTokens(limitTokens)
			.usageRatio(usageRatio)
			.messageCount(messages.size())
			.estimated(true)
			.modelName(modelConfig == null ? null : modelConfig.getModelName())
			.chatModelConfigId(modelConfig == null ? null : modelConfig.getId())
			.build());
	}

	@GetMapping("/sessions/{sessionId}/trace")
	public ResponseEntity<?> getLatestSessionTrace(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId) {
		chatSessionService.requireSessionForAgent(sessionId, agentId);
		return sessionTraceStore.getLatestTrace(sessionId)
			.<ResponseEntity<?>>map(ResponseEntity::ok)
			.orElseGet(() -> ResponseEntity.notFound().build());
	}

	@GetMapping("/sessions/{sessionId}/answers/latest/explain")
	public ResponseEntity<?> getLatestAnswerExplain(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId) {
		chatSessionService.requireSessionForAgent(sessionId, agentId);
		return answerTraceExplainStore.getLatestExplain(sessionId)
			.<ResponseEntity<?>>map(ResponseEntity::ok)
			.or(() -> loadLatestPersistedAnswerExplain(sessionId, agentId).map(ResponseEntity::ok))
			.orElseGet(() -> ResponseEntity.notFound().build());
	}

	@GetMapping("/sessions/{sessionId}/answers/{runtimeRequestId}/explain")
	public ResponseEntity<?> getAnswerExplain(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId,
			@PathVariable(value = "runtimeRequestId") String runtimeRequestId) {
		chatSessionService.requireSessionForAgent(sessionId, agentId);
		return answerTraceExplainStore.getExplain(sessionId, runtimeRequestId)
			.<ResponseEntity<?>>map(ResponseEntity::ok)
			.or(() -> loadPersistedAnswerExplain(sessionId, runtimeRequestId, agentId).map(ResponseEntity::ok))
			.orElseGet(() -> ResponseEntity.notFound().build());
	}

	private java.util.Optional<JsonNode> loadLatestPersistedAnswerExplain(String sessionId, Long agentId) {
		List<ChatMessage> snapshots = chatMessageService.findBySessionIdAndMessageType(sessionId,
				ANSWER_EXPLAIN_MESSAGE_TYPE, agentId);
		JsonNode latestExplainNode = null;
		long latestUpdatedAt = Long.MIN_VALUE;
		for (ChatMessage snapshot : snapshots) {
			if (snapshot == null || !StringUtils.hasText(snapshot.getContent())) {
				continue;
			}
			try {
				JsonNode explainNode = objectMapper.readTree(snapshot.getContent());
				long updatedAt = explainNode.path("updatedAt").asLong(Long.MIN_VALUE);
				if (latestExplainNode == null || updatedAt >= latestUpdatedAt) {
					latestExplainNode = explainNode;
					latestUpdatedAt = updatedAt;
				}
			}
			catch (Exception ex) {
				log.warn("Failed to parse persisted answer explain snapshot. sessionId={}, messageId={}", sessionId,
						snapshot.getId(), ex);
			}
		}
		return java.util.Optional.ofNullable(latestExplainNode);
	}

	private java.util.Optional<JsonNode> loadPersistedAnswerExplain(String sessionId, String runtimeRequestId,
			Long agentId) {
		if (!StringUtils.hasText(sessionId) || !StringUtils.hasText(runtimeRequestId)) {
			return java.util.Optional.empty();
		}
		List<ChatMessage> snapshots = chatMessageService.findBySessionIdAndMessageType(sessionId,
				ANSWER_EXPLAIN_MESSAGE_TYPE, agentId);
		for (ChatMessage snapshot : snapshots) {
			if (snapshot == null || !StringUtils.hasText(snapshot.getContent())) {
				continue;
			}
			try {
				JsonNode explainNode = objectMapper.readTree(snapshot.getContent());
				if (runtimeRequestId.equals(explainNode.path("runtimeRequestId").asText())) {
					return java.util.Optional.of(explainNode);
				}
			}
			catch (Exception ex) {
				log.warn("Failed to parse persisted answer explain snapshot. sessionId={}, messageId={}", sessionId,
						snapshot.getId(), ex);
			}
		}
		return java.util.Optional.empty();
	}

	private ModelConfigDTO resolveChatModelConfig(Integer chatModelConfigId) {
		if (chatModelConfigId != null) {
			return modelConfigDataService.getConfigById(chatModelConfigId, ModelType.CHAT);
		}
		return modelConfigDataService.getActiveConfigByType(ModelType.CHAT);
	}

	private long resolveContextWindowTokens(ModelConfigDTO modelConfig) {
		if (modelConfig == null || modelConfig.getContextWindowTokens() == null
				|| modelConfig.getContextWindowTokens() <= 0) {
			return DEFAULT_CONTEXT_WINDOW_TOKENS;
		}
		return modelConfig.getContextWindowTokens();
	}

	private long countMessageTokens(ChatMessage message) {
		if (message == null) {
			return 0L;
		}
		StringBuilder tokenText = new StringBuilder();
		appendTokenText(tokenText, message.getRole());
		appendTokenText(tokenText, message.getMessageType());
		appendTokenText(tokenText, message.getContent());
		if (tokenText.length() == 0) {
			return 0L;
		}
		return TOKEN_ENCODING.countTokens(tokenText.toString());
	}

	private void appendTokenText(StringBuilder builder, String value) {
		if (!StringUtils.hasText(value)) {
			return;
		}
		if (builder.length() > 0) {
			builder.append('\n');
		}
		builder.append(value);
	}

	/**
	 * Save message to session
	 */
	@PostMapping("/sessions/{sessionId}/messages")
	public ResponseEntity<ChatMessage> saveMessage(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId, @RequestBody ChatMessageDTO request) {
		try {
			if (request == null) {
				return ResponseEntity.badRequest().build();
			}
			ChatMessage message = ChatMessage.builder()
				.sessionId(sessionId)
				.role(request.getRole())
				.content(request.getContent())
				.messageType(request.getMessageType())
				.metadata(request.getMetadata())
				.build();

			ChatMessage savedMessage = chatMessageService.saveMessage(message, agentId);

			// Update session activity time
			chatSessionService.updateSessionTime(sessionId, agentId);

			if (shouldGenerateTitle(request, savedMessage)) {
				sessionTitleService.scheduleTitleGeneration(sessionId, message.getContent());
			}

			return ResponseEntity.ok(savedMessage);
		}
		catch (ResponseStatusException ex) {
			throw ex;
		}
		catch (Exception e) {
			log.error("Save message error for session {}: {}", sessionId, e.getMessage(), e);
			return ResponseEntity.internalServerError().build();
		}
	}

	/**
	 * 置顶/取消置顶会话
	 */
	@PutMapping("/sessions/{sessionId}/pin")
	public ResponseEntity<ApiResponse> pinSession(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId, @RequestParam(value = "isPinned") Boolean isPinned) {
		try {
			chatSessionService.pinSession(sessionId, isPinned, agentId);
			String message = isPinned ? "会话已置顶" : "会话已取消置顶";
			return ResponseEntity.ok(ApiResponse.success(message));
		}
		catch (ResponseStatusException ex) {
			throw ex;
		}
		catch (Exception e) {
			log.error("Pin session error for session {}: {}", sessionId, e.getMessage(), e);
			return ResponseEntity.internalServerError().body(ApiResponse.error("操作失败"));
		}
	}

	/**
	 * Rename session
	 */
	@PutMapping("/sessions/{sessionId}/rename")
	public ResponseEntity<ApiResponse> renameSession(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId, @RequestParam(value = "title") String title) {
		try {
			if (!StringUtils.hasText(title)) {
				return ResponseEntity.badRequest().body(ApiResponse.error("标题不能为空"));
			}

			chatSessionService.renameSession(sessionId, title.trim(), agentId);
			return ResponseEntity.ok(ApiResponse.success("会话已重命名"));
		}
		catch (ResponseStatusException ex) {
			throw ex;
		}
		catch (Exception e) {
			log.error("Rename session error for session {}: {}", sessionId, e.getMessage(), e);
			return ResponseEntity.internalServerError().body(ApiResponse.error("重命名失败"));
		}
	}

	/**
	 * Delete a single session
	 */
	@DeleteMapping("/sessions/{sessionId}")
	public ResponseEntity<ApiResponse> deleteSession(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId) {
		try {
			chatSessionService.deleteSession(sessionId, agentId);
			return ResponseEntity.ok(ApiResponse.success("会话已删除"));
		}
		catch (ResponseStatusException ex) {
			throw ex;
		}
		catch (Exception e) {
			log.error("Delete session error for session {}: {}", sessionId, e.getMessage(), e);
			return ResponseEntity.internalServerError().body(ApiResponse.error("删除失败"));
		}
	}

	/**
	 * Download HTML report
	 */
	@PostMapping("/sessions/{sessionId}/reports/html")
	public ResponseEntity<byte[]> convertAndDownloadHtml(@PathVariable(value = "sessionId") String sessionId,
			@RequestParam(value = "agentId") Long agentId, @RequestBody String content) {
		try {
			if (!StringUtils.hasText(content)) {
				return ResponseEntity.badRequest().build();
			}
			chatSessionService.requireSessionForAgent(sessionId, agentId);
			log.debug("Download HTML report for session {}", sessionId);
			StringBuilder htmlContent = new StringBuilder();
			htmlContent.append(reportTemplateUtil.getHeader());
			htmlContent.append(content);
			htmlContent.append(reportTemplateUtil.getFooter());
			String timestamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMddHHmmss"));
			String filename = "report_" + timestamp + ".html";
			HttpHeaders headers = new HttpHeaders();
			headers.setContentType(new MediaType("text", "html", StandardCharsets.UTF_8));
			headers.setContentDispositionFormData("attachment", filename);
			return ResponseEntity.ok().headers(headers).body(htmlContent.toString().getBytes(StandardCharsets.UTF_8));
		}
		catch (ResponseStatusException ex) {
			throw ex;
		}
		catch (Exception e) {
			log.error("Download HTML report error for session {}: {}", sessionId, e.getMessage(), e);
			return ResponseEntity.internalServerError().build();
		}
	}

	private boolean shouldGenerateTitle(ChatMessageDTO request, ChatMessage savedMessage) {
		if (request == null || savedMessage == null) {
			return false;
		}
		if (request.isTitleNeeded()) {
			return true;
		}
		if (!"user".equalsIgnoreCase(request.getRole())) {
			return false;
		}
		List<ChatMessage> sessionMessages = chatMessageService.findBySessionId(savedMessage.getSessionId());
		return sessionMessages.size() == 1;
	}

}

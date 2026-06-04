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

import com.alibaba.cloud.ai.dataagent.agentscope.dto.AgentRequest;
import com.alibaba.cloud.ai.dataagent.agentscope.service.AgentService;
import com.alibaba.cloud.ai.dataagent.agentscope.vo.AgentResponse;
import lombok.AllArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.http.codec.ServerSentEvent;
import org.springframework.web.bind.annotation.CrossOrigin;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Sinks;
import com.alibaba.cloud.ai.dataagent.service.chat.ChatSessionService;

import static com.alibaba.cloud.ai.dataagent.constant.Constant.STREAM_EVENT_COMPLETE;
import static com.alibaba.cloud.ai.dataagent.constant.Constant.STREAM_EVENT_ERROR;

@Slf4j
@RestController
@AllArgsConstructor
@CrossOrigin(origins = "*")
@RequestMapping("/api")
public class DataAgentController {

	private final AgentService agentService;

	private final ChatSessionService chatSessionService;

	@GetMapping(value = "/stream/search", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
	public ResponseEntity<Flux<ServerSentEvent<AgentResponse>>> streamSearch(@RequestParam("agentId") String agentId,
			@RequestParam("threadId") String threadId,
			@RequestParam(value = "runtimeRequestId", required = false) String runtimeRequestId,
			@RequestParam("query") String query,
			@RequestParam(value = "clarifyCheckEnabled", required = false) boolean clarifyCheckEnabled,
			@RequestParam(value = "humanFeedback", required = false) boolean humanFeedback,
			@RequestParam(value = "humanFeedbackContent", required = false) String humanFeedbackContent,
			@RequestParam(value = "rejectedPlan", required = false) boolean rejectedPlan) {
		Long numericAgentId = parseAgentId(agentId);
		chatSessionService.requireSessionForAgent(threadId, numericAgentId);

		Sinks.Many<ServerSentEvent<AgentResponse>> sink = Sinks.many().unicast().onBackpressureBuffer();
		AgentRequest request = AgentRequest.builder()
			.agentId(agentId)
			.threadId(threadId)
			.runtimeRequestId(runtimeRequestId)
			.query(query)
			.clarifyCheckEnabled(clarifyCheckEnabled)
			.humanFeedback(humanFeedback)
			.humanFeedbackContent(humanFeedbackContent)
			.rejectedPlan(rejectedPlan)
			.build();
		agentService.graphStreamProcess(sink, request);

		Flux<ServerSentEvent<AgentResponse>> stream = sink.asFlux().filter(sse -> {
			if (STREAM_EVENT_COMPLETE.equals(sse.event()) || STREAM_EVENT_ERROR.equals(sse.event())) {
				return true;
			}
			return sse.data() != null && sse.data().getText() != null && !sse.data().getText().isEmpty();
		})
			.doOnSubscribe(subscription -> log.info("Client subscribed to aiagent stream, threadId: {}",
					request.getThreadId()))
			.doOnCancel(() -> {
				log.info("Client disconnected from aiagent stream, threadId: {}", request.getThreadId());
				if (request.getThreadId() != null && request.getRuntimeRequestId() != null) {
					agentService.stopStreamProcessing(request.getThreadId(), request.getRuntimeRequestId());
				}
			})
			.doOnError(error -> {
				log.error("Error occurred during aiagent streaming, threadId: {}", request.getThreadId(), error);
				if (request.getThreadId() != null && request.getRuntimeRequestId() != null) {
					agentService.stopStreamProcessing(request.getThreadId(), request.getRuntimeRequestId());
				}
			})
			.doOnComplete(() -> log.info("Aiagent stream completed successfully, threadId: {}", request.getThreadId()));
		return ResponseEntity.ok()
			.contentType(MediaType.TEXT_EVENT_STREAM)
			.header("Cache-Control", "no-cache")
			.header("Connection", "keep-alive")
			.header("Access-Control-Allow-Origin", "*")
			.body(stream);
	}

	private Long parseAgentId(String agentId) {
		try {
			return Long.valueOf(agentId);
		}
		catch (NumberFormatException ex) {
			throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "agentId must be numeric", ex);
		}
	}

}

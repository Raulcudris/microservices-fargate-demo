package com.makiia.gatewayservice.controller;

import com.makiia.gatewayservice.dto.HealthResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.time.LocalDateTime;

@RestController
public class HealthController {
    @GetMapping("/health")
    public Mono<HealthResponse> health() {
        return Mono.just(
                new HealthResponse(
                        "UP",
                        "gateway-service",
                        LocalDateTime.now().toString()
                )
        );
    }
}
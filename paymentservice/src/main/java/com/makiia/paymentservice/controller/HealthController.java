package com.makiia.paymentservice.controller;

import com.makiia.paymentservice.dto.HealthResponse;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDateTime;

@RestController
@RequestMapping("/api/health")
public class HealthController {
    public ResponseEntity<HealthResponse> health() {
        HealthResponse response = new HealthResponse(
                "UP",
                "Payments Services",
                LocalDateTime.now().toString()
        );
        return ResponseEntity.ok(response);
    }
}
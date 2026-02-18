package com.makiia.orderservice.controller;
import com.makiia.orderservice.dto.HealthResponse;
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
                "Order Service",
                LocalDateTime.now().toString()
        );
        return ResponseEntity.ok(response);
    }
}
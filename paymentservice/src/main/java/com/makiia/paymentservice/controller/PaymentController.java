package com.makiia.paymentservice.controller;

import com.makiia.paymentservice.dto.HealthResponse;
import com.makiia.paymentservice.dto.PaymentRequestDto;
import com.makiia.paymentservice.dto.PaymentResponseDto;
import com.makiia.paymentservice.service.PaymentService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDateTime;
import java.util.List;

@RestController
@RequestMapping("/payments")
public class PaymentController {

    private final PaymentService paymentService;

    public PaymentController(PaymentService paymentService) {
        this.paymentService = paymentService;
    }

    // =============================
    // HEALTH ENDPOINT
    // =============================
    @GetMapping("/health")
    public ResponseEntity<HealthResponse> health() {
        HealthResponse response = new HealthResponse(
                "UP",
                "Payments Service",
                LocalDateTime.now().toString()
        );

        return ResponseEntity.ok(response);
    }

    // 💳 PROCESAR PAGO
    @PostMapping
    public ResponseEntity<PaymentResponseDto> processPayment(
            @RequestBody PaymentRequestDto dto) {

        return ResponseEntity.ok(paymentService.processPayment(dto));
    }

    // 🔍 GET ALL
    @GetMapping
    public ResponseEntity<List<PaymentResponseDto>> getAll() {
        return ResponseEntity.ok(paymentService.getAll());
    }

    // 🔍 GET BY ID
    @GetMapping("/{id}")
    public ResponseEntity<PaymentResponseDto> getById(@PathVariable Long id) {
        return ResponseEntity.ok(paymentService.getById(id));
    }
}

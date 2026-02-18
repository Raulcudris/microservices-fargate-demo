package com.makiia.paymentservice.service;

import com.makiia.paymentservice.dto.PaymentRequestDto;
import com.makiia.paymentservice.dto.PaymentResponseDto;
import com.makiia.paymentservice.entity.Payment;
import com.makiia.paymentservice.entity.PaymentStatus;
import com.makiia.paymentservice.repository.PaymentRepository;
import org.springframework.stereotype.Service;

import java.util.Random;
import java.util.stream.Collectors;

@Service
public class PaymentService {

    private final PaymentRepository paymentRepository;

    public PaymentService(PaymentRepository paymentRepository) {
        this.paymentRepository = paymentRepository;
    }

    // 💳 Procesar pago
    public PaymentResponseDto processPayment(PaymentRequestDto dto) {

        boolean approved = new Random().nextBoolean();

        PaymentStatus status = approved
                ? PaymentStatus.APPROVED
                : PaymentStatus.REJECTED;

        Payment payment = Payment.builder()
                .orderId(dto.getOrderId())
                .amount(dto.getAmount())
                .method(dto.getMethod())
                .status(status)
                .build();

        Payment saved = paymentRepository.save(payment);

        return PaymentResponseDto.builder()
                .paymentId(saved.getId())
                .orderId(saved.getOrderId())
                .amount(saved.getAmount())
                .method(saved.getMethod())
                .status(saved.getStatus().name())
                .createdAt(saved.getCreatedAt())
                .build();
    }

    // 🔍 Obtener todos
    public java.util.List<PaymentResponseDto> getAll() {
        return paymentRepository.findAll()
                .stream()
                .map(this::mapToDto)
                .collect(Collectors.toList());
    }

    // 🔍 Obtener por ID
    public PaymentResponseDto getById(Long id) {
        Payment payment = paymentRepository.findById(id)
                .orElseThrow(() -> new RuntimeException("Pago no encontrado"));
        return mapToDto(payment);
    }

    private PaymentResponseDto mapToDto(Payment payment) {
        return PaymentResponseDto.builder()
                .paymentId(payment.getId())
                .orderId(payment.getOrderId())
                .amount(payment.getAmount())
                .method(payment.getMethod())
                .status(payment.getStatus().name())
                .createdAt(payment.getCreatedAt())
                .build();
    }
}

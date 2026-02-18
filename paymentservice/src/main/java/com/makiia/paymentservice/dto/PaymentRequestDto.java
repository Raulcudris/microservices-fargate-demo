package com.makiia.paymentservice.dto;

import lombok.Data;
import java.math.BigDecimal;

@Data
public class PaymentRequestDto {
    private Long orderId;
    private BigDecimal amount;
    private String method; // CARD, CASH, WHATSAPP, etc.
}

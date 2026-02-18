package com.makiia.orderservice.dto;

import lombok.Builder;
import lombok.Data;
import java.math.BigDecimal;

@Data
@Builder
public class OrderResponseDto {
    private Long orderId;
    private BigDecimal total;
    private String status;
}

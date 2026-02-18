package com.makiia.orderservice.dto;

import lombok.Data;

@Data
public class OrderItemDto {
    private Integer productId;
    private Integer quantity;
}

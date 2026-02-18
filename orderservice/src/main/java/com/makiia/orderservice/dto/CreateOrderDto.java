package com.makiia.orderservice.dto;

import lombok.Data;
import java.util.List;

@Data
public class CreateOrderDto {

    private Long customerId;
    private String contactPhone;
    private String notes;
    private List<OrderItemDto> items;
}

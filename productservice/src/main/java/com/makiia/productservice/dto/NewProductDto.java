package com.makiia.productservice.dto;
import lombok.Data;
import java.math.BigDecimal;

@Data
public class NewProductDto {
    private String name;
    private String description;
    private BigDecimal price;
    private Integer stock;
    private Integer categoryId;
}

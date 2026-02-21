package com.makiia.productservice.controller;

import com.makiia.productservice.dto.NewProductDto;
import com.makiia.productservice.dto.ProductsDto;
import com.makiia.productservice.service.ProductsService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/products")
public class ProductController {

    private final ProductsService productsService;

    public ProductController(ProductsService productsService) {
        this.productsService = productsService;
    }

    @GetMapping
    public ResponseEntity<List<ProductsDto>> getAll() {
        return ResponseEntity.ok(productsService.getAll());
    }

    @GetMapping("/{id}")
    public ResponseEntity<ProductsDto> getById(@PathVariable Integer id) {
        return ResponseEntity.ok(productsService.getById(id));
    }

    @PostMapping
    public ResponseEntity<ProductsDto> save(@RequestBody NewProductDto dto) {
        return ResponseEntity
                .status(HttpStatus.CREATED)
                .body(productsService.save(dto));
    }
}

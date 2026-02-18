package com.makiia.productservice.service;

import com.makiia.productservice.dto.NewProductDto;
import com.makiia.productservice.dto.ProductsDto;
import com.makiia.productservice.entity.Categories;
import com.makiia.productservice.entity.Products;
import com.makiia.productservice.repository.CategoriesRepository;
import com.makiia.productservice.repository.ProductsRepository;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.stream.Collectors;

@Service
public class ProductsService {

    private final ProductsRepository productsRepository;
    private final CategoriesRepository categoriesRepository;

    public ProductsService(ProductsRepository productsRepository,
                           CategoriesRepository categoriesRepository) {
        this.productsRepository = productsRepository;
        this.categoriesRepository = categoriesRepository;
    }

    public List<ProductsDto> getAll() {
        return productsRepository.findAll()
                .stream()
                .map(this::mapToDto)
                .collect(Collectors.toList());
    }

    public ProductsDto getById(Integer id) {
        Products product = productsRepository.findById(id)
                .orElseThrow(() -> new RuntimeException("Producto no encontrado"));

        return ProductsDto.builder()
                .id(product.getId())
                .name(product.getName())
                .description(product.getDescription())
                .price(product.getPrice())
                .stock(product.getStock())
                .category(
                        product.getCategory() != null
                                ? product.getCategory().getName()
                                : null
                )
                .build();
    }


    public ProductsDto save(NewProductDto dto) {
        Categories category = categoriesRepository.findById(dto.getCategoryId())
                .orElseThrow(() -> new RuntimeException("Categoría no encontrada"));

        Products product = new Products();
        product.setName(dto.getName());
        product.setDescription(dto.getDescription());
        product.setPrice(dto.getPrice());
        product.setStock(dto.getStock());
        product.setCategory(category);

        return mapToDto(productsRepository.save(product));
    }

    private ProductsDto mapToDto(Products product) {
        return ProductsDto.builder()
                .id(product.getId())
                .name(product.getName())
                .description(product.getDescription())
                .price(product.getPrice())
                .stock(product.getStock())
                .category(product.getCategory().getName())
                .build();
    }
}

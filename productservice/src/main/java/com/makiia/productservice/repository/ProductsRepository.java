package com.makiia.productservice.repository;
import com.makiia.productservice.entity.Products;
import org.springframework.data.jpa.repository.JpaRepository;


public interface ProductsRepository extends JpaRepository<Products,Integer > {

}

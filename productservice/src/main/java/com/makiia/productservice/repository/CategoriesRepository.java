package com.makiia.productservice.repository;
import com.makiia.productservice.entity.Categories;
import org.springframework.data.jpa.repository.JpaRepository;

public interface CategoriesRepository extends JpaRepository<Categories, Integer> {

}

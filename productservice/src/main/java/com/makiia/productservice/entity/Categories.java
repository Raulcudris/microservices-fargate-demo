package com.makiia.productservice.entity;
import lombok.Data;
import javax.persistence.*;

@Data
@Entity
@Table(name = "categories")
public class Categories {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Integer id;

    private String name;
}

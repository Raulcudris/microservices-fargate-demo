package com.makiia.userservice.repository;

import com.makiia.userservice.entity.EntityUsers;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface EntityUsersRepository extends JpaRepository<EntityUsers, Integer> {
    String FILTER_USERNAME_QUERY = "SELECT c FROM EntityUsers c  WHERE c.username  = :username";
    @Query(value = FILTER_USERNAME_QUERY)
    Optional<EntityUsers> findByUserName(@Param("username")  String username);
}
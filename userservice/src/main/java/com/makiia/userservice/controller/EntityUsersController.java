package com.makiia.userservice.controller;
import com.makiia.userservice.dto.*;
import com.makiia.userservice.entity.EntityUsers;
import com.makiia.userservice.service.EntityUsersService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDateTime;

@RestController
@RequestMapping("/users")
public class EntityUsersController {
    @Autowired
    EntityUsersService entityUsersService;

    // =============================
    // HEALTH ENDPOINT
    // =============================
    @GetMapping("/health")
    public ResponseEntity<HealthResponse> health() {
        HealthResponse response = new HealthResponse(
                "UP",
                "Users Service",
                LocalDateTime.now().toString()
        );

        return ResponseEntity.ok(response);
    }


    @PostMapping("/login")
    public ResponseEntity<TokenDto> login(@RequestBody EntityUsersDto dto){
        TokenDto tokenDto = entityUsersService.login(dto);
        if(tokenDto == null)
            return ResponseEntity.badRequest().build();
        return ResponseEntity.ok(tokenDto);
    }

    @PostMapping("/validate")
    public ResponseEntity<TokenDto> validate(@RequestParam String token, @RequestBody RequestDto dto){
        TokenDto tokenDto = entityUsersService.validate(token, dto);
        if(tokenDto == null)
            return ResponseEntity.badRequest().build();
        return ResponseEntity.ok(tokenDto);
    }

    @PostMapping("/create")
    public ResponseEntity<EntityUsers> create(@RequestBody NewUserDto dto){
        EntityUsers authUser = entityUsersService.save(dto);
        if(authUser == null)
            return ResponseEntity.badRequest().build();
        return ResponseEntity.ok(authUser);
    }

}
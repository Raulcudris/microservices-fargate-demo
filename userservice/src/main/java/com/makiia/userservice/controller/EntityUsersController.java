package com.makiia.userservice.controller;

import com.makiia.userservice.dto.EntityUsersDto;
import com.makiia.userservice.dto.NewUserDto;
import com.makiia.userservice.dto.RequestDto;
import com.makiia.userservice.dto.TokenDto;
import com.makiia.userservice.entity.EntityUsers;
import com.makiia.userservice.service.EntityUsersService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/users")
public class EntityUsersController {
    @Autowired
    EntityUsersService entityUsersService;

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
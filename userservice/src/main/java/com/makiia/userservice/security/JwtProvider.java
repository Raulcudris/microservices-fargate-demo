package com.makiia.userservice.security;

import com.makiia.userservice.dto.RequestDto;
import com.makiia.userservice.entity.EntityUsers;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.annotation.PostConstruct;
import java.util.Base64;
import java.util.Date;
import java.util.HashMap;
import java.util.Map;

@Component
public class JwtProvider {

    @Value("${jwt.secret}")
    private String secret;

    @Autowired
    RouteValidator routeValidator;

    @PostConstruct
    protected void init() {
        secret = Base64.getEncoder().encodeToString(secret.getBytes());
    }

    public String createToken(EntityUsers entityUsers) {
        Map<String, Object> claims = new HashMap<>();
        claims = Jwts.claims().setSubject(entityUsers.getUsername());
        claims.put("id", entityUsers.getId());
        claims.put("role", entityUsers.getRole());

        Date now = new Date();
        Date exp = new Date(now.getTime() + 3600000);

        return Jwts.builder()
                .setClaims(claims)
                .setIssuedAt(now)
                .setExpiration(exp)
                .signWith(SignatureAlgorithm.HS256, secret)
                .compact();
    }

    public boolean validate(String token, RequestDto dto) {
        try {
            Jwts.parser().setSigningKey(secret).parseClaimsJws(token);
        } catch (Exception e) {
            return false;
        }

        if (!isAdmin(token) && routeValidator.isAdminPath(dto)) {
            return false;
        }
        return true;
    }

    public String getUserNameFromToken(String token) {
        try {
            return Jwts.parser().setSigningKey(secret).parseClaimsJws(token).getBody().getSubject();
        } catch (Exception e) {
            return "bad token";
        }
    }

    public Integer getUserIdFromToken(String token) {
        try {
            Object id = Jwts.parser().setSigningKey(secret).parseClaimsJws(token).getBody().get("id");
            if (id instanceof Integer) return (Integer) id;
            if (id instanceof Number) return ((Number) id).intValue();
            return Integer.parseInt(String.valueOf(id));
        } catch (Exception e) {
            return null;
        }
    }

    public String getRoleFromToken(String token) {
        try {
            Object role = Jwts.parser().setSigningKey(secret).parseClaimsJws(token).getBody().get("role");
            return String.valueOf(role);
        } catch (Exception e) {
            return null;
        }
    }

    private boolean isAdmin(String token) {
        return String.valueOf(
                Jwts.parser().setSigningKey(secret).parseClaimsJws(token).getBody().get("role")
        ).equals("ADMIN");
    }
}

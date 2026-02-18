package com.makiia.gatewayservice.config;

import com.makiia.gatewayservice.dto.RequestDto;
import com.makiia.gatewayservice.dto.TokenDto;
import org.springframework.cloud.gateway.filter.GatewayFilter;
import org.springframework.cloud.gateway.filter.factory.AbstractGatewayFilterFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

@Component
public class AuthFilter extends AbstractGatewayFilterFactory<AuthFilter.Config> {

    private final WebClient.Builder webClient;

    public AuthFilter(WebClient.Builder webClient) {
        super(Config.class);
        this.webClient = webClient;
    }

    @Override
    public GatewayFilter apply(Config config) {
        return (exchange, chain) -> {

            String authHeader = exchange.getRequest()
                    .getHeaders()
                    .getFirst(HttpHeaders.AUTHORIZATION);

            if (authHeader == null || !authHeader.startsWith("Bearer ")) {
                return onError(exchange, HttpStatus.UNAUTHORIZED);
            }

            String token = authHeader.substring(7);

            RequestDto req = new RequestDto(
                    exchange.getRequest().getPath().value(),
                    exchange.getRequest().getMethodValue()
            );

            return webClient.build()
                    .post()
                    .uri("http://msvc-users/users/validate?token=" + token)
                    .bodyValue(req) // ✅ IMPORTANTE: ahora envías el body requerido
                    .retrieve()
                    .bodyToMono(TokenDto.class)
                    .flatMap(tokenDto -> {

                        ServerWebExchange mutatedExchange = exchange.mutate()
                                .request(exchange.getRequest().mutate()
                                        .header("X-User-Id", String.valueOf(tokenDto.getUserId()))
                                        .header("X-User-Role", tokenDto.getRole())
                                        .header("X-Username", tokenDto.getUsername())
                                        .build())
                                .build();

                        return chain.filter(mutatedExchange);
                    })
                    .onErrorResume(e -> onError(exchange, HttpStatus.UNAUTHORIZED));
        };
    }

    private Mono<Void> onError(ServerWebExchange exchange, HttpStatus status) {
        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(status);
        return response.setComplete();
    }

    public static class Config {}
}

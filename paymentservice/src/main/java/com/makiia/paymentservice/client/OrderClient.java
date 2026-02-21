package com.makiia.paymentservice.client;

import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.*;

@FeignClient(name = "order-service", url = "http://localhost:8002")
public interface OrderClient {

    @PutMapping("/orders/{orderId}/confirm")
    void confirmOrder(@PathVariable Long orderId);

    @PutMapping("/orders/{orderId}/cancel")
    void cancelOrder(@PathVariable Long orderId);
}

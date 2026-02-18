package com.makiia.orderservice.service;

import com.makiia.orderservice.client.ProductClient;
import com.makiia.orderservice.dto.CreateOrderDto;
import com.makiia.orderservice.dto.OrderItemDto;
import com.makiia.orderservice.dto.OrderResponseDto;
import com.makiia.orderservice.entity.*;
import com.makiia.orderservice.repository.OrderRepository;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.util.List;
import java.util.stream.Collectors;

@Service
public class OrderService {

    private final OrderRepository orderRepository;
    private final ProductClient productClient;

    public OrderService(OrderRepository orderRepository,
                        ProductClient productClient) {
        this.orderRepository = orderRepository;
        this.productClient = productClient;
    }

    // 📌 Listar órdenes
    public List<OrderResponseDto> getAll() {
        return orderRepository.findAll()
                .stream()
                .map(this::mapToDto)
                .collect(Collectors.toList());
    }

    // 📌 Crear orden
    public OrderResponseDto createOrder(CreateOrderDto dto) {

        Order order = new Order();
        order.setCustomerId(dto.getCustomerId());
        order.setStatus(OrderStatus.PENDING);
        order.setChannel(OrderChannel.WEB);
        order.setContactPhone(dto.getContactPhone());
        order.setNotes(dto.getNotes());

        List<OrderItem> items = dto.getItems()
                .stream()
                .map(item -> mapToOrderItem(item, order))
                .collect(Collectors.toList());

        BigDecimal total = calculateTotal(items);

        order.setTotal(total);
        order.setItems(items);

        Order saved = orderRepository.save(order);
        return mapToDto(saved);
    }

    // 📌 Confirmar orden (llamado desde Payment)
    public void confirmOrder(Long id) {
        updateStatus(id, OrderStatus.CONFIRMED);
    }

    // 📌 Cancelar orden (llamado desde Payment)
    public void cancelOrder(Long id) {
        updateStatus(id, OrderStatus.CANCELLED);
    }

    // ==========================
    // 🔁 HELPERS
    // ==========================

    private OrderItem mapToOrderItem(OrderItemDto dto, Order order) {

        var product = productClient.getProductById(dto.getProductId());

        OrderItem item = new OrderItem();
        item.setProductId(product.getId());
        item.setQuantity(dto.getQuantity());
        item.setPrice(product.getPrice());
        item.setOrder(order);

        return item;
    }

    private BigDecimal calculateTotal(List<OrderItem> items) {
        return items.stream()
                .map(i -> i.getPrice()
                        .multiply(BigDecimal.valueOf(i.getQuantity())))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    private void updateStatus(Long id, OrderStatus status) {
        Order order = orderRepository.findById(id)
                .orElseThrow(() -> new RuntimeException("Order no encontrada"));
        order.setStatus(status);
        orderRepository.save(order);
    }

    private OrderResponseDto mapToDto(Order order) {
        return OrderResponseDto.builder()
                .orderId(order.getId())
                .total(order.getTotal())
                .status(order.getStatus().name())
                .build();
    }
}

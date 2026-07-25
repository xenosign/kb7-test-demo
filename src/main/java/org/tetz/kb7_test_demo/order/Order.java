package org.tetz.kb7_test_demo.order;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.math.BigDecimal;
import java.time.LocalDateTime;

@Entity
@Table(name = "orders")
public class Order {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "customer_email", nullable = false)
    private String customerEmail;

    @Column(name = "product_name", nullable = false)
    private String productName;

    @Column(name = "status", nullable = false)
    private String status;

    @Column(name = "amount", nullable = false)
    private BigDecimal amount;

    @Column(name = "created_at", nullable = false)
    private LocalDateTime createdAt;

    protected Order() {
    }

    public Long getId() {
        return id;
    }

    public String getCustomerEmail() {
        return customerEmail;
    }

    public String getProductName() {
        return productName;
    }

    public String getStatus() {
        return status;
    }

    public BigDecimal getAmount() {
        return amount;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }
}

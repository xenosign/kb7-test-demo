USE kb7demo;

CREATE TABLE IF NOT EXISTS orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    customer_email VARCHAR(100) NOT NULL,
    product_name VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at DATETIME NOT NULL
);

-- 의도적으로 customer_email에 인덱스를 걸지 않음: 조회 API에서 풀 테이블 스캔 병목을 재현하기 위함.
-- 병목 해결 단계에서 아래 인덱스를 추가해 Before/After를 비교한다.
-- ALTER TABLE orders ADD INDEX idx_orders_customer_email (customer_email);

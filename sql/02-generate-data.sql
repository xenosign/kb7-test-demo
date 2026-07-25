USE kb7demo;

SET SESSION cte_max_recursion_depth = 2000;

-- 1,000 x 1,000 = 1,000,000건의 더미 주문 데이터를 생성한다.
INSERT INTO orders (customer_email, product_name, status, amount, created_at)
SELECT
    CONCAT('user', a.n * 1000 + b.n, '@example.com') AS customer_email,
    ELT(1 + FLOOR(RAND() * 5), 'Laptop', 'Keyboard', 'Mouse', 'Monitor', 'Headset') AS product_name,
    ELT(1 + FLOOR(RAND() * 3), 'PENDING', 'COMPLETED', 'CANCELLED') AS status,
    ROUND(RAND() * 500 + 10, 2) AS amount,
    DATE_ADD('2023-01-01', INTERVAL FLOOR(RAND() * 900) DAY) AS created_at
FROM
    (WITH RECURSIVE seq AS (
        SELECT 0 AS n
        UNION ALL
        SELECT n + 1 FROM seq WHERE n < 999
    ) SELECT n FROM seq) a
CROSS JOIN
    (WITH RECURSIVE seq AS (
        SELECT 0 AS n
        UNION ALL
        SELECT n + 1 FROM seq WHERE n < 999
    ) SELECT n FROM seq) b;

-- k6 테스트에서 고정 타겟으로 조회할 특정 이메일 (조회 결과가 0건이 되지 않도록 확실히 존재시킴)
INSERT INTO orders (customer_email, product_name, status, amount, created_at)
VALUES ('target@example.com', 'Laptop', 'COMPLETED', 999.99, '2023-06-15 10:00:00');

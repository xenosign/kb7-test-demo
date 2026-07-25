package org.tetz.kb7_test_demo.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface OrderRepository extends JpaRepository<Order, Long> {

    List<Order> findByCustomerEmail(String customerEmail);

    // 커넥션 풀 고갈 재현용: 쿼리 실행 동안 해당 요청이 커넥션을 점유하도록 DB 단에서 대기시킨다.
    @Query(value = "SELECT SLEEP(:seconds)", nativeQuery = true)
    Integer sleep(@Param("seconds") int seconds);
}

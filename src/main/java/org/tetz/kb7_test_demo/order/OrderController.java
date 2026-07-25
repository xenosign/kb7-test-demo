package org.tetz.kb7_test_demo.order;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderRepository orderRepository;

    public OrderController(OrderRepository orderRepository) {
        this.orderRepository = orderRepository;
    }

    // customer_email 컬럼에 인덱스가 없어 100만 건 테이블에서 풀 테이블 스캔이 발생하는 병목 재현용 엔드포인트.
    @GetMapping("/search")
    public List<Order> search(@RequestParam String email) {
        return orderRepository.findByCustomerEmail(email);
    }

    // 커넥션 풀 고갈 재현용 엔드포인트. 요청 하나가 seconds만큼 DB 커넥션을 점유하므로,
    // HikariCP maximum-pool-size를 초과하는 동시 요청이 들어오면 나머지는 커넥션 대기 후 타임아웃된다.
    @GetMapping("/slow")
    public String slow(@RequestParam(defaultValue = "3") int seconds) {
        orderRepository.sleep(seconds);
        return "held connection for " + seconds + "s";
    }
}

package org.tetz.kb7_test_demo.order;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.ObjectMapper;

import java.time.Duration;
import java.util.List;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private static final Duration SEARCH_CACHE_TTL = Duration.ofSeconds(30);

    private final OrderRepository orderRepository;
    private final StringRedisTemplate redisTemplate;
    private final ObjectMapper objectMapper;

    public OrderController(OrderRepository orderRepository, StringRedisTemplate redisTemplate, ObjectMapper objectMapper) {
        this.orderRepository = orderRepository;
        this.redisTemplate = redisTemplate;
        this.objectMapper = objectMapper;
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

    // /search와 동일하게 인덱스 없는 풀 테이블 스캔을 사용하지만, 결과를 Redis에 캐싱해
    // 동일한 email이 반복 조회될 때는 DB를 타지 않도록 한다. X-Cache 헤더로 HIT/MISS를 확인할 수 있다.
    @GetMapping("/search-cached")
    public ResponseEntity<String> searchCached(@RequestParam String email) {
        long start = System.nanoTime();
        String key = "order:search:" + email;

        String cached = redisTemplate.opsForValue().get(key);
        if (cached != null) {
            return jsonResponse(cached, "HIT", start);
        }

        List<Order> orders = orderRepository.findByCustomerEmail(email);
        String json = objectMapper.writeValueAsString(orders);
        redisTemplate.opsForValue().set(key, json, SEARCH_CACHE_TTL);

        return jsonResponse(json, "MISS", start);
    }

    private ResponseEntity<String> jsonResponse(String json, String cacheStatus, long startNanos) {
        long tookMs = (System.nanoTime() - startNanos) / 1_000_000;
        return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_JSON)
                .header("X-Cache", cacheStatus)
                .header("X-Took-Ms", String.valueOf(tookMs))
                .body(json);
    }
}

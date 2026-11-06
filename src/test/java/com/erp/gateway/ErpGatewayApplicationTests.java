package com.erp.gateway;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

@SpringBootTest(properties = { "spring.flyway.enabled=false", "erp.dev.auto-update=false" })
class ErpGatewayApplicationTests {

	@Test
	void contextLoads() {
	}

}

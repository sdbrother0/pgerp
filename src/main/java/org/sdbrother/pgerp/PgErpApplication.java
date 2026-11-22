package org.sdbrother.pgerp;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class PgErpApplication {

	static void main(String[] args) {
		SpringApplication.run(PgErpApplication.class, args);
	}

}

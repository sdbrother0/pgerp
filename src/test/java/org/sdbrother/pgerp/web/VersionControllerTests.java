package org.sdbrother.pgerp.web;

import java.util.Properties;

import org.junit.jupiter.api.Test;
import org.sdbrother.pgerp.push.UiPushBroadcaster;
import org.sdbrother.pgerp.security.DatabaseAuthenticationProvider;
import org.sdbrother.pgerp.security.SecurityConfig;
import org.sdbrother.pgerp.security.TrustedSessions;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(VersionController.class)
@Import({ SecurityConfig.class, TrustedSessions.class, VersionControllerTests.Build.class })
class VersionControllerTests {

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	@Test
	@WithMockUser
	void signedInUserGetsVersion() throws Exception {
		this.mvc.perform(get("/api/version"))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.version").value("1.2.3"));
	}

	@Test
	void versionIsHiddenWithoutSession() throws Exception {
		this.mvc.perform(get("/api/version")).andExpect(status().isUnauthorized());
	}

	@Test
	void versionIsEmptyWithoutBuildInfo() {
		VersionController controller = new VersionController(
				new StaticListableBeanFactory().getBeanProvider(BuildProperties.class));
		assertThat(controller.version()).containsEntry("version", "");
	}

	@TestConfiguration
	static class Build {

		@Bean
		@Primary
		BuildProperties testBuildProperties() {
			Properties properties = new Properties();
			properties.setProperty("version", "1.2.3");
			return new BuildProperties(properties);
		}

	}

}

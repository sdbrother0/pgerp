# syntax=docker/dockerfile:1
# Образ PgERP: сборка Maven на JDK 25, запуск на JRE 25.
#   docker build -t pgerp .
# Запуск вместе с PostgreSQL — compose.yaml (docker compose up -d).

# ---------- Сборка ----------
FROM eclipse-temurin:25-jdk AS build
WORKDIR /src

# Сначала только описание сборки: зависимости кэшируются, пока не изменился pom.xml
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q dependency:go-offline

COPY src src
# Тесты требуют базу данных — их запускают вне сборки образа
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q package -DskipTests \
 && cp target/erp-gateway-*.jar /src/app.jar \
 && java -Djarmode=tools -jar /src/app.jar extract --layers --launcher --destination /src/extracted

# ---------- Запуск ----------
FROM eclipse-temurin:25-jre
WORKDIR /app

# Отдельный пользователь без прав root
RUN groupadd --system pgerp && useradd --system --gid pgerp --home-dir /app pgerp

# Слои Spring Boot: зависимости меняются реже кода приложения
COPY --from=build /src/extracted/dependencies/ ./
COPY --from=build /src/extracted/spring-boot-loader/ ./
COPY --from=build /src/extracted/snapshot-dependencies/ ./
COPY --from=build /src/extracted/application/ ./

USER pgerp
EXPOSE 8080

ENV ERP_DB_URL=jdbc:postgresql://db:5432/erp \
    ERP_DB_USER=postgres \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -Djava.awt.headless=true"

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]

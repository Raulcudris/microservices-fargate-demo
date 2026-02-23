# ---- Build Stage ----
FROM eclipse-temurin:11-jdk-jammy AS build
WORKDIR /app

# Cache de dependencias
COPY gradlew .
COPY gradle ./gradle
COPY build.gradle* settings.gradle* gradle.properties* ./
RUN chmod +x gradlew && ./gradlew --no-daemon dependencies || true

# Copiar el resto del proyecto
COPY . .

# Build jar (Spring Boot)
RUN ./gradlew --no-daemon clean bootJar -x test

# ---- Run Stage ----
FROM eclipse-temurin:11-jre-jammy
WORKDIR /app

# curl útil para healthchecks
RUN apt-get update && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*

# Crear usuario no-root CON home directory y permisos
RUN groupadd -r spring && \
    useradd -r -g spring -m -d /home/spring spring && \
    mkdir -p /home/spring/.config/jgit && \
    mkdir -p /tmp/config-repo && \
    chown -R spring:spring /home/spring /app /tmp/config-repo

# Cambiar al usuario spring
USER spring

# Variables de entorno para JGit (usar /tmp en lugar de home)
ENV JGIT_CONFIG=/tmp/jgit.config
ENV HOME=/tmp
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=25.0 -Djava.security.egd=file:/dev/./urandom"

COPY --from=build /app/build/libs/*.jar app.jar

EXPOSE 8081

# Mejor usar exec form en lugar de sh -c
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
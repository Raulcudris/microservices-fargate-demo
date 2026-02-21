# ---- Build Stage ----
FROM eclipse-temurin:11-jdk-jammy AS build
WORKDIR /app

# Cache de dependencias
COPY gradlew .
COPY gradle ./gradle
COPY build.gradle* settings.gradle* gradle.properties* ./
RUN chmod +x gradlew && ./gradlew --no-daemon dependencies || true

# Copiar el resto del proyecto (más seguro que solo src)
COPY . .

# Build jar (Spring Boot)
RUN ./gradlew --no-daemon clean bootJar -x test

# ---- Run Stage ----
FROM eclipse-temurin:11-jre-jammy
WORKDIR /app

# curl útil para healthchecks en compose y troubleshooting
RUN apt-get update && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*

# Usuario no-root
RUN groupadd -r spring && useradd -r -g spring spring
USER spring

COPY --from=build /app/build/libs/*.jar app.jar

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=25.0 -Djava.security.egd=file:/dev/./urandom"

EXPOSE 8001
ENTRYPOINT ["sh","-c","java $JAVA_TOOL_OPTIONS -jar /app/app.jar"]
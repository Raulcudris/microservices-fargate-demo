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

# Crear directorio temporal para posibles archivos temporales
RUN mkdir -p /tmp && chmod 777 /tmp

# Usuario no-root
RUN groupadd -r spring && useradd -r -g spring spring
USER spring

COPY --from=build /app/build/libs/*.jar app.jar

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=25.0 -Djava.security.egd=file:/dev/./urandom"
ENV HOME=/tmp

EXPOSE 8761
ENTRYPOINT ["sh","-c","java $JAVA_TOOL_OPTIONS -jar /app/app.jar"]
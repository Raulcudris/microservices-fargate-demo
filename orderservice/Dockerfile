# ---- Build Stage ----
FROM maven:3.9.6-eclipse-temurin-11 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn clean package -DskipTests

# ---- Run Stage ----
FROM eclipse-temurin:11-jre-jammy
WORKDIR /app

# curl para healthcheck del docker-compose
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/target/*.jar app.jar

EXPOSE 8002
ENTRYPOINT ["java", "-jar", "/app/app.jar"]

# Etapa 1: Build
FROM eclipse-temurin:11-jdk AS builder

WORKDIR /home

# (Opcional) Si NO usas git/curl/unzip en el build, elimina esto para acelerar
# RUN apt-get update && apt-get install -y git curl unzip && rm -rf /var/lib/apt/lists/*

# 1) Copiar solo lo necesario para cachear dependencias
COPY gradle gradle
COPY gradlew .
COPY build.gradle* settings.gradle* gradle.properties* ./

RUN chmod +x ./gradlew

# 2) Descargar dependencias (cache de Gradle en layer)
# El "|| true" evita que falle si tu build necesita aún src para compilar, pero igual calienta cache
RUN ./gradlew --no-daemon dependencies || true

# 3) Ahora sí copia el resto del proyecto
COPY . .

# 4) Build final
RUN ./gradlew --no-daemon clean bootJar -x test


# Etapa 2: Runtime
FROM eclipse-temurin:11-jre

ENV TZ=America/Bogota
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Usuario no-root
RUN groupadd -r spring && useradd -r -g spring spring
USER spring

WORKDIR /home

COPY --from=builder /home/build/libs/*.jar app.jar

EXPOSE 8080

# JVM tuning para contenedor + arranque rápido
ENV JAVA_TOOL_OPTIONS="\
-XX:+UseContainerSupport \
-XX:MaxRAMPercentage=75 \
-XX:InitialRAMPercentage=25 \
-XX:+UseSerialGC \
-XX:MaxMetaspaceSize=128m \
-Djava.security.egd=file:/dev/./urandom \
-Dspring.main.lazy-initialization=true \
"

ENTRYPOINT ["sh","-c","java $JAVA_TOOL_OPTIONS -jar app.jar"]

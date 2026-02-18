# Etapa 1: Build (Construcción del JAR)
FROM eclipse-temurin:11-jdk AS builder

# Instalar dependencias necesarias
RUN apt-get update && apt-get install -y \
    git \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Establecer el directorio de trabajo para la construcción
WORKDIR /home

# Copiar todos los archivos del proyecto al contenedor
COPY . .

# Dar permisos al Gradle Wrapper
RUN chmod +x ./gradlew

# Construir el proyecto y generar el archivo JAR
RUN ./gradlew clean build -x test

# Etapa 2: Runtime (Ejecución del JAR)
FROM eclipse-temurin:11-jre

# Configurar el entorno de zona horaria
ENV TZ=America/Bogota
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Crear usuario no-root para mayor seguridad
RUN groupadd -r spring && useradd -r -g spring spring
USER spring

# Establecer el directorio de trabajo para la ejecución
WORKDIR /home

# Copiar el archivo JAR generado en la etapa de construcción
COPY --from=builder /home/build/libs/*.jar app.jar

# Exponer el puerto de la aplicación
EXPOSE 8004

# Comando para ejecutar la aplicación
CMD ["java", "-jar", "app.jar"]
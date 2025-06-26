# Etapa 1: Build con Maven y JDK 21
FROM maven:3.9.6-eclipse-temurin-21 AS build

COPY . .

RUN mvn clean package

RUN mvn clean package -DskipTests

# Etapa 2: Imagen runtime con OpenJDK 21 JRE
FROM openjdk:21

EXPOSE 8762

COPY --from=build /target/cloud-gateway-0.0.1-SNAPSHOT.jar app.jar


ENTRYPOINT ["java", "-jar", "/app.jar"]
# Etapa 1: Build con Maven y JDK 24
FROM maven:3.9.6-eclipse-temurin-24 AS build


WORKDIR /app


COPY pom.xml .

RUN mvn dependency:go-offline


COPY src ./src


RUN mvn clean package -DskipTests

# Etapa 2: Imagen runtime con OpenJDK 24 JRE
FROM eclipse-temurin:24-jre-alpine


WORKDIR /app


EXPOSE 8762


COPY --from=build /app/target/cloud_gateway-0.0.1-SNAPSHOT.jar ./app.jar


ENTRYPOINT ["java", "-jar", "app.jar"]
# Cloud Gateway - Documentación

## Objetivo
Este microservicio actúa como puerta de entrada (API Gateway) para el ecosistema de microservicios del proyecto de inventario. Centraliza el enrutamiento, CORS, descubrimiento de servicios vía Eureka y la exposición de métricas.

## Puntos de entrada (Entry Points)
- `CloudGatewayApplication.java`: Clase principal que arranca Spring Boot y habilita el cliente de descubrimiento (`@EnableDiscoveryClient`). Lee la variable de entorno `PROFILE` para activar un `spring.profiles.active` dinámico.
- Puerto expuesto: Controlado por la variable de entorno `SERVER_PORT` (ver `application.yml`). En docker-compose.dev.yml actualmente mapeado a `8762`.

## Archivos importantes

| Archivo | Descripción |
|---------|------------|
| `pom.xml` | Dependencias del Gateway (Spring Cloud Gateway, Eureka Client, Actuator, DevTools). Atención: define `<java.version>23</java.version>` (ver sección de notas). |
| `Dockerfile` | Imagen multi-stage: construye el JAR con Maven y luego crea una imagen ligera con Temurin JDK para ejecutar `app.jar`. |
| `src/main/resources/application.yml` | Configuración de: nombre de la app (`spring.application.name`), Gateway (discovery locator, filtros por defecto, CORS global), Actuator (exposición de endpoints), Eureka Client y puerto del servidor. Usa variables de entorno externas para parametrizar. |
| `.env` / `test.env` | Variables de entorno (en producción se recomienda usar `.env.template` sin valores sensibles). |
| `docker-compose.dev.yml` (en carpeta superior) | Orquesta los servicios: PostgreSQL (db), operador, buscador, eureka y este gateway. Actualmente no incluye Elasticsearch (agregar si procede). |

## Variables de entorno usadas (referenciadas en `application.yml`)
| Variable | Rol |
|----------|-----|
| `SERVER_NAME` | Nombre lógico de la app para Eureka y logs. |
| `ALLOWED_ORIGINS` | Orígenes permitidos en CORS. Puede ser `*` o dominios específicos. |
| `ROUTE_TABLES_ENABLED` | Habilita el endpoint actuator de gateway (visualización de rutas). |
| `SERVER_PORT` | Puerto de escucha del gateway dentro del contenedor. |
| `EUREKA_URL` | URL base del servidor Eureka para el registro y descubrimiento. |
| `PROFILE` | (Opcional) Activa un perfil de Spring diferente al `default`. |

## CORS
Configurado de forma global bajo `spring.cloud.gateway.globalcors.cors-configurations`. Ajustar `ALLOWED_ORIGINS` para entornos de producción (evitar `"*"`).

## Descubrimiento de servicios
El bloque:
```yaml
spring:
	cloud:
		gateway:
			discovery:
				locator:
					enabled: true
					lower-case-service-id: true
```
permite que el gateway cree rutas dinámicas basadas en los IDs de los servicios registrados en Eureka. Ejemplo: si `ms-search` se registra como `ms-search`, una petición a `http://GATEWAY_HOST/ms-search/**` se enrutará al backend correspondiente.

## Filtros globales
`default-filters` incluye `DedupeResponseHeader` para evitar duplicados en cabeceras CORS.

## Actuator
Todos los endpoints están expuestos (`management.endpoints.web.exposure.include: "*"`). En producción se recomienda restringirlos (`health,info`).

## Flujo de enrutamiento (simplificado)
1. Cliente (front) hace petición al Gateway.
2. Gateway resuelve la ruta (estática o vía discovery locator + Eureka).
3. Aplica filtros (CORS, deduplicación de cabeceras, etc.).
4. Reenvía al microservicio destino.
5. Devuelve respuesta al cliente.

## Integración en docker-compose (desarrollo)
Fragmento relevante (ya existente en `docker-compose.dev.yml` dentro de `cloud-gateway`):
```yaml
	ms-cloud-gateway:
		build:
			context: .
			dockerfile: Dockerfile
		container_name: ms-cloud-gateway
		env_file:
			- .env
		ports:
			- "8762:8762"
		networks:
			- ms-project
		depends_on:
			- ms-eureka
			- ms-search
			- ms-operator
```
La red `ms-project` permite que el gateway resuelva los hosts internos (por ejemplo `ms-eureka:8761`).

## Modo de desarrollo recomendado (compose + watch + rebuild)
Se ha configurado `develop.watch` en el `docker-compose.dev.yml` para que **cada cambio en el código fuente (`src`) provoque un rebuild completo** de la imagen del microservicio correspondiente. Esto garantiza que el código Java se compile de nuevo y evita inconsistencias con DevTools cuando no se generan `.class` nuevos.

### Archivo  `docker-compose.dev.yml`
```yaml

	ms-operator:
		develop:
			watch:
				- action: rebuild
					path: ../operator/src
				- action: rebuild
					path: ../operator/pom.xml

	ms-search:

		volumes:
			- ../search/src:/app/src
			- ../search/pom.xml:/app/pom.xml
			- ../search/.mvn:/app/.mvn
			- ../search/mvnw:/app/mvnw
			- maven-repo-search:/root/.m2
		develop:
			watch:
				- action: rebuild
					path: ../search/src
				- action: rebuild
					path: ../search/pom.xml

	ms-eureka:
		volumes:
			- ../eureka/src:/app/src
			- ../eureka/pom.xml:/app/pom.xml
			- ../eureka/.mvn:/app/.mvn
			- ../eureka/mvnw:/app/mvnw
			- maven-repo-eureka:/root/.m2
		develop:
			watch:
				- action: rebuild
					path: ../eureka/src
				- action: rebuild
					path: ../eureka/pom.xml

	ms-cloud-gateway:
		volumes:
			- ./src:/app/src
			- ./pom.xml:/app/pom.xml
			- ./.mvn:/app/.mvn
			- ./mvnw:/app/mvnw
			- maven-repo-gateway:/root/.m2
		develop:
			watch:
				- action: rebuild
					path: ./src
				- action: rebuild
					path: ./pom.xml

```

### Comando de arranque en modo watch
```bash
docker compose -f cloud-gateway/docker-compose.dev.yml watch
```

Al guardar un archivo bajo `src` en cualquiera de los servicios:
1. Compose detecta el cambio y reconstruye la imagen (action: rebuild).
2. Se recrea el contenedor con el nuevo código.
3. El endpoint expone la versión actualizada (ejemplo: `/dev/reload-test`).

### Ventajas / Desventajas
| Ventaja | Desventaja |
|---------|------------|
| Garantiza recompilación limpia | Lento si hay muchos módulos |
| Evita inconsistencias de clases | El rebuild descarga dependencias si cambian poms |
| Un flujo unificado para todos | Mayor consumo de CPU/IO durante rebuild |

### Alternativa (más rápida)
Usar bind mounts + compilación local (`./mvnw -q -DskipTests compile`) montando `target/classes` y dejando DevTools reiniciar. Esta opción reduce rebuilds pero requiere compilar fuera del contenedor.

## Cómo se enlazan los microservicios
| Servicio | Nombre de contenedor | Función |
|----------|----------------------|---------|
| `ms-eureka` | Registro/Eureka | Proporciona descubrimiento de servicios. |
| `ms-search` | Buscador | Indexa y sirve datos de búsqueda (futuro: Elasticsearch). |
| `ms-operator` | Operador | Operaciones CRUD/negocio principal (usa PostgreSQL). |
| `db` | PostgreSQL | Base de datos para `ms-operator`. |
| `ms-cloud-gateway` | Gateway | Entrada única para el front-end. |

El gateway utiliza Eureka para localizar `ms-search` y `ms-operator`. Las rutas pueden consumirse vía: `http://localhost:8762/ms-search/...` o `http://localhost:8762/ms-operator/...` (según configuración de discovery locator y naming).

## Ejecución (modo actual sin watch / hot reload)
Desde el directorio `cloud-gateway` (o raíz ajustando la ruta), ejecutar:
```bash
docker compose -f docker-compose.dev.yml up --build
```
Esto construirá las imágenes y levantará todos los contenedores.

## Posible mejora: modo desarrollo con DevTools / watch
1. Añadir perfiles `dev` y `prod` en `application.yml` o archivos separados.
2. Usar `spring-boot-devtools` (ya añadido) + montar el código fuente como volumen.
3. (Opcional) Crear `Dockerfile.dev` que ejecute `mvn spring-boot:run` y usar `develop.watch` de Docker Compose (si versión soporta) para sincronizar cambios.

## Notas sobre la versión de Java
El `pom.xml` fija `<java.version>23</java.version>`. Asegúrate de que la imagen base (`eclipse-temurin:24-jdk`) soporta la compilación y que tu entorno local tiene JDK acorde. Si hay errores en otros módulos con JDKs diferentes, homogeneizar a LTS (17 o 21) puede ser recomendable.

## Buenas prácticas sugeridas
- Restringir CORS a dominios concretos (e.g. front en producción).
- Limitar endpoints de Actuator en producción.
- Añadir rate limiting y filtros de seguridad (e.g. autenticación JWT) según evolucione el proyecto.
- Crear un `README` general en la raíz describiendo cómo interactúa este gateway con los demás servicios.

## Troubleshooting rápido
| Problema | Causa común | Solución |
|----------|-------------|----------|
| 404 al llamar a `ms-search` vía gateway | Servicio no registrado aún en Eureka | Esperar a registro (logs) o verificar `eureka.client.serviceUrl` |
| CORS bloquea peticiones | `ALLOWED_ORIGINS` no incluye el front | Ajustar `.env` del gateway y reiniciar contenedor |
| Cambios de código no reflejados | Imagen construida previamente | Reconstruir con `--build` o implementar modo dev |
| Error de versión Java | JDK inconsistente entre módulos | Alinear `<java.version>` y base images |




# Guía de Verificación y Troubleshooting: Eureka vía Cloud Gateway

Fecha: 2025-08-24
Estado actual: Contenedores desplegados en EC2 usando Docker Compose + imágenes en Amazon ECR Público. Acceso al gateway: `http://54.152.94.55:8762`. Intento de abrir `http://54.152.94.55:8762/eureka/web` devuelve 404 (Whitelabel Error Page).

---
## 1. Objetivo
Asegurar que los microservicios (Eureka, Operator, Search, Cloud Gateway) están:
- Correctamente conectados a Eureka.
- Ruteables a través del Cloud Gateway.
- Accesibles sólo mediante el gateway (no exposición directa innecesaria).
- Dashboard de Eureka accesible (opcional) desde el gateway o mediante acceso directo interno.

---
## 2. Síntoma Principal
Al abrir: `http://54.152.94.55:8762/eureka/web` obtienes:
```
Whitelabel Error Page (404 Not Found)
```

### Causa más probable
El **path de enrutamiento no coincide** con el nombre del servicio registrado / nombre del servicio en Docker.

Actualmente en tu `docker-compose.yml` (ejemplo usado):
```yaml
services:
  aws-eureka:
    image: public.ecr.aws/.../aws-eureka:latest
```
Y en `eureka.env`:
```
SERVER_NAME=aws-eureka
```
Spring Cloud Gateway con `discovery.locator.enabled=true` crea rutas dinámicas siguiendo el patrón:
```
/{serviceId}/**  -> lb://{serviceId}
```
Donde `serviceId` = `spring.application.name` (en minúsculas).

Por tanto, la UI de Eureka estaría en:
```
http://54.152.94.55:8761/
```
No en `/eureka/`.

Además, TUS OTROS servicios apuntan a:
```
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://eureka:8761/eureka/
```
Pero el host real dentro de la red Docker es `aws-eureka`. Eso rompe la conexión a Eureka (los clientes no se registran).

---
## 3. Checklist Rápido
| Paso | Acción | Comando | Esperado |
|------|--------|---------|----------|
| 1 | Ver contenedores | `docker compose ps` | Todos UP |
| 2 | Resolver DNS interno | `docker exec -it aws-cloud-gateway ping -c1 aws-eureka` | Respuesta exitosa |
| 3 | Ver logs Eureka | `docker compose logs -f aws-eureka` | Mensajes de registro/lista de clientes |
| 4 | Ver si clientes se registran | `curl -s http://aws-eureka:8761/eureka/apps | head` (desde un contenedor) | XML/JSON con aplicaciones |
| 5 | Ver rutas del gateway | `curl -s http://localhost:8762/actuator/gateway/routes | jq` (SSH dentro EC2) | Lista incluye aws-operator, aws-search, aws-eureka |
| 6 | Confirmar variable EUREKA_URL en servicios | Revisar `env/*.env` | Usa host correcto |
| 7 | Probar ruta a Eureka UI vía gateway | Abrir `http://54.152.94.55:8762/aws-eureka/` | Página HTML de Eureka |

---
## 4. Corrección de Naming (Crítico)
Tienes DOS opciones coherentes. Elige UNA:

### Opción A (Recomendada): Cambiar host en las variables de los clientes
Actualizar en `gateway.env`, `operator.env`, `search.env`:
```
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://aws-eureka:8761/eureka/
```
(No renombres servicios. Solo alinea el host.)

### Opción B: Renombrar el servicio en docker-compose a `eureka`
Cambia:
```yaml
aws-eureka:
```
por:
```yaml
eureka:
```
Y ajusta `SERVER_NAME=eureka` en `eureka.env`.

Resultado: Ruta vía gateway será `http://54.152.94.55:8762/eureka/`.

---
## 5. Exponer el Dashboard Correctamente
Si quieres mantener `aws-eureka` como nombre del servicio pero que el dashboard responda también a `/eureka/**`, agrega una ruta estática en el `application.yml` del gateway:
```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: eureka-alias
          uri: http://aws-eureka:8761
          predicates:
            - Path=/eureka/**
          filters:
            - StripPrefix=1
```
Esto permite ambas URLs:
- `http://54.152.94.55:8762/aws-eureka/`
- `http://54.152.94.55:8762/eureka/`

### Pasos para aplicar:
1. Editar `cloud-gateway/src/main/resources/application.yml` y añadir el bloque anterior bajo `spring.cloud.gateway` (sin duplicar keys).  
2. Redeploy (nuevo push => CI/CD) o en EC2: `docker compose up -d aws-cloud-gateway`.

---
## 6. Validación Funcional Post-Fix
Ejecutar (en EC2):
```bash
# Ver registro de servicios (desde dentro del gateway)
docker exec -it microservices-cloud-gateway-1 curl -s http://aws-eureka:8761/eureka/apps | grep -Ei '<name>|<instance' | head

# Probar operator vía gateway (ajusta ruta real)
curl -i http://localhost:8762/aws-operator/actuator/health

# Probar search vía gateway
curl -i http://localhost:8762/aws-search/actuator/health

# Ver rutas expuestas en gateway
curl -s http://localhost:8762/actuator/gateway/routes | grep uri
```
Si todo está correcto verás `status": "UP"` en health y URIs `lb://AWS-OPERATOR` etc.

---
## 7. Errores Comunes y Soluciones
| Problema | Causa | Solución |
|----------|-------|----------|
| 404 en `/eureka/web` | Nombre de servicio distinto | Ajustar naming o ruta estática |
| Servicios no aparecen en UI | Dirección de Eureka incorrecta | Corregir `EUREKA_CLIENT_SERVICEURL_DEFAULTZONE` |
| `503` al llamar a operator/search vía gateway | Cliente no registrado aún | Esperar 10–20s tras arranque o revisar logs |
| DNS interno falla (`ping: unknown host`) | Servicio mal nombrado | Verificar nombre del servicio en compose |
| UI lenta | Falta de recursos (t3.micro) | Considerar t3.small si CPU credit bajo |

---
## 8. Seguridad
- No expongas puertos internos (8761, 8080, 8081) públicamente.
- Limita acceso al dashboard de Eureka (ideal: no exponer en producción o proteger detrás de auth/reverse proxy).
- Considera activar HTTPS en el gateway más adelante.

---
## 9. Resumen Rápido de Acción
1. Armoniza host de Eureka: o `aws-eureka` en todas las `EUREKA_CLIENT_SERVICEURL_DEFAULTZONE` o renombra servicio a `eureka`.
2. (Opcional) Añade ruta estática para alias `/eureka/**`.
3. Redeploy gateway.
4. Valida rutas y health endpoints.
5. Revisa UI en `/aws-eureka/` o `/eureka/` según tu elección.

---
## 10. Ejemplo de Archivos Corregidos (Opción A)
`operator.env`:
```
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://aws-eureka:8761/eureka/
```
`search.env`:
```
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://aws-eureka:8761/eureka/
```
`gateway.env`:
```
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://aws-eureka:8761/eureka/
```

---
## 11. Próximos Pasos (Mejoras)
- Añadir monitoreo simple con `/actuator/metrics` (limitar exposición futura).
- Implementar HTTPS (Let’s Encrypt + nginx reverso o ALB).
- Añadir health checks personalizados para dependencias externas.
- Configurar tags de imagen versionadas (`:v1.0.0`) además de `:latest`.

---
¿Necesitas que te genere el bloque de rutas integradas en tu `application.yml` automáticamente? Pídelo y lo añado.

---
Fin de documento.

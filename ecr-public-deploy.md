## Despliegue Continuo con ECR Público

### Configuración de ECR Público
Amazon ECR Public permite almacenar y distribuir imágenes Docker de forma pública sin costos de transferencia de datos salientes. A diferencia de ECR privado, las imágenes públicas son accesibles sin autenticación para pull.

Para crear repositorios públicos:

1. Accede a la consola de AWS y navega a ECR Public
2. Selecciona "Crear repositorio"
3. Elige un espacio de nombres público
4. Crea los siguientes repositorios:

| Servicio | URI Público | 
|----------|-------------|
| aws-cloud-gateway | public.ecr.aws/k1b3s0y0/aws-cloud-gateway |
| aws-eureka | public.ecr.aws/k1b3s0y0/aws-eureka |
| aws-operator | public.ecr.aws/k1b3s0y0/aws-operator |
| aws-search | public.ecr.aws/k1b3s0y0/aws-search |

### Docker Compose para ECR Público
Tu archivo `docker-compose.yml` necesita ser actualizado para usar las URIs públicas:

```yaml
version: '3.9'
services:
  eureka:
    image: public.ecr.aws/k1b3s0y0/aws-eureka:latest
    env_file: ./env/eureka.env
    restart: unless-stopped
    networks:
      - ms-network
    
  operator:
    image: public.ecr.aws/k1b3s0y0/aws-operator:latest
    env_file: ./env/operator.env
    depends_on:
      - eureka
      - db
    restart: unless-stopped
    networks:
      - ms-network
    
  search:
    image: public.ecr.aws/k1b3s0y0/aws-search:latest
    env_file: ./env/search.env
    depends_on:
      - eureka
    restart: unless-stopped
    networks:
      - ms-network
    
  cloud-gateway:
    image: public.ecr.aws/k1b3s0y0/aws-cloud-gateway:latest
    env_file: ./env/gateway.env
    depends_on:
      - eureka
      - operator
      - search
    ports:
      - "8762:8762"
    restart: unless-stopped
    networks:
      - ms-network
    
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: operator_db
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped
    networks:
      - ms-network

networks:
  ms-network:
    driver: bridge

volumes:
  pgdata:
```

### Modificaciones al Workflow para ECR Público
Para publicar en ECR Público, necesitas modificar tu workflow de GitHub Actions:

```yaml
name: Build & Deploy to ECR Public

on:
  push:
    branches: [ "main", "dev" ]
  workflow_dispatch:

env:
  REGISTRY: public.ecr.aws/k1b3s0y0
  IMAGE_NAME: aws-operator # Cambia según el repositorio

jobs:
  build-push-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1 # ECR Public está en us-east-1

      - name: Login to ECR Public
        uses: docker/login-action@v3
        with:
          registry: public.ecr.aws
          username: ${{ secrets.AWS_ACCESS_KEY_ID }}
          password: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        # Alternativa: aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

      - name: Build image
        run: |
          docker build -t $REGISTRY/$IMAGE_NAME:latest .
          docker tag $REGISTRY/$IMAGE_NAME:latest $REGISTRY/$IMAGE_NAME:${{ github.sha }}

      - name: Push image
        run: |
          docker push $REGISTRY/$IMAGE_NAME:latest
          docker push $REGISTRY/$IMAGE_NAME:${{ github.sha }}

      - name: Deploy (pull & restart only this service)
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          envs: REGISTRY,IMAGE_NAME
          script: |
            cd /opt/microservices
            docker compose pull $IMAGE_NAME
            docker compose up -d $IMAGE_NAME
            docker image prune -f
```

### Principales Diferencias con ECR Privado

1. **URI del Repositorio**: 
   - Privado: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/repositorio`
   - Público: `public.ecr.aws/espacio-nombres/repositorio`

2. **Autenticación**:
   - Privado: `aws ecr get-login-password`
   - Público: `aws ecr-public get-login-password --region us-east-1`

3. **Pull sin Autenticación**:
   - Las imágenes en ECR Público pueden ser descargadas sin autenticación
   - Para push, aún necesitas credenciales de AWS válidas

4. **Región**:
   - ECR Público siempre está en us-east-1, independientemente de donde esté tu infraestructura
   - Las operaciones push/login deben especificar us-east-1

### Verificación de Despliegue
Para verificar que tu despliegue está usando imágenes públicas:

```bash
# En el servidor EC2
cd /opt/microservices
docker compose ps
docker image ls | grep public.ecr.aws
```

### Despliegue Manual desde ECR Público
Si necesitas hacer un despliegue manual sin GitHub Actions:

```bash
# No necesitas login para pull desde ECR público
docker compose pull
docker compose up -d
```

### Mejores Prácticas para ECR Público
1. **Visibilidad**: Recuerda que cualquier persona puede descargar tus imágenes
2. **No incluir secretos**: Nunca incrustes credenciales o secretos en las imágenes
3. **Escaneo de seguridad**: Habilita el escaneo automático de vulnerabilidades
4. **Versionado claro**: Utiliza tags semánticos además de `:latest`
5. **Documentación**: Incluye una descripción clara del contenido del repositorio

### Consideraciones de Seguridad
- Las imágenes públicas son accesibles globalmente sin autenticación
- Los permisos IAM solo controlan quién puede publicar, no quién puede descargar
- Considera si tu caso de uso realmente requiere repositorios públicos

## Variables de Entorno Necesarias

Para que el despliegue funcione correctamente, necesitas configurar los siguientes archivos de variables de entorno en tu servidor EC2 en la carpeta `/opt/microservices/env/`:

### `gateway.env`
```env
SERVER_NAME=aws-cloud-gateway
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8762
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://eureka:8761/eureka/
ALLOWED_ORIGINS=*
ROUTE_TABLES_ENABLED=true
```

### `eureka.env`
```env
SERVER_NAME=aws-eureka
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8761
EUREKA_INSTANCE_HOSTNAME=eureka
EUREKA_CLIENT_REGISTERWITHEUERKA=false
EUREKA_CLIENT_FETCHREGISTRY=false
EUREKA_RENEWAL=0.90
```

### `operator.env`
```env
SERVER_NAME=aws-operator
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8080
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://eureka:8761/eureka/
SPRING_DATASOURCE_URL=jdbc:postgresql://db:5432/operator_db
SPRING_DATASOURCE_USERNAME=postgres
SPRING_DATASOURCE_PASSWORD=postgres
SPRING_JPA_HIBERNATE_DDL_AUTO=update
SPRING_JPA_SHOW_SQL=false
```

### `search.env`
```env
SERVER_NAME=aws-search
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8081
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://eureka:8761/eureka/
ELASTICSEARCH_HOST=elasticsearch
ELASTICSEARCH_PORT=9200
ELASTICSEARCH_USER=elastic
ELASTICSEARCH_PWD=changeme
```

### Notas Importantes sobre las Variables de Entorno:

1. **Valores Sensibles**: Las contraseñas y credenciales mostradas son ejemplos. En un entorno de producción real, deberías usar valores seguros y considerar utilizar AWS Secrets Manager o un sistema similar.

2. **Variables Spring Boot**: Las variables siguen el formato de Spring Boot, donde los puntos en properties se reemplazan por guiones bajos en variables de entorno.

3. **Configuración de Red**: Los nombres de host como `eureka`, `db`, `elasticsearch` funcionan gracias a la red Docker definida en docker-compose.

4. **Perfiles de Spring**: `SPRING_PROFILES_ACTIVE=prod` asegura que se carguen las configuraciones de producción.

5. **Verificación**: Puedes verificar que las variables se están aplicando correctamente consultando los logs de los contenedores:
   ```bash
   docker compose logs cloud-gateway | grep "The following profiles are active"
   ```

## Instancia EC2 en Producción

Actualmente tenemos desplegado el sistema en una instancia EC2 en AWS con los siguientes detalles:

### Información de la Instancia

| Propiedad | Valor |
|-----------|-------|
| Instance ID | i-0e5f27fba886e3060 |
| Nombre | microservices-host |
| Tipo | t3.micro |
| AMI | Ubuntu Noble 24.04 (ami-0360c520857e3138f) |
| IP Pública | 54.174.115.203 |
| DNS Público | ec2-54-174-115-203.compute-1.amazonaws.com |
| IP Privada | 172.31.35.238 |
| VPC ID | vpc-05239e9c8f0ca36aa |
| Subnet ID | subnet-06689968a7105e5c6 |
| Key Pair | deploy-key |

### Contenedores en Ejecución

El siguiente es el estado de los contenedores desplegados en la instancia EC2:

```
CONTAINER ID   IMAGE                                              COMMAND                  CREATED          STATUS          PORTS                                         NAMES
b5af6cf356f1   public.ecr.aws/k1b3s0y0/aws-cloud-gateway:latest   "java -jar /app.jar"     19 seconds ago   Up 18 seconds   0.0.0.0:8762->8762/tcp, [::]:8762->8762/tcp   microservices-cloud-gateway-1
2da6ace962a1   public.ecr.aws/k1b3s0y0/aws-operator:latest        "java -jar /app.jar"     19 seconds ago   Up 18 seconds   8082/tcp                                      microservices-operator-1
76ea3db487ad   public.ecr.aws/k1b3s0y0/aws-search:latest          "java -jar /app.jar"     19 seconds ago   Up 18 seconds   8081/tcp                                      microservices-search-1
37807800b152   public.ecr.aws/k1b3s0y0/aws-eureka:latest          "java -jar /app.jar"     19 seconds ago   Up 19 seconds   8761/tcp                                      microservices-eureka-1
bd2d5ae0c52c   postgres:16                                        "docker-entrypoint.s…"   19 seconds ago   Up 19 seconds   5432/tcp                                      microservices-db-1
```

### Endpoints Disponibles

Los siguientes endpoints están disponibles en la instancia de producción:

| Servicio | URL | Descripción |
|----------|-----|-------------|
| Cloud Gateway | http://54.174.115.203:8762 | Puerta de enlace API principal |
| Cloud Gateway (DNS) | http://ec2-54-174-115-203.compute-1.amazonaws.com:8762 | Acceso vía DNS |
| Eureka Dashboard | http://54.174.115.203:8762/eureka/web | Registro y descubrimiento de servicios (a través del gateway) |
| Health Check | http://54.174.115.203:8762/actuator/health | Comprobación de estado del sistema |

### Acceso y Monitoreo

Para acceder al servidor:

```bash
ssh -i deploy-key.pem ubuntu@54.174.115.203
```

Para monitorear los logs en tiempo real:

```bash
# Ver logs de todos los servicios
cd /opt/microservices
docker compose logs -f

# Ver logs de un servicio específico
docker compose logs -f cloud-gateway
```

Para verificar el uso de recursos:

```bash
docker stats
```

### Seguridad y Consideraciones

- La instancia está configurada con un grupo de seguridad que permite tráfico HTTP en el puerto 8762 y SSH en el puerto 22.
- Los servicios internos (Eureka, Operator, Search, PostgreSQL) no están expuestos directamente a Internet.
- Todas las solicitudes externas deben pasar a través de Cloud Gateway.
- Se recomienda configurar HTTPS en producción para asegurar las comunicaciones.

# CI/CD y Despliegue en AWS (Guía Rápida para 4 Microservicios)

Tiempo estimado de implementación inicial: ~6 horas (principiante).
Objetivo: Desplegar 4 microservicios Java (gateway, eureka, operator, search) + Postgres + (opcional Elasticsearch) con CI/CD de bajo costo.

## Estrategia recomendada (más simple y barata)
1. Usar **1 instancia EC2** (t3.micro / t3.small) con **Docker + docker-compose**.
2. Alojar imágenes en **Amazon ECR** (registro de contenedores).
3. Configurar **GitHub Actions** para:
	 - Construir imágenes
	 - Publicarlas en ECR
	 - Conectarse por SSH a la instancia EC2 y hacer `docker compose pull && up -d`.
4. Exponer solo el **Cloud Gateway** (puerto 8762 / o 80 mediante Nginx opcional) y bloquear los demás puertos externamente.

### Detalle ampliado de la estrategia
Esta estrategia prioriza: simplicidad, bajo costo, rollback rápido y tiempo de implementación < 1 día.

#### Naming recomendado (consistente y fácil de filtrar)
| Recurso | Nombre sugerido | Notas |
|---------|-----------------|-------|
| Instancia EC2 | `ms-core-prod-01` | Prefijo `ms` (microservices), sufijo incremental si escalas |
| Security Group | `sg-ms-core` | Limita puertos 22 y 8762 únicamente |
| Key Pair | `kp-ms-deploy` | Evita nombres genéricos como `my-key` |
| IAM User CI/CD | `cicd-deploy` | Solo permisos mínimos (ECR + EC2 Describe) al final |
| ECR Repos | `cloud-gateway`, `eureka`, `operator`, `search` | Todos en minúscula, sin guiones extra |
| Volumen Docker (Postgres) | `pgdata` | Definido en compose |
| Volumen Docker (Elasticsearch) | `esdata` | Elimínalo si no usas ES |
| Tag AWS (Project) | `inventory-ms` | Usar en todos los recursos para tracking de costos |
| Tag AWS (Env) | `dev` / `prod` | Aunque sea un único entorno, define `prod` para claridad |

#### Flujo completo (alto nivel)
1. Dev hace push a rama (`dev-miguel` o `main`).
2. Workflow construye 4 imágenes Docker y las etiqueta (`latest` + `sha`).
3. Imágenes subidas a ECR.
4. Job de deploy se conecta por SSH a EC2.
5. Ejecuta `docker compose pull && docker compose up -d`.
6. Instancia reutiliza volúmenes para datos persistentes (Postgres / ES).
7. Verificación de health (manual o script futuro).

#### Justificación de 1 sola instancia
- Minimiza latencia entre servicios (misma red / mismo host).
- Simplifica networking (no necesitas VPC avanzada / ALB / Service Discovery extra).
- Costos: t3.micro (~$8–$10/mes) o t3.small (~$16–$20/mes). Puedes apagarla cuando no la uses.

#### Cuando subir a t3.small
- Elasticsearch empieza a matar procesos por memoria.
- Postgres se queda sin caché (consultas lentas) y tienes > 200MB datos.
- CPU credit balance < 20% de forma persistente (CloudWatch metric `CPUCreditBalance`).

#### Seguridad mínima viable
- Abrir solo puertos 22 (tu IP) y 8762 (público o tu IP en demo).
- NO exponer Eureka, Postgres, Elasticsearch.
- Rotar la clave SSH si la compartes.
- Añadir `fail2ban` opcional si dejas puerto 22 abierto largo tiempo.

#### Monitoreo rápido (sin stack adicional)
- Usar `docker logs -f` para diagnósticos.
- Crear alias en EC2: `alias dps='docker compose ps'` y `alias dlogs='docker logs -f cloud-gateway'`.
- Activar métricas básicas CloudWatch (vienen por defecto para EC2) y revisar CPU / Network.

#### Rollback manual (30 segundos)
1. Editar temporalmente `docker-compose.yml` fijando tag previo (`cloud-gateway:shaAnterior`).
2. `docker compose pull && docker compose up -d cloud-gateway`.
3. Ver health. Repetir para otros servicios si procede.

#### Limpieza periódica
Mensual o tras varias releases:
```bash
docker image prune -f
docker volume ls
docker volume prune  # SOLO si sabes que no vas a perder datos necesarios
```

#### Variante con Nginx (opcional)
Si quieres servir el gateway en puerto 80:
1. Agregar contenedor `nginx` que reverse-proxy `cloud-gateway:8762`.
2. Abrir sólo puerto 80 al público.
3. Futuro: certbot o ALB para HTTPS.

Ejemplo de snippet:
```yaml
	nginx:
		image: nginx:1.27-alpine
		depends_on: [cloud-gateway]
		ports:
			- "80:80"
		volumes:
			- ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
```
`nginx.conf` simple:
```nginx
server {
	listen 80;
	location / { proxy_pass http://cloud-gateway:8762; proxy_set_header Host $host; }
}
```

#### Automatización futura (prioridades)
1. Script de smoke test post-deploy (`/actuator/health`).
2. Añadir tagging semántico (`v1.0.0`).
3. Cache de dependencias Maven en build (actions cache) para acelerar.
4. Integrar análisis estático (Sonar / SpotBugs) si el tiempo lo permite.

#### Tabla rápida de decisiones
| Tema | Decisión actual | Motivo | Próximo paso potencial |
|------|-----------------|--------|------------------------|
| Orquestación | docker-compose en 1 EC2 | Simplicidad / costo | Migrar a ECS si escalas |
| Descubrimiento | Eureka local | Reutilizas código actual | Evaluar si gateway puede enrutar estático |
| Almacenamiento | Volúmenes locales | Suficiente para demo | Migrar a RDS / OpenSearch gestionado |
| Observabilidad | Logs manuales | Tiempo limitado | Añadir Prometheus / Grafana |
| Seguridad | SG básico + claves | Minimiza superficie | HTTPS + WAF futuro |

---

> Alternativa (más “cloud native”, más tiempo): ECS Fargate + ALB + Service Discovery. Incluida al final como sección opcional si tienes tiempo extra.

---
## Paso 0. Preparar repositorio
Estructura actual: cada microservicio tiene su propio `Dockerfile` y hay un `docker-compose.prod.yml` (ajústalo si hace falta). Asegura:
- Variables sensibles NO en commit (`.env` reales fuera, usar `.env.template`).
- Nombrar imágenes de forma consistente: `cloud-gateway`, `eureka`, `operator`, `search`.

Ejemplo (fragmento sugerido docker-compose.prod.yml):
```yaml
version: '3.9'
services:
	eureka:
		image: ${ECR_URI}/eureka:latest
		env_file: ../eureka/.env
	operator:
		image: ${ECR_URI}/operator:latest
		env_file: ../operator/.env
		depends_on:
			- db
			- eureka
	search:
		image: ${ECR_URI}/search:latest
		env_file: ../search/.env
		depends_on:
			- eureka
	cloud-gateway:
		image: ${ECR_URI}/cloud-gateway:latest
		env_file: ./.env
		depends_on:
			- eureka
			- operator
			- search
		ports:
			- "8762:8762"
	db:
		image: postgres:16
		environment:
			POSTGRES_DB: operator_db
			POSTGRES_USER: postgres
			POSTGRES_PASSWORD: postgres
		volumes:
			- pgdata:/var/lib/postgresql/data
	elasticsearch:
		image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
		environment:
			- discovery.type=single-node
			- xpack.security.enabled=false
		ports:
			- "9200:9200" # Solo si lo necesitas público (mejor eliminar)
		volumes:
			- esdata:/usr/share/elasticsearch/data
volumes:
	pgdata:
	esdata:
```

---
## Paso 1. Configurar cuenta AWS (mínimo vital)
1. Inicia sesión en la consola.
2. Cambia región (ej: `us-east-1` o la más cercana a ti).
3. Crea un **usuario IAM** para CI/CD:
	 - IAM > Users > Create user: `cicd-deploy`
	 - Access type: *Programmatic access*.
	 - Adjunta política administrada temporal: `AmazonEC2FullAccess`, `AmazonEC2ContainerRegistryFullAccess`. (Luego puedes restringir).
	 - Guarda `AWS_ACCESS_KEY_ID` y `AWS_SECRET_ACCESS_KEY`.
4. Crea **par de llaves SSH**: EC2 > Key Pairs > Create (nombre: `deploy-key`). Descarga `.pem`.
5. Crea **Security Group**: `microservices-sg`:
	 - Inbound:
		 - SSH (22) tu IP
		 - TCP 8762 (Gateway) 0.0.0.0/0 (o tu IP para más seguridad)
		 - (Opcional) TCP 9200 si quieres inspeccionar Elasticsearch (mejor omitir)
	 - Outbound: all.

Costos aproximados: t3.micro (free tier / bajo), almacenamiento EBS 8–16GB, ECR sólo cobra almacenamiento (~0.10 USD/GB/mes). Mantén pocas tags.

---
## Paso 2. Crear repositorios ECR
Por cada microservicio:
1. ECR > Create repository
	 - `unir-f1011/cloud-gateway`
	 - `unir-f1011/eureka`
	 - `unir-f1011/operator`
	 - `unir-f1011/search`
2. Apunta el URI de cada repo: `ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/<nombre>`.

Opcional: usa un único repositorio con tags distintas (`gateway:latest`, etc.) — pero repos separados facilitan limpieza.

---
## Paso 3. Crear instancia EC2
1. EC2 > Launch instance
	 - Nombre: `microservices-host`
	 - AMI: Amazon Linux 2023 (o Ubuntu 22.04 LTS)
	 - Tipo: t3.micro (o t3.small si Elasticsearch pesa)
	 - Key pair: `deploy-key`
	 - Security Group: `microservices-sg`
	 - Storage: 20GB gp3 (para imágenes + datos).
2. Lanzar.
3. Conectar por SSH:
```bash
ssh -i deploy-key.pem ec2-user@EC2_PUBLIC_IP
```
4. Instalar Docker + Docker Compose (Ubuntu 22.04 LTS en AWS):
```bash
# Actualizar índices
sudo apt-get update -y

# Dependencias para repositorio Docker
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Clave GPG y repo oficial Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
	sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Instalar Docker Engine + plugin compose
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Añadir usuario ubuntu al grupo docker (cerrar sesión tras esto o usar newgrp)
sudo usermod -aG docker ubuntu
newgrp docker <<'EOF'
docker version
docker compose version
EOF

# (Opcional) Habilitar arranque automático
sudo systemctl enable docker
```

> Fallback (solo si plugin compose no está disponible o necesitas versión fija):
```bash
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4)
sudo curl -L https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose version
```
5. Cerrar sesión y volver a entrar (para aplicar grupo docker).
6. Crear estructura de despliegue:
```bash
mkdir -p /opt/microservices && cd /opt/microservices
mkdir env
``` 
7. Copia tus `.env` (manual via scp o editar con nano).

---
## Paso 4. Preparar docker-compose para producción en el servidor
En `/opt/microservices/docker-compose.yml` coloca (ajustando URIs ECR):
```yaml
version: '3.9'
services:
	eureka:
		image: 905357847082.dkr.ecr.us-east-1.amazonaws.com/eureka:latest
		env_file: ./env/eureka.env
		restart: unless-stopped
	operator:
		image: 905357847082.dkr.ecr.us-east-1.amazonaws.com/operator:latest
		env_file: ./env/operator.env
		depends_on: [eureka, db]
		restart: unless-stopped
	search:
		image: 905357847082.dkr.ecr.us-east-1.amazonaws.com/search:latest
		env_file: ./env/search.env
		depends_on: [eureka]
		restart: unless-stopped
	cloud-gateway:
		image: 905357847082.dkr.ecr.us-east-1.amazonaws.com/cloud-gateway:latest
		env_file: ./env/gateway.env
		depends_on: [eureka, operator, search]
		ports:
			- "8762:8762"
		restart: unless-stopped
	db:
		image: postgres:16
		environment:
			POSTGRES_DB: operator_db
			POSTGRES_USER: postgres
			POSTGRES_PASSWORD: postgres
		volumes:
			- pgdata:/var/lib/postgresql/data
		restart: unless-stopped
	elasticsearch:
		image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
		environment:
			- discovery.type=single-node
			- xpack.security.enabled=false
		volumes:
			- esdata:/usr/share/elasticsearch/data
		restart: unless-stopped
volumes:
	pgdata:
	esdata:
```
> Si los recursos son muy limitados: eliminar Elasticsearch o moverlo a un servicio gestionado más tarde.

Probar manualmente (una vez que existan imágenes):
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
docker compose pull
docker compose up -d
docker compose ps
```

---
## Paso 5. Configurar GitHub Secrets
En tu repositorio (Settings > Secrets and variables > Actions > New repository secret):
| Nombre | Valor |
|--------|-------|
| AWS_ACCESS_KEY_ID | (del usuario IAM) |
| AWS_SECRET_ACCESS_KEY | (del usuario IAM) |
| AWS_REGION | us-east-1 (o tu región) |
| ECR_ACCOUNT_ID | Tu número de cuenta |
| EC2_HOST | IP pública de la instancia |
| EC2_USER | ec2-user (Amazon Linux) / ubuntu (si Ubuntu) |
| EC2_SSH_KEY | Contenido base64 del .pem (opción A) |
| SSH_PRIVATE_KEY | Clave privada (opción B más común para actions/ssh) |

> Elige UNA forma: usar `appleboy/ssh-action` con `SSH_PRIVATE_KEY` es sencillo.

---
## (Nuevo) Estrategia Multi‑Repositorio (tu escenario actual)
Tienes cada microservicio en un repositorio distinto:

| Servicio | Repo GitHub |
|----------|-------------|
| Frontend | `Unir-F1011/inventario-front` |
| Gateway  | `Unir-F1011/cloud-gateway` |
| Eureka   | `Unir-F1011/eureka` |
| Operator | `Unir-F1011/operator` |
| Search   | `Unir-F1011/search` |

No “subes código a AWS”: sólo subes código a GitHub. GitHub Actions construye imágenes y las publica en **ECR**; EC2 solamente hace `pull` de imágenes actualizadas. Tus opciones:

### Opción A (más simple) – Pipeline por servicio (Build + Deploy parcial)
Cada repo backend tiene su propio workflow que:
1. Se dispara con push (main / dev).
2. Construye SU imagen y la sube a ECR.
3. Se conecta a EC2 y ejecuta sólo:
	 ```bash
	 docker compose pull <service>
	 docker compose up -d <service>
	 ```
	 (Siempre que `docker-compose.yml` ya exista en el servidor con todas las definiciones.)

Ventajas: despliegue rápido y aislado. Contras: lógica duplicada (5 workflows muy parecidos).

### Opción B – Repo "infra" (centralizador)
Crear un repositorio adicional (p.ej. `infra-microservices`) que:
1. Contiene `docker-compose.yml` de producción y la carpeta `scripts/`.
2. Usa acciones para clonar (checkout) cada repo (usando `actions/checkout` con `repository:`) y construir todas las imágenes juntas.
3. Despliega en lote (todos los servicios) tras cada cambio en cualquier repo (mediante `repository_dispatch` o un workflow que periódicamente (cron) sincroniza).

Ventajas: fuente de verdad única para infra. Contras: necesitas token con permisos para leer repos privados y triggers extra.

### Opción C – Build distribuido + Deploy central
1. Cada servicio hace solo build + push (NO SSH).
2. Al terminar, emite un `repository_dispatch` a un repo infra central.
3. Repo infra escucha todos los dispatch y ejecuta un deploy (puede agregar lógica para agrupar cambios en ventana de 2-5 min).

### Recomendación inicial
Usa **Opción A** (rápida y mínima) para comenzar. Si crece la complejidad, migras a B/C.

### Variables / Secrets mínimos por cada repo backend
Debes repetir (o usar Organization secrets) en: `cloud-gateway`, `eureka`, `operator`, `search`:
| Secret | Comentario |
|--------|-----------|
| AWS_ACCESS_KEY_ID | Usuario IAM CI/CD |
| AWS_SECRET_ACCESS_KEY | Usuario IAM CI/CD |
| AWS_REGION | ej: us-east-1 |
| ECR_ACCOUNT_ID | Número de cuenta |
| EC2_HOST | IP pública EC2 |
| EC2_USER | `ubuntu` si usas Ubuntu 22.04 |
| SSH_PRIVATE_KEY | Clave privada para SSH |

Frontend (inventario-front) puede tener su propio flujo (deploy a S3+CloudFront / Vercel / Nginx) fuera del alcance backend actual.

### Ejemplo Workflow Opción A (en repo `operator` – similar en los demás)
Archivo `.github/workflows/deploy.yml`:
```yaml
name: Build & Deploy Operator

on:
	push:
		branches: [ "main", "dev-miguel" ]
	workflow_dispatch:

env:
	AWS_REGION: ${{ secrets.AWS_REGION }}
	ACCOUNT_ID: ${{ secrets.ECR_ACCOUNT_ID }}
	REGISTRY: ${{ secrets.ECR_ACCOUNT_ID }}.dkr.ecr.${{ secrets.AWS_REGION }}.amazonaws.com
	IMAGE_NAME: operator

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
					aws-region: ${{ secrets.AWS_REGION }}

			- name: Login to ECR
				uses: aws-actions/amazon-ecr-login@v2

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
						aws ecr get-login-password --region ${{ secrets.AWS_REGION }} | docker login --username AWS --password-stdin $REGISTRY
						docker compose pull $IMAGE_NAME
						docker compose up -d $IMAGE_NAME
						docker image prune -f
```

Repite cambiando `IMAGE_NAME` en cada repo. Asegúrate que en `docker-compose.yml` del servidor el nombre del servicio coincide (`operator`, `search`, etc.).

### Ejemplo Workflow Infra Central (Opcional – Opción B)
En repo `infra-microservices`:
```yaml
name: Build All & Deploy
on:
	workflow_dispatch:
	schedule:
		- cron: '0 */6 * * *'  # cada 6h (ejemplo)

env:
	AWS_REGION: ${{ secrets.AWS_REGION }}
	ACCOUNT_ID: ${{ secrets.ECR_ACCOUNT_ID }}
	REGISTRY: ${{ secrets.ECR_ACCOUNT_ID }}.dkr.ecr.${{ secrets.AWS_REGION }}.amazonaws.com

jobs:
	build-all:
		runs-on: ubuntu-latest
		steps:
			- name: Checkout infra repo
				uses: actions/checkout@v4

			- name: Checkout gateway
				uses: actions/checkout@v4
				with:
					repository: Unir-F1011/cloud-gateway
					path: cloud-gateway
			- name: Checkout eureka
				uses: actions/checkout@v4
				with:
					repository: Unir-F1011/eureka
					path: eureka
			- name: Checkout operator
				uses: actions/checkout@v4
				with:
					repository: Unir-F1011/operator
					path: operator
			- name: Checkout search
				uses: actions/checkout@v4
				with:
					repository: Unir-F1011/search
					path: search

			- name: Configure AWS Credentials
				uses: aws-actions/configure-aws-credentials@v4
				with:
					aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
					aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
					aws-region: ${{ secrets.AWS_REGION }}

			- name: Login to ECR
				uses: aws-actions/amazon-ecr-login@v2

			- name: Build & Push (matrix manual)
				run: |
					for S in cloud-gateway eureka operator search; do \
						docker build -t $REGISTRY/$S:latest $S; \
						docker push $REGISTRY/$S:latest; \
					done

	deploy:
		runs-on: ubuntu-latest
		needs: build-all
		steps:
			- name: Deploy via SSH
				uses: appleboy/ssh-action@v1.2.0
				with:
					host: ${{ secrets.EC2_HOST }}
					username: ${{ secrets.EC2_USER }}
					key: ${{ secrets.SSH_PRIVATE_KEY }}
					script: |
						cd /opt/microservices
						aws ecr get-login-password --region ${{ secrets.AWS_REGION }} | docker login --username AWS --password-stdin $REGISTRY
						docker compose pull
						docker compose up -d
						docker image prune -f
```

> Repos privados: necesitarás un **Fine-grained PAT** como secret `GH_TOKEN` y añadir `token: ${{ secrets.GH_TOKEN }}` en cada paso `actions/checkout`.

### Tagging recomendado
Publicar `latest` + `sha` siempre. Para prod estable: añadir tag semántico manual (`v1.0.0`). Ejemplo en build parcial:
```bash
docker tag $REGISTRY/$IMAGE_NAME:latest $REGISTRY/$IMAGE_NAME:v1.0.0
docker push $REGISTRY/$IMAGE_NAME:v1.0.0
```

### Rollback rápido (Opción A)
En EC2:
```bash
docker compose images | grep operator
docker compose pull operator:shaAnterior || docker pull $REGISTRY/operator:shaAnterior
sed -i 's/operator:latest/operator:shaAnterior/' docker-compose.yml
docker compose up -d operator
```

### Checklist Multi‑Repo inicial
- [ ] Workflow por servicio creado (4 backends)
- [ ] Secrets replicados u Organization secrets
- [ ] `docker-compose.yml` con nombres de servicio correctos
- [ ] Primera build y push verificada en ECR
- [ ] Despliegue parcial exitoso (al menos un servicio)

---
## Paso 6. Workflow GitHub Actions (build + push + deploy)
Crear `.github/workflows/deploy.yml`:
```yaml
name: CI/CD Microservices

on:
	push:
		branches: [ "dev-miguel", "main" ]
	workflow_dispatch:

env:
	AWS_REGION: ${{ secrets.AWS_REGION }}
	ACCOUNT_ID: ${{ secrets.ECR_ACCOUNT_ID }}
	REGISTRY: ${{ secrets.ECR_ACCOUNT_ID }}.dkr.ecr.${{ secrets.AWS_REGION }}.amazonaws.com

jobs:
	build-and-push:
		runs-on: ubuntu-latest
		steps:
			- name: Checkout
				uses: actions/checkout@v4

			- name: Configure AWS Credentials
				uses: aws-actions/configure-aws-credentials@v4
				with:
					aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
					aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
					aws-region: ${{ secrets.AWS_REGION }}

			- name: Login to ECR
				uses: aws-actions/amazon-ecr-login@v2

			- name: Build & Push cloud-gateway
				run: |
					docker build -t $REGISTRY/cloud-gateway:latest cloud-gateway
					docker push $REGISTRY/cloud-gateway:latest
			- name: Build & Push eureka
				run: |
					docker build -t $REGISTRY/eureka:latest eureka
					docker push $REGISTRY/eureka:latest
			- name: Build & Push operator
				run: |
					docker build -t $REGISTRY/operator:latest operator
					docker push $REGISTRY/operator:latest
			- name: Build & Push search
				run: |
					docker build -t $REGISTRY/search:latest search
					docker push $REGISTRY/search:latest

	deploy:
		runs-on: ubuntu-latest
		needs: build-and-push
		steps:
			- name: Deploy via SSH
				uses: appleboy/ssh-action@v1.2.0
				with:
					host: ${{ secrets.EC2_HOST }}
					username: ${{ secrets.EC2_USER }}
					key: ${{ secrets.SSH_PRIVATE_KEY }}
					script: |
						cd /opt/microservices
						aws ecr get-login-password --region ${{ secrets.AWS_REGION }} | docker login --username AWS --password-stdin $REGISTRY
						docker compose pull
						docker compose up -d
						docker image prune -f
```

### Notas
- Puedes versionar imágenes con el SHA del commit: añade `:${{ github.sha }}` además de `:latest`.
- Para rollback: conserva la tag anterior o apunta manualmente en `docker-compose.yml`.

---
## Paso 7. Variables de entorno y secretos
Ejemplos de archivos `/opt/microservices/env/*.env`:
`gateway.env`:
```env
SERVER_NAME=ms-cloud-gateway
ALLOWED_ORIGINS=*
ROUTE_TABLES_ENABLED=true
SERVER_PORT=8762
EUREKA_URL=http://eureka:8761/eureka
```
`eureka.env`:
```env
SERVER_NAME=ms-eureka
SERVER_PORT=8761
EUREKA_HOST=localhost
EUREKA_RENEWAL=0.90
```
`operator.env`:
```env
SERVER_NAME=ms-operator
SERVER_PORT=8082
DB_URL=jdbc:postgresql://db:5432/operator_db
DB_USER=postgres
DB_PASSWORD=postgres
EUREKA_URL=http://eureka:8761/eureka
```
`search.env`:
```env
SERVER_NAME=ms-search
SERVER_PORT=8081
EUREKA_URL=http://eureka:8761/eureka
ELASTICSEARCH_HOST=elasticsearch:9200
ELASTICSEARCH_USER=elastic
ELASTICSEARCH_PWD=changeme
```

---
## Paso 8. Pruebas rápidas tras despliegue
1. `docker compose ps` en EC2.
2. `curl http://localhost:8762/actuator/health` (SSH) -> debe ser UP.
3. Desde tu máquina: `curl http://EC2_PUBLIC_IP:8762/ms-operator/...` (cuando las rutas estén configuradas por discovery locator).
4. Verifica Eureka UI: `http://EC2_PUBLIC_IP:8761` (si abriste el puerto; de lo contrario accede por túnel SSH).

---
## Paso 9. Optimización de costos
- Apaga la instancia cuando no la uses (Stop Instance) para no facturar cómputo (almacenamiento EBS sí se cobra).
- Elimina imágenes antiguas (workflow ya hace `docker image prune -f`).
- Evita exponer puertos innecesarios (no publiques 9200 si no hace falta).
- Usa `t3.micro` si Elasticsearch no es crítico; o ejecuta sin Elasticsearch para la demo si no se exige.

---
## Paso 10. Checks de seguridad rápidos
- Limita SSH a tu IP específica.
- No subir `.env` reales al repo.
- Considera rotar las keys IAM tras la demo.
- Añade `ufw`/NACL reglas si usas más capas (opcional).

---
## (Opcional) Variante ECS Fargate (resumen ultra breve)
1. Crear repositorios ECR (igual que antes).
2. Crear Cluster ECS.
3. Definir Task Definition con múltiples contenedores (eureka, operator, search, gateway, db, elasticsearch) – todos en la misma task (inaceptable para prod, pero reduce complejidad).
4. Crear Service (Desired count 1) + asignar ALB escuchando puerto 8762 -> target group contenedor gateway.
5. GitHub Actions: en lugar de SSH, usar acción `aws ecs deploy` (ej: `aws-actions/amazon-ecs-deploy-task-definition@v1`).
6. Actualizar Task Definition JSON reemplazando las imágenes con el nuevo tag.

> Esta opción consume más tiempo en configuración de IAM, ALB, roles, y no es ideal para una ventana de 6 horas si eres principiante.

---
## Problemas comunes
| Problema | Causa | Solución |
|----------|-------|----------|
| 403 al hacer login ECR | Credenciales IAM sin permisos | Revisar políticas ECR Full Access o crear política mínima |
| Contenedor reinicia en loop | Variables de entorno faltan | Ver logs `docker logs <container>` |
| Eureka no muestra servicios | Arrancaron antes de Eureka | Reiniciar servicios dependientes o esperar 30s |
| Gateway 502/503 | Service ID incorrecto | Confirmar `spring.application.name` y discovery locator |
| Postgres no persiste | Volumen faltante | Ver sección `pgdata` |

---
## Checklist final (antes de la demo)
- [ ] IAM usuario creado y secrets añadidos en GitHub
- [ ] Repos ECR creados
- [ ] EC2 con Docker operativo
- [ ] docker-compose.yml en `/opt/microservices`
- [ ] `.env` copiadas en `/opt/microservices/env/`
- [ ] Workflow ejecutó build & push correctamente
- [ ] Despliegue vía Actions exitoso
- [ ] Endpoint health responde
- [ ] Solo puerto gateway público

---
## Siguientes pasos futuros
- Añadir HTTPS (ACM + Nginx reverse proxy o ALB con certificado).
- Separar servicios en distintas tasks/instancias para escalado real.
- Añadir observabilidad (Prometheus/Grafana / CloudWatch logs centralizados).
- Implementar versionado semántico de imágenes.

---
Guía terminada.

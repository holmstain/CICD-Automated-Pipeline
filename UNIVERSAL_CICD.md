# Universal Docker CI/CD template

This directory is a reusable GitHub Actions + GHCR + VPS blue/green deployment template. Pipeline logic does not depend on the application's language. Each project supplies a Dockerfile that builds its own application and follows the runtime contract below.

## Copy into a project

1. Copy `.github/workflows/deploy.yml`, `scripts/deploy.sh`, `docker-compose.yml`, and `nginx.conf` into the repository root. Adapt `Dockerfile` to the app; the included file is a runnable static smoke example.
2. The workflow assumes a public GitHub repository cloned on the VPS at `/opt/OWNER/REPOSITORY`. Set GitHub Actions secrets `VPS_HOST`, `VPS_USER`, and `VPS_SSH_KEY`.
3. Follow `DEPLOYMENT.md` to provision Docker, Nginx, TLS, `active-port.conf`, and the untracked `.env.production` file.
4. Push to `main`. Each image is tagged with the full commit SHA and `latest`; deployment uses the immutable SHA tag.

## Dockerfile contract

- Final image listens on `0.0.0.0:8080` and returns HTTP 200 from `GET /health` only when ready to receive traffic.
- Use a multi-stage build: compile/build in a builder stage, then copy only runtime artifacts and required runtime dependencies into a small final image.
- Run as a non-root user when the runtime supports it. Do not bake secrets into build arguments or image layers.
- Ensure the runtime handles `SIGTERM` and exits cleanly. The Compose services provide init, restart policy, dropped Linux capabilities, and no-new-privileges.

## Multi-stage examples

Adapt paths and commands to the project; each final stage must implement the contract above.

### Node.js

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine AS runtime
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
USER node
EXPOSE 8080
CMD ["node", "dist/server.js"]
```

### Python

```dockerfile
FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt
COPY . .

FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080
WORKDIR /app
COPY --from=build /wheels /wheels
RUN pip install --no-cache-dir /wheels/* && rm -rf /wheels \
    && useradd --system --uid 10001 app
COPY --from=build --chown=app:app /build /app
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
```

### Go

```dockerfile
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/server

FROM scratch AS runtime
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
```

These are starting points, not universal build recipes: dependency files, build commands, and entrypoints vary by application. Verify the actual image's port and `/health` behavior before deployment.

## Deployment behavior

The workflow serializes production deployments, builds and pushes SHA + `latest` tags, then uses SSH to fetch the deployed commit and run the script. The script starts the inactive slot on loopback port 3001 or 3002, waits for `/health`, atomically changes the Nginx include, validates with `nginx -t`, reloads Nginx, drains the old slot, and removes its container. Failed health checks leave the active slot serving traffic. Nginx validation/reload errors restore the previous upstream config.

Image pruning is filtered by the repository's OCI source label. Without labels, `docker image prune -f` removes dangling images across the whole Docker daemon, including unrelated projects. A single VPS remains a single failure domain; WebSocket or long-running requests may need a longer drain interval.

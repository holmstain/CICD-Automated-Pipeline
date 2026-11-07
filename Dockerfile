# Runnable static smoke template. Replace stages for each application
# while preserving the port and health endpoint contract in UNIVERSAL_CICD.md.
FROM alpine:3.21 AS build
RUN mkdir -p /site && printf '<h1>Deployment template</h1>\n' > /site/index.html \
    && printf 'ok\n' > /site/health

FROM nginx:1.27-alpine AS runtime
RUN rm -f /etc/nginx/conf.d/default.conf \
    && printf 'server { listen 8080; root /usr/share/nginx/html; location = /health { access_log off; default_type text/plain; } }\n' \
       > /etc/nginx/conf.d/default.conf
COPY --from=build /site/ /usr/share/nginx/html/
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

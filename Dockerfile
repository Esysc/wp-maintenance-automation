FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    rsync \
    openssh-client \
    gzip \
    tar \
    restic \
   coreutils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY scripts /app/scripts
COPY .env.example /app/.env.example
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/scripts/*.sh /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]

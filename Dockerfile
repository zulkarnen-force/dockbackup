FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    docker-cli \
    postgresql-client \
    mysql-client \
    mongodb-tools \
    jq \
    tzdata \
    rclone

WORKDIR /app

COPY backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

ENTRYPOINT ["/app/backup.sh"]
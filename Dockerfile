FROM alpine:3.19

RUN apk add --no-cache \
    bash=5.2.21-r0 \
    docker-cli=25.0.5-r1 \
    postgresql16-client=16.11-r0 \
    mysql-client=10.11.14-r0 \
    mongodb-tools=100.8.0-r5 \
    jq=1.7.1-r0 \
    tzdata=2025b-r0 \
    rclone=1.65.0-r3

WORKDIR /app

COPY backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

ENTRYPOINT ["/app/backup.sh"]
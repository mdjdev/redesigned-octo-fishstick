FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    git \
    inotify-tools \
    openssh-client \
    ca-certificates

RUN addgroup -S gitwatch && \
    adduser -S -G gitwatch -h /app gitwatch

RUN wget -O /usr/local/bin/gitwatch \
    https://raw.githubusercontent.com/gitwatch/gitwatch/dfdd3bd/gitwatch.sh && \
    chmod +x /usr/local/bin/gitwatch

# COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER gitwatch

WORKDIR /mnt/repo

# ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

ENTRYPOINT ["/usr/local/bin/gitwatch"]

CMD [ "-r", "origin", "-b", "main", "/mnt/repo" ]

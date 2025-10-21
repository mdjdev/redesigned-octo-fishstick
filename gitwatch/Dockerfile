FROM alpine:3.22

RUN apk add --no-cache \
      bash \
      git \
      inotify-tools \
      openssh-client \
      ca-certificates \
    && update-ca-certificates

ARG USERNAME=gitwatch
ARG UID=1026
ARG GID=100

RUN addgroup -S -g ${GID} ${USERNAME} || true
RUN adduser -S -D -h /home/${USERNAME} -s /bin/sh -G users -u ${UID} ${USERNAME} || true
RUN mkdir -p /home/${USERNAME} && chown ${UID}:${GID} /home/${USERNAME}

# RUN set -eux; \
#   if ! getent group "${GID}" >/dev/null; then echo "Group with GID ${GID} not found"; exit 1; fi; \
#   group_name="$(getent group ${GID} | cut -d: -f1)"; \
#   if ! getent passwd "${UID}" >/dev/null; then \
#   adduser -S -D -h "/home/${USERNAME}" -s /bin/sh -G "${group_name}" -u "${UID}" "${USERNAME}"; \
#   fi; \
#   mkdir -p "/home/${USERNAME}" && chown "${UID}:${GID}" "/home/${USERNAME}" 

RUN mkdir -p /mnt/.git && chown ${UID}:${GID} /mnt/.git

RUN wget -O /usr/local/bin/gitwatch \
    https://raw.githubusercontent.com/gitwatch/gitwatch/dfdd3bd/gitwatch.sh && \
    chmod +x /usr/local/bin/gitwatch

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY gitwatch-pre-flight.sh /usr/local/bin/gitwatch-pre-flight.sh
RUN chmod +x /usr/local/bin/gitwatch-pre-flight.sh

USER ${UID}:${GID}

WORKDIR /mnt/repo

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# ENTRYPOINT ["/usr/local/bin/gitwatch"]

CMD [ "-r", "origin", "-b", "main", "-R", "-g", "/mnt/.git", "/mnt/repo" ]

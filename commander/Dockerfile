FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    git \
    openssh-client \
    ca-certificates && \
    update-ca-certificates

ARG USERNAME=commander
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

USER ${UID}:${GID}

WORKDIR /mnt

CMD ["sleep","infinity"]

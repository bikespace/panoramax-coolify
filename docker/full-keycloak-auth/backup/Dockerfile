FROM alpine:3.24
# supercronic, rclone and restic are installed from their upstream release
# binaries, each pinned to a version and verified against a hash.
ARG SUPERCRONIC_VERSION=0.2.51
ARG SUPERCRONIC_SHA1=1692066e350a88ff4d7d6474fe3c7a6c41ec5e89
ARG RCLONE_VERSION=1.76.0
ARG RCLONE_SHA256=b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7
ARG RESTIC_VERSION=0.19.1
ARG RESTIC_SHA256=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
RUN apk add --no-cache postgresql16-client ca-certificates tzdata gettext \
 && apk add --no-cache --virtual .build-deps curl \
 && cd /tmp \
 && curl -fsSL -o supercronic \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1}  supercronic" | sha1sum -c - \
 && install -m 0755 supercronic /usr/local/bin/supercronic \
 && curl -fsSL -o rclone.zip \
      "https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" \
 && echo "${RCLONE_SHA256}  rclone.zip" | sha256sum -c - \
 && unzip -q rclone.zip \
 && install -m 0755 "rclone-v${RCLONE_VERSION}-linux-amd64/rclone" /usr/local/bin/rclone \
 && curl -fsSL -o restic.bz2 \
      "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" \
 && echo "${RESTIC_SHA256}  restic.bz2" | sha256sum -c - \
 && bunzip2 restic.bz2 \
 && install -m 0755 restic /usr/local/bin/restic \
 && rm -rf /tmp/* \
 && apk del --no-network .build-deps
COPY *.sh /usr/local/bin/
COPY crontab.template /etc/crontab.template
RUN chmod +x /usr/local/bin/*.sh
CMD ["entrypoint.sh"]

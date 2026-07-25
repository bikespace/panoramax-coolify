FROM alpine:3.20
# supercronic pinned to v0.2.33 and verified against the SHA1 published on the
# upstream release (aptible/supercronic only publishes SHA1, not SHA256). The
# build fails closed if the downloaded binary's hash doesn't match — this
# container holds every app secret and both S3 key sets, so an unverified
# download here would be a supply-chain foothold.
RUN apk add --no-cache postgresql16-client rclone restic ca-certificates tzdata curl gettext \
 && curl -fsSL -o /tmp/supercronic \
      https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
 && echo "71b0d58cc53f6bd72cf2f293e09e294b79c666d8  /tmp/supercronic" | sha1sum -c - \
 && install -m 0755 /tmp/supercronic /usr/local/bin/supercronic \
 && rm /tmp/supercronic
COPY *.sh /usr/local/bin/
COPY crontab.template /etc/crontab.template
RUN chmod +x /usr/local/bin/*.sh
CMD ["entrypoint.sh"]

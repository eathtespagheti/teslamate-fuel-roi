FROM postgres:18-alpine
RUN apk add --no-cache curl jq
COPY scripts/fetch.sh scripts/import.sh scripts/entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/*.sh \
 && adduser -D -u 10001 fuelroi
USER 10001
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

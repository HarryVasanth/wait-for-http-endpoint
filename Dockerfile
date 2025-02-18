FROM alpine:3

COPY wait-for-http-endpoint.sh /wait-for-http-endpoint.sh
RUN chmod +x /wait-for-http-endpoint.sh && \
    apk add --no-cache curl

ENTRYPOINT ["/wait-for-http-endpoint.sh"]


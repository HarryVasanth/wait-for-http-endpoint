FROM alpine:3

# Install curl and remove apk cache for a smaller image footprint
RUN apk add --no-cache curl && \
    rm -rf /var/cache/apk/*

COPY wait-for-http-endpoint.sh /wait-for-http-endpoint.sh
RUN chmod +x /wait-for-http-endpoint.sh

ENTRYPOINT ["/wait-for-http-endpoint.sh"]
FROM alpine:latest
RUN apk add --no-cache curl
COPY wait-for-http-endpoint.sh /wait-for-http-endpoint.sh
RUN chmod +x /wait-for-http-endpoint.sh
ENTRYPOINT ["/wait-for-http-endpoint.sh"]

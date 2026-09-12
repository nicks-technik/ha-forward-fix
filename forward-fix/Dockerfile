ARG BUILD_FROM
FROM $BUILD_FROM
RUN apk add --no-cache iptables ip6tables jq mosquitto-clients
COPY run.sh /run.sh
RUN chmod +x /run.sh
CMD ["/run.sh"]

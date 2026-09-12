ARG BUILD_FROM
# Base image is injected per-arch by the Supervisor (see build.yaml).
# hadolint ignore=DL3006
FROM $BUILD_FROM
# Floating apk versions are intentional: rebuilt monthly, always patched.
# hadolint ignore=DL3018
RUN apk add --no-cache iptables ip6tables jq mosquitto-clients
COPY run.sh lib.sh /
RUN chmod +x /run.sh
CMD ["/run.sh"]

ARG BUILD_FROM
# hadolint ignore=DL3006
# Base image is injected per-arch by the Supervisor (see build.yaml).
FROM $BUILD_FROM
# hadolint ignore=DL3018
# Floating apk versions are intentional: rebuilt monthly, always patched.
RUN apk add --no-cache iptables ip6tables jq mosquitto-clients
COPY run.sh lib.sh /
RUN chmod +x /run.sh
CMD ["/run.sh"]

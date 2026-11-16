# Base image pinned in poc/versions.env (ALPINE_IMAGE), passed by poc/build.sh.
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache bash curl jq openssl

COPY provision-root-ca.sh /usr/local/bin/provision-root-ca.sh

# Same UID as the proxy: the legacy private key on the PVC is 0600.
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/provision-root-ca.sh"]

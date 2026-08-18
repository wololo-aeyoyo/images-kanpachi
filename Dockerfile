# Kanpachi host node, as a sidecar for the Project Zomboid pod.
#
# There is no upstream container image, so we unpack the release .deb. `apt
# install` is not an option: the package declares `Depends: nftables, libc6,
# systemd` and its postinst calls systemctl, neither of which survives in a
# container. `dpkg-deb -x` takes the payload and leaves the maintainer scripts
# alone, which is exactly what we want.
FROM ubuntu:24.04

ARG KANPACHI_VERSION=v0.4.0
ARG KANPACHI_REPO=https://github.com/alvarogabrielgomez/kanpachi
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl nftables iproute2 iputils-ping jq socat \
 && rm -rf /var/lib/apt/lists/*

# The release filename is kept so `sha256sum -c` matches its manifest entry.
# --ignore-missing because SHA256SUMS-linux also covers the kanpseed binaries,
# which this image has no use for.
RUN curl -fsSL -o /tmp/kanpachi-amd64.deb \
      "${KANPACHI_REPO}/releases/download/${KANPACHI_VERSION}/kanpachi-amd64.deb" \
 && curl -fsSL -o /tmp/SHA256SUMS-linux \
      "${KANPACHI_REPO}/releases/download/${KANPACHI_VERSION}/SHA256SUMS-linux" \
 && cd /tmp && sha256sum -c SHA256SUMS-linux --ignore-missing \
 && dpkg-deb -x /tmp/kanpachi-amd64.deb / \
 && rm -f /tmp/kanpachi-amd64.deb /tmp/SHA256SUMS-linux \
 && test -x /usr/bin/kanpachi \
 && test -x /usr/libexec/kanpachi/kanpachid \
 && test -x /usr/libexec/kanpachi/kanpachi-engine \
 && test -f /usr/share/kanpachi/builtin.json \
 && install -d -m 0755 /etc/kanpachi \
 && install -d -m 0700 /var/lib/kanpachi

# /etc/kanpachi/quarantine.nft is deliberately NOT asserted here. It is not in
# the package: the daemon writes it on first run, which is why the shipped
# kanpachi-quarantine.service is guarded by ConditionPathExists.

COPY systemctl-shim /usr/local/bin/systemctl
COPY entrypoint.sh  /usr/local/bin/kanpachi-entrypoint
RUN chmod +x /usr/local/bin/systemctl /usr/local/bin/kanpachi-entrypoint

ENTRYPOINT ["/usr/local/bin/kanpachi-entrypoint"]

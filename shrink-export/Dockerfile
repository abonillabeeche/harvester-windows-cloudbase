# Prebuilt tool image for the shrink-export Job (air-gapped clusters).
# Build + push, then set the Job's image: to it and remove the apt-get/curl
# bootstrap from the Job args.
#
#   docker build -t <registry>/harvester-disk-shrink:1.0 shrink-export/
#   docker push  <registry>/harvester-disk-shrink:1.0
FROM debian:12-slim

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        qemu-utils ntfs-3g parted gdisk kpartx curl ca-certificates util-linux \
    && curl -sSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/$(curl -sSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/bin/bash", "/usr/local/bin/entrypoint.sh"]

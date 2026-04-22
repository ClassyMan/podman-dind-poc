# Pinned to Podman 4.9.4 (latest 4.9.x). Matches the 4.9.3 Podman that
# Ubuntu 24.04 ships via apt, with the final patch-level from upstream.
# The stable image is preconfigured with fuse-overlayfs and a user-level
# podman that can nest inside a rootless podman host.
FROM quay.io/podman/stable:v4.9.4

COPY inner-demo.sh /usr/local/bin/inner-demo.sh
RUN chmod +x /usr/local/bin/inner-demo.sh

CMD ["/usr/local/bin/inner-demo.sh"]

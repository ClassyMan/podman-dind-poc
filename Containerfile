# CI agent image: Ubuntu base + rootless podman + JDK + Maven + Testcontainers project.
# This is the pattern a Jenkins / GitLab agent image would follow: an existing
# base, a few extra packages, a handful of /etc/subuid lines, and the project.
FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      podman \
      fuse-overlayfs \
      slirp4netns \
      uidmap \
      dbus-user-session \
      ca-certificates \
      openjdk-21-jdk-headless \
      maven \
 && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a pre-existing `ubuntu` user at UID 1000. Add subuid/subgid
# ranges for it so rootless podman can allocate a nested user namespace. The
# ranges must be a subset of the host user's /etc/subuid ranges.
RUN echo "ubuntu:100000:65536" > /etc/subuid \
 && echo "ubuntu:100000:65536" > /etc/subgid

# Route inner docker.io pulls via Google's mirror.gcr.io pull-through cache to
# avoid Docker Hub's anonymous rate limit when tests pull images (postgres etc.)
COPY registries.conf /etc/containers/registries.conf.d/99-docker-mirror.conf

# /run/user/$UID is usually created by systemd-logind at login; not present in
# a bare Docker container. Rootless podman needs it for its socket.
RUN mkdir -p /run/user/1000 \
 && chown 1000:1000 /run/user/1000 \
 && chmod 0700 /run/user/1000

USER ubuntu
WORKDIR /home/ubuntu/project

# Copy pom first and pre-resolve deps so the test-time container isn't
# re-downloading dependencies on every run.
COPY --chown=ubuntu:ubuntu pom.xml ./
RUN mvn -B -q dependency:go-offline || true

COPY --chown=ubuntu:ubuntu src ./src
COPY --chown=ubuntu:ubuntu entrypoint.sh /home/ubuntu/entrypoint.sh
RUN chmod +x /home/ubuntu/entrypoint.sh

CMD ["/home/ubuntu/entrypoint.sh"]

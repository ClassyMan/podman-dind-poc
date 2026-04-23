# CLAUDE.md — podman-dind-poc

Reference implementation for rootless Podman inside a Docker CI agent (Jenkins-style) as an alternative to Docker-in-Docker. Verified end-to-end by a JUnit 5 + Testcontainers + AssertJ test using LocalStack's S3 API.

## Quick commands

```bash
./run.sh        # build + run the full demo (~5-8 min first time, ~30 s after cache)
./test.sh       # same but asserts PASS/FAIL for CI (exit 0 / 1 / 2)
```

Preconditions on Ubuntu 24.04+ hosts (one-time per host):

```bash
sudo install -m 0644 apparmor-profile/podman-nested.apparmor /etc/apparmor.d/podman-nested
sudo apparmor_parser -r /etc/apparmor.d/podman-nested
```

## What's here

- `Containerfile` — Ubuntu 24.04 + podman + OpenJDK 21 + Maven + the project.
- `entrypoint.sh` — starts rootless Podman's docker-compat socket, exports the three Testcontainers env vars, execs `mvn test`.
- `pom.xml`, `src/test/java/` — the Maven project and the single Testcontainers test.
- `apparmor-profile/podman-nested.apparmor` — 4-line AppArmor profile (`flags=(unconfined) { userns }`) satisfying Ubuntu 24.04+'s `kernel.apparmor_restrict_unprivileged_userns=1`.
- `run.sh`, `test.sh` — orchestration + CI wrapper.
- `registries.conf` — `mirror.gcr.io` pull-through cache for inner `docker.io` pulls.
- `README.md` — five-step "add these OSS pieces to your own setup" guide. Keep it framed that way.
- `MORE_EXAMPLES.md` — Postgres / Kafka / Redis / Mongo / nginx / Spring Boot WAR patterns.
- `docker-equivalent-fails.md` — why `--privileged` and socket-mount each give up isolation.

## Conventions (follow on any future edit)

- Tests use **AssertJ** (`assertThat(...).isEqualTo(...)`, `.as("...")` for descriptions). Not JUnit Jupiter `Assertions`.
- Maven deps pin exact versions — no ranges, no `-SNAPSHOT`.
- README advice is framed as "add these OSS pieces to your existing setup" — **not** "clone and depend on this repo". It's a reference implementation to diff against.
- Repo is public. No references to employer, internal systems, or other private projects.

## Known gotchas (learned 2026-04-22 — don't rediscover)

- `docker build` defaults to looking for `Dockerfile`; this repo has `Containerfile`. `run.sh` passes `-f Containerfile`.
- `TESTCONTAINERS_HOST_OVERRIDE=localhost` is not optional. Testcontainers sees `/.dockerenv` inside the agent, detects "in Docker", and tries the Docker gateway IP. Rootless Podman's `rootlessport` binds on loopback, so JDBC/HTTP clients time out without the override.
- `--cap-add=SYS_ADMIN` is required. Docker's default cap bounding set excludes `CAP_SYS_ADMIN`; setuid `newuidmap` can't elevate to write `/proc/PID/uid_map` without it. The agent's user is still non-root with `CapEff=0`; the cap is only usable transiently by setuid binaries (`newuidmap`, `newgidmap`, `mount`).
- Ubuntu 24.04+ needs the `podman-nested` AppArmor profile loaded on the host. Other distros don't.
- The `ubuntu:24.04` base image already ships with a `ubuntu` user at UID 1000. Don't try to `useradd --uid 1000`; add subuid/subgid for the existing user.
- `/run/user/$UID/` isn't created by systemd-logind inside a bare Docker container. Pre-create it in the `Containerfile`.

## Flag set reference (outer docker run)

```
--device /dev/fuse
--device /dev/net/tun
--cap-add=SYS_ADMIN
--security-opt apparmor=podman-nested
--security-opt seccomp=unconfined
--security-opt systempaths=unconfined
```

Resulting `CapBnd = 0x00000000a82425fb` (15 caps) vs `--privileged`'s `0x000001ffffffffff` (38+).

## Testcontainers env vars (set in entrypoint.sh)

```
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock
TESTCONTAINERS_RYUK_DISABLED=true
TESTCONTAINERS_HOST_OVERRIDE=localhost
```

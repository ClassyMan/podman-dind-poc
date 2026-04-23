# podman-dind-poc

**How to run Testcontainers tests from a Docker-wrapped CI agent without `--privileged` or `/var/run/docker.sock`, using only upstream open-source components: rootless Podman, Testcontainers, and a 4-line AppArmor profile.**

Verified end-to-end by a JUnit 5 + Testcontainers test that spawns a Postgres container and runs `SELECT 42` over JDBC. See [Verify the pattern](#verify-the-pattern) at the bottom.

## The problem

Your Jenkins agent (or GitLab runner, or CircleCI executor) wraps the whole test run in a Docker container. The tests then need to spawn more containers — Testcontainers, integration stacks, etc. The usual options both give up isolation:

- **`docker run --privileged`** — 38+ capabilities, seccomp off, every host device exposed, AppArmor/SELinux off. Escape is trivial.
- **`-v /var/run/docker.sock`** — the inner `docker` command is a client talking to the host's daemon. "Inner" containers are actually the host's. `docker run -v /:/host` from a test → root on host.

## The pattern

Install rootless Podman inside your existing agent image. Before tests run, start Podman's docker-compat socket. Point Testcontainers at it. Your existing test code is unchanged; containers Testcontainers spawns are truly nested (own userns, own overlay store, own netns).

| | Outer `CapBnd` | Seccomp | Inner workload isolation |
| --- | --- | --- | --- |
| `docker run --privileged` | 38+ (all) | off | weak — escape is trivial |
| `-v /var/run/docker.sock` | Docker default (14) | default | **none — siblings of host** |
| **This pattern** | 15 (default + `SYS_ADMIN`) | off | **real nested userns + overlay + netns** |

## What to add to your setup

### 1. Install Podman + its rootless deps in your agent image

For a Debian/Ubuntu base:

```dockerfile
FROM <your existing agent base>

RUN apt-get update && apt-get install -y --no-install-recommends \
      podman \
      fuse-overlayfs \
      slirp4netns \
      uidmap \
      dbus-user-session \
 && rm -rf /var/lib/apt/lists/*

# Add subuid/subgid ranges for your agent user (the container's /etc/subuid
# range must be a subset of the host user's — 100000:65536 is the default on
# Ubuntu for real user accounts).
RUN echo "<agent-user>:100000:65536" >> /etc/subuid \
 && echo "<agent-user>:100000:65536" >> /etc/subgid

# Pre-create /run/user/<uid>; systemd-logind usually creates this on login,
# but bare Docker containers don't have one. Rootless Podman needs it for
# its socket.
RUN mkdir -p /run/user/<agent-uid> \
 && chown <agent-uid>:<agent-uid> /run/user/<agent-uid>
```

On RHEL/Fedora substitute `dnf install podman slirp4netns fuse-overlayfs shadow-utils`. On Alpine, `apk add podman fuse-overlayfs slirp4netns shadow-uidmap`.

### 2. Load a 4-line AppArmor profile on each CI host (Ubuntu 24.04+ only)

Ubuntu 24.04 enables `kernel.apparmor_restrict_unprivileged_userns=1` by default. Processes running under the default "unconfined" AppArmor label can't write `/proc/PID/uid_map`, which rootless Podman needs during nested userns setup. A named profile with an explicit `userns` grant is enough.

Put this somewhere your host provisioning tool can find it:

```
abi <abi/4.0>,
include <tunables/global>

profile podman-nested flags=(unconfined) {
  userns,
}
```

Install once per CI host (golden image, Puppet, Ansible, whatever):

```bash
sudo install -m 0644 podman-nested.apparmor /etc/apparmor.d/podman-nested
sudo apparmor_parser -r /etc/apparmor.d/podman-nested
```

`flags=(unconfined)` means the profile adds no restrictions; it only gives the kernel a named AppArmor context with the `userns` grant it's looking for. RHEL / Fedora / Alpine / older Ubuntu don't need this step — use `--security-opt apparmor=unconfined` (Ubuntu) or just omit the flag entirely (non-AppArmor hosts).

### 3. Start the Podman docker-compat socket in your agent entrypoint

Before `mvn test` (or your equivalent test invocation):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$XDG_RUNTIME_DIR/podman"

# Run Podman's docker-compat API listener in the background. --time=0 keeps
# it running indefinitely until the container exits.
podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" &

# Wait up to 10s for the socket to appear.
for _ in {1..10}; do
  [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ] && break
  sleep 1
done

export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
export TESTCONTAINERS_HOST_OVERRIDE=localhost
```

Three env vars for Testcontainers:

- **`DOCKER_HOST`** — tells Testcontainers where Podman's docker-compat socket is. Testcontainers uses the Docker HTTP API; Podman's `system service` implements that API compatibly.
- **`TESTCONTAINERS_RYUK_DISABLED=true`** — Ryuk is Testcontainers' cleanup-companion container. Its socket-peering approach doesn't play nicely with rootless Podman. Testcontainers' JVM shutdown hooks still clean up containers it created, so you lose only the orphan-recovery safety net for ungraceful JVM crashes.
- **`TESTCONTAINERS_HOST_OVERRIDE=localhost`** — Testcontainers detects `/.dockerenv` and, thinking it's inside Docker, defaults to the Docker gateway IP. Rootless Podman's `rootlessport` binds ports on the agent container's loopback, not the gateway, so force localhost.

### 4. Your Maven deps — nothing Podman-specific

Standard Testcontainers artefacts:

```xml
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>testcontainers</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>junit-jupiter</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>postgresql</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<!-- plus junit-jupiter-api, junit-jupiter-engine, org.postgresql:postgresql -->
```

Test code is exactly what you'd write with Docker:

```java
@Testcontainers
class MyIntegrationTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void postgresIsReachable() throws Exception {
        try (var conn = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var stmt = conn.createStatement();
             var rs = stmt.executeQuery("SELECT 42 AS answer")) {
            assertTrue(rs.next());
            assertEquals(42, rs.getInt("answer"));
        }
    }
}
```

### 5. Run your agent container with the minimal flag set

In your Jenkinsfile agent config (or `docker.image().inside(...)`, or the equivalent in your CI system):

```bash
docker run --rm \
  --device /dev/fuse \                       # for fuse-overlayfs storage
  --device /dev/net/tun \                    # for slirp4netns networking
  --cap-add=SYS_ADMIN \                      # so setuid newuidmap can write uid_map
  --security-opt apparmor=podman-nested \    # Ubuntu 24.04+ userns grant (from step 2)
  --security-opt seccomp=unconfined \        # default seccomp blocks unshare/mount syscalls
  --security-opt systempaths=unconfined \    # default /proc + /sys masking blocks nested /proc
  <your-agent-image>
```

**Not used:** `--privileged`, `-v /var/run/docker.sock`, `--userns=host`, `--net=host`, any other `--cap-add`.

## What each flag concedes

- **Two `--device` entries** — two device nodes. `--privileged` exposes every device node under `/dev`.
- **`--cap-add=SYS_ADMIN`** — one capability, added to the bounding set. The agent user is non-root with `CapEff=0`; only setuid binaries (`newuidmap`, `newgidmap`, `mount`) can exercise this cap, transiently. `--privileged` grants all 38 caps.
- **`apparmor=podman-nested`** — the profile is literally `flags=(unconfined) { userns }`. Four lines. Adds no restrictions beyond the cap set + seccomp.
- **`seccomp=unconfined`** — turns off Docker's default seccomp profile. Cap set + AppArmor still enforce.
- **`systempaths=unconfined`** — restores `/proc` + `/sys` paths that Docker masks by default. Visibility only; nothing writable that wasn't already.

## Caveats

- **cgroups v2** required. Ubuntu 22.04+, RHEL 9+, Fedora 31+.
- **Kernel ≥ 5.11** recommended.
- **Step 2** (AppArmor profile) only needed on Ubuntu 24.04+. On RHEL/Fedora/Alpine/older Ubuntu, skip step 2 and either use `--security-opt apparmor=unconfined` (Ubuntu with AppArmor but without the 24.04+ restriction) or drop the `apparmor=...` flag entirely.
- **`DockerComposeContainer`** needs a compose binary reachable. `podman-compose` works; Podman 4.x's built-in `podman compose` isn't 100% Docker-compose-compatible. Pin `podman-compose` if you use Compose.
- **Docker-only features** (`buildx`, multi-arch builds, `docker manifest`) aren't in Podman's compat layer. Usually irrelevant for test code.
- **Not tested** on cgroups v1, Docker daemons with `userns-remap` enabled, or Kubernetes pod executors.

## Not claimed

- Not a security audit. `--cap-add=SYS_ADMIN` + `seccomp=unconfined` are real concessions — just orders of magnitude narrower than `--privileged`.
- Not a migration guide. `postgres:16-alpine` is smaller than your real test workload.
- See [`docker-equivalent-fails.md`](./docker-equivalent-fails.md) for a deeper breakdown of what `--privileged` and socket-mount each give up.

## Verify the pattern

This repository is a working reference implementation — an Ubuntu 24.04 + Podman + JDK 21 + Maven image containing the JUnit test above, runnable as a single command. It's here to prove the pattern works and to let you diff your own agent against something known-good; it is **not** meant to be depended on.

```bash
git clone https://github.com/ClassyMan/podman-dind-poc
cd podman-dind-poc
# One-time on Ubuntu 24.04+ hosts:
sudo install -m 0644 apparmor-profile/podman-nested.apparmor /etc/apparmor.d/podman-nested
sudo apparmor_parser -r /etc/apparmor.d/podman-nested
./run.sh
```

Expected output:

```
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

`./test.sh` runs the same thing and exits 0/1 for CI.

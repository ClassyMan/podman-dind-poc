# podman-dind-poc

**A working alternative to Docker-in-Docker for CI agents that are themselves Docker containers. The agent runs rootless Podman internally; tests inside use Testcontainers pointed at Podman's docker-compat socket. No `--privileged`, no `/var/run/docker.sock` mount.**

Verified end-to-end by a real JUnit 5 + Testcontainers test that spawns a Postgres container and asserts `SELECT 42` over JDBC.

## The problem

Your Jenkins agent (or GitLab runner, or CircleCI executor) wraps the whole test run in a Docker container. The tests then need to spawn more containers — Testcontainers, integration stacks, etc. The usual options both give up isolation:

- **`docker run --privileged`** — 38+ capabilities, seccomp off, every host device exposed, AppArmor/SELinux off. Escape is trivial.
- **`-v /var/run/docker.sock`** — the inner `docker` command is a client talking to the host's daemon. "Inner" containers are actually the host's. `docker run -v /:/host` from a test → root on host.

## What this does

1. CI agent image = base OS + `podman` + your JDK + Maven + your project.
2. Run the agent with a narrow flag set (not `--privileged`, not a socket mount).
3. Inside, start rootless Podman's docker-compat socket (`podman system service`).
4. Point Testcontainers at it with two env vars:
   ```
   DOCKER_HOST=unix:///run/user/1000/podman/podman.sock
   TESTCONTAINERS_RYUK_DISABLED=true
   TESTCONTAINERS_HOST_OVERRIDE=localhost
   ```
5. Run `mvn test`. Your existing Testcontainers code is unchanged. Containers it spawns are truly nested (their own userns, overlay store, netns).

| | Outer `CapBnd` | Seccomp | Inner workload isolation |
| --- | --- | --- | --- |
| `docker run --privileged` | 38+ (all) | off | weak — escape is trivial |
| `-v /var/run/docker.sock` | Docker default (14) | default | **none — siblings of host** |
| **This repo** | 15 (default + `SYS_ADMIN`) | off | **real nested userns + overlay + netns** |

## Run it

One-time per CI host (Ubuntu 24.04+ only — older distros don't need this):

```bash
sudo install -m 0644 apparmor-profile/podman-nested.apparmor /etc/apparmor.d/podman-nested
sudo apparmor_parser -r /etc/apparmor.d/podman-nested
```

Then any time:

```bash
./run.sh
```

This builds an Ubuntu + Podman + JDK 21 + Maven image containing the test project, runs it under Docker with the minimal flag set, starts Podman's docker-compat socket, and runs `mvn test`. The test asserts:

```
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

`./test.sh` does the same and exits with a PASS/FAIL code for CI.

## Repo layout

```
podman-dind-poc/
├── Containerfile                             # ubuntu + podman + jdk + maven + project
├── entrypoint.sh                             # starts podman socket, sets env, runs mvn test
├── pom.xml                                   # testcontainers + postgres JDBC + junit 5
├── src/test/java/com/classyman/poc/
│   └── PodmanInDockerTest.java               # the real Testcontainers test
├── registries.conf                           # mirror.gcr.io for inner docker.io pulls
├── apparmor-profile/
│   └── podman-nested.apparmor                # 4-line profile for Ubuntu 24.04+ restriction
├── run.sh                                    # docker build + docker run with the 6 flags
├── test.sh                                   # run.sh + assert, exit code for CI
├── docker-equivalent-fails.md                # why --privileged and socket-mount each give up isolation
├── LICENSE
└── .gitignore
```

## The flag set

```bash
docker run --rm \
  --device /dev/fuse \                       # for fuse-overlayfs storage
  --device /dev/net/tun \                    # for slirp4netns networking
  --cap-add=SYS_ADMIN \                      # so setuid newuidmap can write uid_map
  --security-opt apparmor=podman-nested \    # Ubuntu 24.04+ userns grant (4-line profile)
  --security-opt seccomp=unconfined \        # default blocks some unshare/mount syscalls
  --security-opt systempaths=unconfined \    # default /proc + /sys masking blocks nested /proc
  podman-dind-poc:local
```

**Not used**: `--privileged`, `-v /var/run/docker.sock`, `--userns=host`, `--net=host`, any other `--cap-add`.

### What each flag concedes

- **`--device /dev/fuse`, `--device /dev/net/tun`** — two device nodes. `--privileged` exposes every device node under `/dev`.
- **`--cap-add=SYS_ADMIN`** — one capability, only usable by setuid binaries (`newuidmap`, `newgidmap`, `mount`) transiently. The agent's ubuntu user has `CapEff=0`; `--privileged` grants all 38 caps.
- **`apparmor=podman-nested`** — the profile is literally `flags=(unconfined) { userns }`. Four lines. Adds no restrictions beyond the cap set + seccomp.
- **`seccomp=unconfined`** — turns off Docker's default seccomp profile because it blocks syscalls the inner runtime needs. Cap set + AppArmor still enforce.
- **`systempaths=unconfined`** — restores `/proc` + `/sys` paths that Docker masks by default. Visibility only.

## The Testcontainers test

```java
@Testcontainers
class PodmanInDockerTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void postgresContainerIsRunning() {
        assertTrue(POSTGRES.isRunning());
    }

    @Test
    void postgresAcceptsQueriesOverJdbc() throws Exception {
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

Standard `pom.xml` — `org.testcontainers:testcontainers`, `org.testcontainers:junit-jupiter`, `org.testcontainers:postgresql`, `org.postgresql:postgresql`, `org.junit.jupiter:junit-jupiter-api`. No Podman-specific artifact. The plumbing is three env vars set by `entrypoint.sh`:

- `DOCKER_HOST=unix:///run/user/1000/podman/podman.sock` — tell Testcontainers where Podman's docker-compat socket is.
- `TESTCONTAINERS_RYUK_DISABLED=true` — disable the Ryuk reaper companion container; its socket-peering approach doesn't play nicely with rootless Podman. Testcontainers' JVM shutdown hooks still clean up containers it created.
- `TESTCONTAINERS_HOST_OVERRIDE=localhost` — Testcontainers detects `/.dockerenv` and defaults to the Docker gateway IP; rootless Podman's `rootlessport` binds ports on the agent container's loopback, so force localhost.

## Plumbing this into Jenkins

1. In your existing CI agent's Dockerfile, add:
   ```dockerfile
   RUN apt-get install -y --no-install-recommends \
         podman fuse-overlayfs slirp4netns uidmap dbus-user-session
   RUN echo "<agent-user>:100000:65536" >> /etc/subuid \
    && echo "<agent-user>:100000:65536" >> /etc/subgid
   RUN mkdir -p /run/user/<agent-uid> \
    && chown <agent-uid>:<agent-uid> /run/user/<agent-uid>
   ```
2. On each CI host, load `podman-nested.apparmor` once (golden image, Puppet, Ansible — whatever you use for provisioning). Only Ubuntu 24.04+ needs this.
3. In your Jenkinsfile agent config (or `docker.image().inside(...)` invocation), pass the six `--device` / `--cap-add` / `--security-opt` flags.
4. In the agent's entrypoint, start Podman's docker-compat socket before your test runs, and export the three Testcontainers env vars. See `entrypoint.sh` in this repo for the pattern.

## Caveats

- **cgroups v2** required. Ubuntu 22.04+, RHEL 9+, Fedora 31+.
- **Kernel ≥ 5.11** recommended.
- **AppArmor profile** only needed on Ubuntu 24.04+. Other distros can use `--security-opt apparmor=unconfined` instead.
- **`DockerComposeContainer`** needs a compose binary reachable. `podman-compose` works; Podman 4.x's built-in `podman compose` isn't 100% Docker-compose-compatible. Pin `podman-compose` if you use Compose.
- **Docker-only features** (`buildx`, multi-arch builds, `docker manifest`) aren't in Podman's compat layer. Usually irrelevant for test code.
- **Not tested** on cgroups v1, Docker daemons with `userns-remap`, or Kubernetes pod executors.

## Not claimed

- Not a security audit. `--cap-add=SYS_ADMIN` + `seccomp=unconfined` are real concessions — just orders of magnitude narrower than `--privileged`.
- Not a migration guide. `hello-world` and `postgres:16-alpine` are smaller than your real test workload.
- See [`docker-equivalent-fails.md`](./docker-equivalent-fails.md) for a deeper breakdown of what `--privileged` and socket-mount each give up.

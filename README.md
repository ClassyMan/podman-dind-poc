# podman-dind-poc

**A drop-in replacement for Docker-in-Docker inside a CI agent. No `--privileged`. No `/var/run/docker.sock` mount.**

## The problem

Your Jenkins agent (or GitLab runner, or CircleCI executor) wraps the whole test run in a Docker container. Your tests then need to spawn more containers — Testcontainers, integration-test stacks, etc. The two usual options both give up isolation:

- **`docker run --privileged`** — 38+ capabilities, seccomp off, every host device exposed, AppArmor/SELinux off. A buggy or malicious test escapes trivially.
- **`-v /var/run/docker.sock:/var/run/docker.sock`** — the inner `docker` command is a client talking to the **host's** daemon. "Inner" containers are actually the host's. One `docker run -v /:/host` from a test gives you root on the host.

## What this does

Install rootless Podman inside your Docker CI-agent image. Let Podman do the nesting. Each test-spawned container gets its own user namespace, overlay storage, and network — while the outer agent container stays inside a sharply bounded flag set.

| | Outer `CapBnd` | Seccomp | Inner isolation |
| --- | --- | --- | --- |
| `docker run --privileged` | 38+ caps (all) | **off** | weak — escape is trivial |
| `-v /var/run/docker.sock` | Docker default (14 caps) | default | **none** — "inner" containers are host's |
| **This repo** | 15 caps (default + `SYS_ADMIN`) | off | **real nested userns + overlay + netns** |

## Run it

One-time host setup (Ubuntu 24.04+ only — older distros skip this step):

```bash
sudo install -m 0644 docker-outer/apparmor-profile/podman-nested.apparmor /etc/apparmor.d/podman-nested
sudo apparmor_parser -r /etc/apparmor.d/podman-nested
```

Then run the demo (builds an Ubuntu+Podman image, runs it via Docker, runs `hello-world` nested inside):

```bash
docker-outer/run.sh
```

`test.sh` at the repo root asserts the scenario actually works (PASS banner present, `Hello from Docker!` present, `CapBnd` is not `--privileged`'s full set). Exit 0 for CI.

## The flag set

```bash
docker run --rm \
  --device /dev/fuse \                       # for fuse-overlayfs storage
  --device /dev/net/tun \                    # for slirp4netns networking
  --cap-add=SYS_ADMIN \                      # so setuid newuidmap can write uid_map
  --security-opt apparmor=podman-nested \    # Ubuntu 24.04+ userns grant (4-line profile)
  --security-opt seccomp=unconfined \        # Docker default blocks some unshare/mount
  --security-opt systempaths=unconfined \    # restore /proc + /sys visibility inside
  podman-in-docker:local
```

**Not used**: `--privileged`, `-v /var/run/docker.sock`, `--userns=host`, `--net=host`, any other `--cap-add`.

### What each flag actually concedes

- **`--device /dev/fuse`, `--device /dev/net/tun`** — two device nodes. `--privileged` exposes every device under `/dev`.
- **`--cap-add=SYS_ADMIN`** — one capability, added to the bounding set. The container still runs as UID 1000 with `CapEff=0`; only setuid binaries (`newuidmap`, `newgidmap`, `mount`) can exercise this cap, transiently.
- **`--security-opt apparmor=podman-nested`** — the profile is literally `flags=(unconfined) { userns }`. Four lines. It adds no restrictions beyond what the cap set + seccomp already enforce; it only satisfies the Ubuntu 24.04+ kernel requirement that unprivileged userns work happens under a named AppArmor profile with an explicit `userns` grant.
- **`--security-opt seccomp=unconfined`** — turns off Docker's default seccomp profile because it blocks syscalls (`unshare`, various `mount` variants) the inner runtime needs. Cap set and AppArmor still enforce.
- **`--security-opt systempaths=unconfined`** — Docker masks a handful of `/proc` and `/sys` subpaths by default; the inner runtime needs standard visibility to set up its own `/proc`. No write access is granted that wasn't already.

## What the demo verifies

`inner-demo.sh` runs eight self-checks inside the outer container, with `set -euo pipefail` — any failure bails, so the final `=== PASS ===` banner only prints if everything worked:

1. **Identity** — `whoami`, UID, userns, `uid_map`.
2. **Capability bounds** — `grep '^Cap' /proc/self/status`. Explicitly contrasted with `--privileged`'s `CapBnd=0x000001ffffffffff`.
3. **No host container socket mounted** — fails loudly if `/var/run/docker.sock` or a Podman socket is present; forces the demo to be real nesting, not fake-nesting-via-socket-share.
4. **Outer podman version**.
5. **Storage driver is overlay, rootless**.
6. **`podman ps -a` is empty** — proves the inner podman has its own graph root, not a view into the host's.
7. **Network interfaces** — shows the container has its own netns.
8. **Actual nested workload** — `podman run --rm docker.io/library/hello-world` runs and prints "Hello from Docker!".

## Wiring this into Jenkins

1. In your CI agent's Dockerfile, add `podman fuse-overlayfs slirp4netns uidmap dbus-user-session` to the apt (or equivalent) install line. Add `/etc/subuid` + `/etc/subgid` entries for the agent user (`<user>:100000:65536` is typical).
2. On each CI host, load `podman-nested.apparmor` once. Golden image, Puppet, Ansible, whatever you use for host provisioning. Only needed on Ubuntu 24.04+.
3. In the Jenkinsfile's agent config or the `docker.image().inside(...)` invocation, pass the six `--device` / `--cap-add` / `--security-opt` flags above.
4. Point Testcontainers at the agent's rootless Podman socket:
   ```
   DOCKER_HOST=unix:///run/user/1000/podman/podman.sock
   TESTCONTAINERS_RYUK_DISABLED=true
   ```
   The `docker-outer/Containerfile` in this repo already sets this up as an example.

## Caveats

- **cgroups v2** required. Standard on Ubuntu 22.04+, RHEL 9+, Fedora 31+.
- **Kernel ≥ 5.11** recommended for reliable unprivileged userns + overlay.
- **Ubuntu 24.04+** hosts need the AppArmor profile loaded. Older or non-Ubuntu hosts don't.
- Not tested on cgroups v1 hosts, Docker daemons with `userns-remap` enabled, or Kubernetes pod executors.

## Not claimed

- **Not a security audit.** `--cap-add=SYS_ADMIN` + `seccomp=unconfined` are real concessions — just orders of magnitude narrower than `--privileged`.
- **Not a migration guide.** `hello-world` is smaller than your real test workload; real pipelines have more moving parts.
- See [`docker-equivalent-fails.md`](./docker-equivalent-fails.md) for what `docker --privileged` and socket-mounting each give up in full.

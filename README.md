# podman-dind-poc

**Claim: Rootless podman can run a truly nested container with minimal flags — without `--privileged` and without mounting the host container socket.**

Two scenarios in this repo:

- **[podman-outer](./Containerfile)** (top level) — outer container is `quay.io/podman/stable` run via *host* podman. This is the purest demonstration: the nested workload runs inside a container whose process has `CapEff=0` (zero effective capabilities).
- **[docker-outer](./docker-outer/)** — outer container is a purpose-built Ubuntu + podman image run via *host* Docker. Targets Jenkins / GitLab CI setups that wrap their entire test run in a Docker agent. Slightly wider flag set than podman-outer (one extra capability: `SYS_ADMIN`) but vastly narrower than Docker-in-Docker's `--privileged`.

In both cases the outer container runs a rootless podman binary. Inside it, a second `podman run` launches an unrelated workload (`hello-world`) that goes through its own user namespace, its own overlay filesystem, its own network namespace, and its own container store.

## Why this matters: Docker's two D-in-D workarounds

Docker has no rootless, daemonless story, so "Docker-in-Docker" in practice becomes one of:

### Option A: `docker run --privileged`
- Grants ~40 Linux capabilities to the inner container.
- Disables seccomp and AppArmor/SELinux confinement.
- All host devices accessible.
- A `--privileged` container can escape via mount, device access, or kernel module load.

### Option B: `-v /var/run/docker.sock:/var/run/docker.sock`
- The inner `docker` command is a client talking to the host daemon.
- Containers launched "inside" are actually the host's containers.
- Any such container can mount host `/` — full host compromise.
- This is fake nesting: sibling containers, not nested ones.

See [docker-equivalent-fails.md](docker-equivalent-fails.md) for the full breakdown.

## Why Podman is structurally different

- **No daemon** — each `podman` invocation is a fork+exec CLI.
- **User namespaces actually nest** (up to kernel limits; see subuid/subgid).
- **fuse-overlayfs** gives overlay storage inside an unprivileged user namespace.
- **slirp4netns** (or pasta) gives per-container userspace networking — no shared iptables.

The inner container is nested, not a sibling, and no host capability is granted.

## Run it

**Scenario 1 (podman-outer):** Requires rootless podman on the host.
```bash
./run.sh
```

**Scenario 2 (docker-outer — for Jenkins-style CI):** Requires Docker on the host. On Ubuntu 24.04+ also requires loading a tiny AppArmor profile once:
```bash
# one-time (CI host setup — can be in a golden image / provisioning tool)
sudo install -m 0644 docker-outer/apparmor-profile/podman-nested.apparmor /etc/apparmor.d/podman-nested
sudo apparmor_parser -r /etc/apparmor.d/podman-nested

# then:
docker-outer/run.sh
```

Tested on Ubuntu 24.04 host with Docker 29.3 and Podman 4.9.3 inside.

## Outer-container flags

### Scenario 1 — podman-outer

| Flag | Purpose | Is this "privilege"? |
| --- | --- | --- |
| `--user podman` | Run the outer container as the `podman` user (UID 1000 in image), which has `/etc/subuid` + `/etc/subgid` entries so the inner podman gets a proper nested userns range. | No — drops privilege (UID 1000, not 0) |
| `--device /dev/fuse` | For fuse-overlayfs inside the userns. | No — exposes one device, not all of `/dev` |
| `--security-opt label=disable` | Disable SELinux label confinement. No-op on AppArmor. | No — only relevant under SELinux |
| `--security-opt unmask=ALL` | Undo podman's defence-in-depth masking of certain `/proc` and `/sys` subpaths. | No — no caps added, no host paths mounted, seccomp still active |

**Not used:** `--privileged`, `-v /var/run/docker.sock`, `--cap-add`, `--userns=host`, `--net=host`, `seccomp=unconfined`. **`CapEff=0`** inside the container — zero effective capabilities.

### Scenario 2 — docker-outer

| Flag | Purpose | Is this "privilege"? |
| --- | --- | --- |
| `--device /dev/fuse` | For fuse-overlayfs inside the inner container. | No |
| `--device /dev/net/tun` | For slirp4netns userspace networking inside the inner container. | No — single device |
| `--cap-add=SYS_ADMIN` | Docker's default cap bounding set excludes `SYS_ADMIN`, but the kernel requires it on the `uid_map` write path. Without it, setuid-root `newuidmap` cannot gain `SYS_ADMIN` transiently and nested userns setup fails. | **One cap added.** The container still runs as UID 1000 with `CapEff=0`; only setuid binaries inside (newuidmap, newgidmap) can use this transiently. |
| `--security-opt apparmor=podman-nested` | Minimal 4-line AppArmor profile (`flags=(unconfined) { userns }`). On Ubuntu 24.04+ the kernel requires an AppArmor profile with an explicit `userns` grant for unprivileged userns operations. Profile adds *zero* restrictions beyond the container's cap set and seccomp. | No |
| `--security-opt seccomp=unconfined` | Docker's default seccomp profile blocks some `unshare`/`mount` syscalls the inner runtime needs. | Yes, seccomp turned off. But AppArmor and cap set still enforce. |
| `--security-opt systempaths=unconfined` | Restores `/proc` + `/sys` view (Docker masks these by default). | No — only restores visibility, no writes |

**Not used:** `--privileged`, `-v /var/run/docker.sock`, `--userns=host`, `--net=host`.

Bounding set comparison:

| Mode | `CapBnd` | Cap count |
| --- | --- | --- |
| This PoC, podman-outer | `0x00000000800405fb` | 11 |
| This PoC, docker-outer | `0x00000000a82425fb` | 15 (Docker default 14 + `SYS_ADMIN`) |
| Docker `--privileged` | `0x000001ffffffffff` | 38+ |

The docker-outer path gives up more than the podman-outer path (`SYS_ADMIN` + `seccomp=unconfined`) — but it's what you can do *inside an existing Docker-based CI agent* without demanding a switch to podman as the CI container runtime.

## Example output

Abbreviated from an actual run on Ubuntu 24.04 / Podman 4.9.3:

```
[1] Identity — inner root is NOT host root
    whoami:  podman
    UID:     1000
    userns:  user:[4026532584]
    uid_map:    0  1000      1
                1  100000   65536               <- nested userns mapping

[2] Capability bounds — contrast with Docker --privileged (CapBnd=0x000001ffffffffff)
    CapInh:  0000000000000000
    CapPrm:  0000000000000000
    CapEff:  0000000000000000                   <- ZERO effective caps
    CapBnd:  00000000800405fb                   <- 11 caps, none dangerous
    CapAmb:  0000000000000000

[3] PASS: no docker/podman socket found

[4] podman version 4.9.4

[5] driver: overlay / cgroup: v2 / runtime: crun

[6] <empty>                                     <- inner store is separate

[7] interfaces: lo tap0                         <- own slirp4netns

[8] Hello from Docker!                          <- nested workload ran
    ...

=== PASS: nested container ran rootless, no --privileged, no socket mount ===
          (isolated userns + caps + store + net)
```

The key contrast: Docker's `--privileged` produces `CapBnd=0x000001ffffffffff` (38 caps). This PoC produces `CapEff=0x0000000000000000` (0 effective caps) and `CapBnd=0x00000000800405fb` (11 caps, none of the dangerous ones).

## Caveats

- **cgroups v2** is required. Standard on Ubuntu 22.04+, Fedora 31+.
- `/etc/subuid` and `/etc/subgid` must have an entry for your *host* user — typically `<user>:100000:65536`. The Ansible playbook that provisioned this repo's test VM adds this automatically.
- Kernel ≥ 5.11 recommended for reliable unprivileged userns overlay.
- `--user podman` is specific to the `quay.io/podman/stable` image's built-in user (it has pre-configured subuid entries). On Podman 5.x, the default mapping may work without this.
- The Containerfile configures `mirror.gcr.io` as a pull-through cache for docker.io to dodge Docker Hub's 100-pull/6h anonymous rate limit during the nested `hello-world` pull. See `registries.conf`.

## What is not claimed

- Not a security audit.
- Not a migration guide.
- Not a perf comparison.

Scope is deliberately narrow: demonstrate one specific thing.

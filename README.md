# podman-dind-poc

**Claim: Podman runs a truly nested container rootlessly, without `--privileged` and without mounting any host socket.**

This PoC backs that claim with a single script. The outer container runs a rootless podman binary. Inside it, a second `podman run` launches an unrelated workload (`hello-world`) that goes through its own user namespace, its own overlay filesystem, its own network namespace, and its own container store.

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

```bash
./run.sh
```

Requires rootless podman on the host. Tested on Ubuntu 24.04 with Podman 4.9.3.

## Outer-container flags used (and what each is for)

| Flag | Purpose | Is this "privilege"? |
| --- | --- | --- |
| `--user podman` | Run the outer container as the `podman` user (UID 1000 in image), which has `/etc/subuid` + `/etc/subgid` entries so the inner podman gets a proper nested userns range. Without this, you fall back to "rootless single mapping" and the inner runtime breaks on devpts. | No — drops privilege (runs as UID 1000, not 0, in the outer) |
| `--device /dev/fuse` | Single device node so the inner podman can use fuse-overlayfs for overlay storage inside the userns. | No — exposes one device, not the ~200 that `--privileged` exposes |
| `--security-opt label=disable` | Disable SELinux label confinement. No-op on AppArmor/Ubuntu; prevents AVC denials on RHEL/Fedora hosts. | No — only relevant under SELinux |
| `--security-opt unmask=ALL` | Undo podman's default masking of certain `/proc` and `/sys` subpaths (defence-in-depth masking). The inner runtime needs a standard `/proc`, `/sys`, and devpts view to set up its own mounts. | No — no caps added, no host paths mounted, seccomp still active |

**Not used:** `--privileged`, `-v /var/run/docker.sock`, `--cap-add`, `--userns=host`, `--net=host`, `seccomp=unconfined`.

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

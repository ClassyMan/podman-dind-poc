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

## What the output looks like

The `inner-demo.sh` script prints eight numbered sections. Abbreviated:

```
[1] Identity — inner root is NOT host root
    UID: 0
    uid_map: 0 <non-zero-base> <range>           <- userns mapping proves it
[2] Capability bounds
    CapBnd: <small hex, NOT 0x000001ffffffffff>  <- not --privileged
[3] No host container socket mounted
    PASS: no docker/podman socket found
[4] Outer podman version
    podman version 4.9.x
[5] Storage driver
    driver: overlay / rootless: true / cgroupVersion: v2
[6] Container store is empty
    <empty>                                      <- separate store
[7] Network interfaces
    tap0 / slirp4netns                           <- own network
[8] Nested workload
    Hello from Docker!
=== PASS: ... ===
```

## Caveats

- **cgroups v2** is required. Standard on Ubuntu 22.04+, Fedora 31+.
- `/etc/subuid` and `/etc/subgid` must have an entry for your user — typically `<user>:100000:65536`.
- Kernel ≥ 5.11 recommended for reliable unprivileged userns overlay.
- On SELinux hosts, `--security-opt label=disable` is needed. On AppArmor/Ubuntu it's a no-op and harmless.
- `--device /dev/fuse` is the one host-resource hook-up required. This is a single device node for use *inside the user namespace*; it grants no host capabilities. See section [2] in the demo output — `CapBnd` stays small.

## What is not claimed

- Not a security audit.
- Not a migration guide.
- Not a perf comparison.

Scope is deliberately narrow: demonstrate one specific thing.

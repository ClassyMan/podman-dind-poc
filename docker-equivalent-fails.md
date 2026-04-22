# Docker's two D-in-D paths, and what each concedes

Neither Docker option delivers what the name "Docker-in-Docker" implies (a nested, isolated container running a second container). Each sacrifices something the rootless podman nesting in this repo preserves.

## Option A — `docker run --privileged`

Running Docker inside a `--privileged` Docker container does give you a real inner Docker daemon. The cost:

| Concession | What Docker's `--privileged` grants |
| --- | --- |
| Capabilities | All ~40 caps granted to the inner container, including `CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, `CAP_MKNOD`, `CAP_SYS_RAWIO`. |
| Devices | All host devices exposed under `/dev`. |
| AppArmor / SELinux | Label/profile unconfined. |
| seccomp | Default profile disabled. |
| Mount | Container can `mount` arbitrary filesystems from the host. |
| Kernel modules | Container can load kernel modules. |

A `--privileged` container is not isolated from the host. Any workload running in it can trivially escape. From Docker's own docs: *"The --privileged flag gives all capabilities to the container, and it also lifts all the limitations enforced by the device cgroup controller."*

For a build/CI use case this is the usual choice because the alternative (Option B) is worse. But "isolation" here is a naming convention, not a security property.

## Option B — `-v /var/run/docker.sock:/var/run/docker.sock`

Bind-mounting the host's Docker daemon socket into the "inner" container makes `docker` commands work inside it. What happens next:

- The inner `docker` is a **client**, not a daemon. It talks to the **host's** dockerd.
- Containers it "runs inside" actually run on the host, as siblings of the outer container.
- The inner container *is* the outer container's namespace, but the *containers it launches* are not nested — they share the host's container store, network, and volume namespace.
- Any container launched this way can start a new container with `-v /:/host` and mount the host root. Or with `--pid=host`. Or with `--privileged`. The "inner" container has full control of the daemon.
- This is equivalent to giving the outer container root on the host.

This pattern is not nested containerization. It is "container with a backdoor to the host daemon", presented with the grammar of nesting.

## Why rootless podman avoids both

- **No daemon.** Each `podman` call is a fork+exec process. There is no socket to mount because there is no central daemon to mount to.
- **User namespaces actually nest.** The kernel supports multiple levels of userns. Rootless podman uses this directly — the outer container gets a subuid range from the host, the inner container carves further from that range.
- **fuse-overlayfs gives overlay storage in an unprivileged userns.** The kernel's native overlayfs has historically required `CAP_SYS_ADMIN` to mount; fuse-overlayfs is a userspace implementation that does not. The outer container needs exactly one device node exposed — `/dev/fuse` — to let the fuse driver work. No other host privilege is granted.
- **slirp4netns / pasta give per-container userspace networking.** No shared iptables, no conntrack leakage, no "inner container opens port 8080 and hits outer's already-bound 8080."

Taken together: the inner container in this PoC has its own user namespace, its own storage, its own network, and a capability set that does not include `CAP_SYS_ADMIN`. Compare that to `--privileged` (Option A — full caps) and socket-mount (Option B — full daemon control). Neither is equivalent.

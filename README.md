# images-kanpachi

Container image for the Kanpachi P2P sidecar that runs alongside the Project
Zomboid dedicated server.

Published as `ghcr.io/wololo-aeyoyo/kanpachi-sidecar`. Consumed by
[`cluster-kubernetes`](https://github.com/wololo-aeyoyo/cluster-kubernetes) in
`zomboid/zomboid-release.yaml`, which injects it as a native sidecar via a Flux
post-renderer.

## Releasing

The image tag comes from `VERSION`, not from the commit — the cluster pins an
exact tag, so a release is a bump to that file:

```sh
echo "0.4.0-2" > VERSION
git commit -am "release 0.4.0-2" && git push
```

Then update the pin in `cluster-kubernetes` at `zomboid/zomboid-release.yaml`.

The workflow refuses to push a tag that already exists, so a forgotten bump
fails the build instead of moving a tag the cluster has already pulled. Use the
manual `workflow_dispatch` run with `overwrite: true` to deliberately re-release.

## Runtime contract

Derived from the Deployment that consumes it:

| Requirement | Value |
| --- | --- |
| User | root (`runAsUser: 0`), `allowPrivilegeEscalation: true` |
| Capabilities | `NET_ADMIN`, `NET_RAW` |
| Device | `/dev/net/tun` (hostPath, CharDevice) |
| State (persistent) | `/var/lib/kanpachi` — `identity.key`, `api.token`, `hosted-room.json` |
| Runtime | `/run/kanpachi` — tmpfs (`emptyDir.medium: Memory`) |
| Shared | `/shared` — shared with the Zomboid container |
| Env | `ROOM_NAME` |
| Env (from `kanpachi-secret`) | `KANPACHI_SEED`, `KANPACHI_SEED_PASSWORD` |
| Arch | `linux/amd64` only (pod pins `nodeSelector: kubernetes.io/arch: amd64`) |

Secrets come from Vault via an `ExternalSecret`; nothing sensitive belongs in
this repo.

## Status

The `Dockerfile` is not written yet — the build will fail until it exists.

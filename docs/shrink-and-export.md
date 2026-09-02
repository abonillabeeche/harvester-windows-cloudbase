# Image sizing, shrinking, and exporting

## Two sizes, not one

A Harvester image has two independent sizes:

| | What it is | Set by | Seen as |
|---|---|---|---|
| **Virtual size** | the disk geometry a cloned VM boots with | the partition/disk size at build time | `.status.virtualSize` |
| **Physical size** | actual bytes stored / downloaded | how sparse the data is | `.status.size` |

A good golden image is **small in both** and grows on deploy. Cloudbase-Init's
`ExtendVolumesPlugin` (baked into this image) expands `C:` to fill the target
disk on first boot, so a small image serves any VM size.

## Fixing virtual size: build small

Our answer file creates `C:` with `<Extend>true</Extend>`, so it fills the whole
rootdisk. **The rootdisk size at build time is the image's virtual size.** The
manifests default to a **32Gi** rootdisk for this reason — plenty for a base
Windows Server, and it grows on deploy. Don't build on a 64Gi disk if you want a
32Gi image; the clean fix is to build small, not to shrink afterwards.

## Fixing physical size: drop the zeros

`qemu-img convert -O qcow2` omits runs of zeros, so a disk whose free space is
zeroed converts to a compact qcow2. `bootstrap.ps1` zeroes the free space just
before sysprep (Windows ships no `sdelete`, so it fills free space with a zero
file and deletes it). That alone gets you a small physical image via any export.

## Exporting

### Native export (simplest)

[`kubectl/export-image.yaml`](../kubectl/export-image.yaml) — a
`VirtualMachineImage` with `sourceType: export-from-volume` pointing at the
build rootdisk PVC. No conversion: the image keeps the **same virtual size** as
the source PVC. Combined with a small build disk + the zero-free-space step,
this is all most people need.

### shrink-export Job (compaction + optional virtual shrink)

Use [`../shrink-export/`](../shrink-export/) when you want to compact an
*existing* disk, or shrink its virtual size below the build-disk size. It's a
parameterized Job — give it a namespace + source PVC + target image name — that:

1. attaches the source PVC as a raw block device,
2. **`compact`** mode: `qemu-img convert -f raw -O qcow2` (drops zeros), or
   **`shrink`** mode: also `ntfsresize` `C:` to its minimum, shrink the
   partition table, and `qemu-img resize --shrink` the virtual size,
3. creates a `VirtualMachineImage` (`sourceType: upload`) and streams the qcow2
   to Harvester's upload API.

See [../shrink-export/README.md](../shrink-export/README.md) for usage.

### Choosing the storage backend (`BACKEND` / `TARGET_STORAGECLASS`)

A Harvester `VirtualMachineImage` can be stored two ways, and the Job picks
between them with the `BACKEND` env var:

| `BACKEND` | Stored as | Storage class | Upload form field |
|---|---|---|---|
| `backingimage` (default) | a Longhorn *backing image* | always Longhorn | `chunk` |
| `cdi` | a CDI-imported PVC | **`targetStorageClassName`** (any tested CSI class, or the cluster default) | `file` |

Use `backingimage` unless you specifically need the image to live on a
StorageClass other than Longhorn (for example, Longhorn is out of space, or you
standardize on a different tested StorageClass). For `cdi`, set
`TARGET_STORAGECLASS` to a **tested** StorageClass; leave it empty to use the
cluster-default class. The Job flips the multipart form field automatically
(`chunk` vs `file`) to match the backend — you don't set that yourself.

> **CDI scratch space.** CDI stages the incoming upload in a *scratch* PVC whose
> class is `CDIConfig.spec.scratchSpaceStorageClass`. When that's unset it falls
> back to the **cluster-default StorageClass** — so even a `cdi` upload targeting
> a healthy class can wedge if the *default* class is unhealthy/full. Point
> scratch at a healthy class if needed. Note that `CDIConfig` is reconciled from
> the `CDI` CR, so patch the CR, not `CDIConfig` directly:
> ```
> kubectl patch cdi cdi --type=merge \
>   -p '{"spec":{"config":{"scratchSpaceStorageClass":"<tested-class>"}}}'
> ```

> **CDI uploads are two-phase.** For `backingimage` the `?action=upload` POST
> streams the file in one shot. For `cdi`, that same POST is what *provisions*
> the DataVolume + upload pod, and the handler then waits for the upload proxy to
> be ready before it accepts bytes. If provisioning is slow the first POST can
> return **HTTP 500 "context deadline exceeded"** — the DataVolume doesn't exist
> until you POST, so you can't pre-wait for it. The Job simply **retries the
> POST** (up to 12× for `cdi`, 15s apart) until it returns 200 or the image
> reports `Imported=True`. A single POST is enough for `backingimage`.

> **`compact` vs `shrink`.** `compact` is safe and only affects physical size —
> use it as the default. `shrink` edits the partition table and truncates the
> virtual disk; it needs a clean NTFS (captured after a graceful sysprep
> `/shutdown`) and is best-effort on GPT disks. If you just want a small image,
> prefer *building on a small rootdisk* (32Gi) over post-hoc `shrink`.

## A verified run

Captured against a real Windows Server 2022 golden build (`shrink` mode,
`SLACK_MIB=1024`):

| Stage | Size |
|---|---|
| Build rootdisk (virtual, at build time) | 32 Gi |
| NTFS used / `ntfsresize` minimum | ~11.25 GB |
| NTFS resized to (min + 1 GiB slack) | ~12.3 GB |
| **Exported image — virtual size** | **12 GiB** (`.status.virtualSize` = 12853444608) |
| **Exported image — physical size** | **8.87 GiB** (`.status.size` = 9521332224) |

The whole Job (apt install of tooling → `ntfsresize` → partition-table
`resizepart` → `qemu-img convert` → `qemu-img resize --shrink` → upload →
`Imported=True`) ran in ~2.5 min for this image. The result is a 12 Gi image
that Cloudbase-Init's `ExtendVolumesPlugin` grows to any target disk on deploy.

The same image was also verified with `BACKEND=cdi` +
`TARGET_STORAGECLASS=<a tested StorageClass>`: identical physical/virtual sizes,
`Imported=True`, landed on the target class instead of Longhorn.

Re-verified on a second cluster/build: physical **9.19 GiB** (9586475008),
virtual **12.96 GiB** (12842958848), `BACKEND=cdi`, whole Job (compact + upload)
finished in **~3 min**. Numbers vary run-to-run with actual NTFS usage, but the
Job's own steps and their ordering don't.

## Why the Job talks to `harvester.harvester-system.svc:8443`

Harvester's image **upload API** is a Steve action:

```
POST /v1/harvesterhci.io.virtualmachineimages/<ns>/<name>?action=upload&size=<bytes>
```

with the file as `multipart/form-data` (form field **`chunk`** for the
`backingimage` backend, `file` for `cdi`), plus a `File-Size: <bytes>` header.

Two auth facts shape the Job:

- The externally-exposed Steve `/v1` API does **not** accept a raw Kubernetes
  ServiceAccount token — it expects a Rancher/Harvester API token. So you can't
  just use the pod's SA token against the public endpoint.
- The **in-cluster** `harvester.harvester-system.svc:8443` listener terminates
  auth upstream, so from inside the cluster the `action=upload` call needs **no
  token at all**.

The Job therefore uploads to the in-cluster service (`curl -k`, no token) and
uses the SA token only for the `kubectl` create/wait calls against the
kube-apiserver — which is why the ServiceAccount needs RBAC on
`virtualmachineimages` (`create/get/list/watch/update/...`). If your Job can't
reach the ClusterIP and must go through the Rancher VIP, supply a real Harvester
API token as a Bearer instead.

**It connects by ClusterIP, not by the DNS name.** The API's TLS listener
rejects the SNI `harvester.harvester-system.svc` with alert 112
(unrecognized_name), which OpenSSL 3 treats as fatal
(`curl: (35) ... error:0A000458:SSL routines::tlsv1 unrecognized name`). The Job
resolves the service to its ClusterIP and hits `https://<ip>:8443`: an
IP-literal host makes curl send **no** SNI (RFC 6066 forbids IP-literal SNI), so
the handshake succeeds. `-k` skips cert verification and a `Host:` header
preserves any name-based routing.

### Gotchas

- Form field name is backend-specific: **`chunk`** (backingimage) / `file`
  (cdi). A raw `application/octet-stream` body is rejected (HTTP 415).
- `size=<bytes>` query param is **required**; also send `File-Size`.
- Never set `spec.size` — size/virtualSize are detected server-side from the
  qcow2 header.
- The image must reach `Initialized=True` before the upload (the Job waits).
  Very small test files can trip a datasource-readiness race and 500 — real
  Windows images are large enough to be fine.
- The upload POST blocks for the whole transfer; the Job gives curl a long
  `--max-time`.
- Connect by **ClusterIP**, not the `*.svc` name — see the SNI note above.
- Under `set -o pipefail`, never `yes | ntfsresize`/`yes | parted`: `yes` dies
  with SIGPIPE (141) when the consumer exits and trips pipefail *after* a
  successful operation. Use `echo y` / a finite `printf`. `parted -s` also
  auto-answers "No" to the shrink prompt — drive it with
  `printf 'Yes\nYes\n' | parted ---pretend-input-tty`.

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

> **`compact` vs `shrink`.** `compact` is safe and only affects physical size —
> use it as the default. `shrink` edits the partition table and truncates the
> virtual disk; it needs a clean NTFS (captured after a graceful sysprep
> `/shutdown`) and is best-effort on GPT disks. If you just want a small image,
> prefer *building on a small rootdisk* (32Gi) over post-hoc `shrink`.

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

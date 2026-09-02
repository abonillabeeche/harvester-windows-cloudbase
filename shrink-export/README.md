# shrink-export

A parameterized Kubernetes Job that compacts (and optionally shrinks) a Windows
disk PVC and registers the result as a Harvester `VirtualMachineImage` via the
upload API. Give it a **namespace + source PVC + target image name**.

See [../docs/shrink-and-export.md](../docs/shrink-and-export.md) for the sizing
model and the upload-API details.

## Files

| File | Purpose |
|---|---|
| `entrypoint.sh` | the logic: attach block PVC → `qemu-img` compact (+ optional `ntfsresize`/truncate) → create image + upload |
| `shrink-and-upload-job.yaml` | ServiceAccount + RBAC + Job |
| `Dockerfile` | optional prebuilt tool image (for air-gapped clusters) |

## What you need

- **`kubectl` with a working kubeconfig** for the cluster (the same one you use
  for everything else). That's it for *you*.
- **No Rancher/Harvester API token, no login, no user account.** The Job uploads
  to Harvester's *in-cluster* upload service, which terminates auth upstream — so
  from inside the cluster the upload needs **no token at all**. The one bit of
  auth involved (creating/watching the image object) is handled automatically by
  the Job's own ServiceAccount + RBAC, which the manifest creates for you. You
  never paste or manage a credential.

## Preconditions

- The **source VM is Stopped** — its RWO PVC must be free to attach.
- The image was captured after a **clean sysprep `/shutdown`** (NTFS consistent).
- The Job runs **in the same namespace as the source PVC** (a pod can only mount
  PVCs from its own namespace).

## Usage — 3 steps

```bash
cd shrink-export/
NS=default            # namespace of the source PVC (the Job runs here too)
```

**1. Ship the script as a ConfigMap:**

```bash
kubectl -n "$NS" create configmap disk-shrink-script \
  --from-file=entrypoint.sh=entrypoint.sh
```

**2. Fill in the placeholders** in `shrink-and-upload-job.yaml` (set every
`namespace:` to `$NS`, then the env values):

| Field | Set to |
|---|---|
| `REPLACE_SOURCE_PVC` | your rootdisk PVC, e.g. `winbuild-rootdisk` |
| `REPLACE_IMAGE_NAME` | new image `metadata.name` |
| `REPLACE_IMAGE_DISPLAY` | new image displayName |
| `MODE` | `compact` (safe) or `shrink` (min virtual size) |
| `BACKEND` | `backingimage` (Longhorn) or `cdi` (any tested class) |
| `TARGET_STORAGECLASS` | *cdi only:* a tested StorageClass (or empty for the default) |

**3. Run it and watch:**

```bash
kubectl -n "$NS" apply -f shrink-and-upload-job.yaml
kubectl -n "$NS" logs -f job/disk-shrink
```

**Result** — the new `VirtualMachineImage` (physical / virtual size / progress):

```bash
kubectl -n "$NS" get virtualmachineimage <IMAGE_NAME> \
  -o jsonpath='{.status.size} {.status.virtualSize} {.status.progress}{"\n"}'
```

## Notes

- The default image is `debian:12-slim`; the Job installs `qemu-utils`,
  `ntfs-3g`, `parted`, `gdisk`, `kpartx`, `curl`, `util-linux` and `kubectl` at
  startup (needs egress). For **air-gapped** clusters, build and push the
  `Dockerfile` and set the Job's `image:` to it, then drop the `apt-get`/`curl`
  preamble in the Job's `args`.
- `securityContext.privileged: true` is required for `kpartx`/device-mapper in
  `shrink` mode. `compact` mode only reads the block device.
- `MODE=compact` is the safe default (physical size only). `MODE=shrink` edits
  the partition table and truncates the virtual disk — read the warning in
  [../docs/shrink-and-export.md](../docs/shrink-and-export.md).

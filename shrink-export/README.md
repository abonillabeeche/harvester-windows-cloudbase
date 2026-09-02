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

## Preconditions

- The **source VM is Stopped** — its RWO PVC must be free to attach.
- The image was captured after a **clean sysprep `/shutdown`** (NTFS consistent).
- The Job runs **in the same namespace as the source PVC** (a pod can only mount
  PVCs from its own namespace).

## Usage

```bash
cd shrink-export/
NS=default            # namespace of the source PVC (and the Job)

# 1. Ship the script as a ConfigMap
kubectl -n "$NS" create configmap disk-shrink-script \
  --from-file=entrypoint.sh=entrypoint.sh

# 2. Edit shrink-and-upload-job.yaml:
#      - set every `namespace:` to $NS
#      - REPLACE_SOURCE_PVC     -> your rootdisk PVC (e.g. winbuild-rootdisk)
#      - REPLACE_IMAGE_NAME     -> new image metadata.name
#      - REPLACE_IMAGE_DISPLAY  -> new image displayName
#      - MODE                   -> compact (safe) | shrink (min virtual size)

# 3. Run it
kubectl -n "$NS" apply -f shrink-and-upload-job.yaml
kubectl -n "$NS" logs -f job/disk-shrink

# 4. Result
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

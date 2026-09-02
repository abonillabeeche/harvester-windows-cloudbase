#!/usr/bin/env bash
# shrink-export: compact (and optionally shrink) a Windows disk PVC, then
# register the result as a Harvester VirtualMachineImage via the upload API.
#
# Runs as a Kubernetes Job inside the Harvester cluster. The source PVC is
# attached as a RAW BLOCK device at $SRC_DEV (volumeDevices). The source VM must
# be Stopped (an RWO PVC can't attach while its VM runs) and the NTFS filesystem
# must be clean — i.e. captured after a graceful sysprep /shutdown.
#
# Env (see shrink-and-upload-job.yaml):
#   SRC_DEV           block device path of the source PVC        (default /dev/src)
#   IMAGE_NAME        metadata.name for the new VirtualMachineImage
#   IMAGE_DISPLAY     spec.displayName                            (default = IMAGE_NAME)
#   IMAGE_NAMESPACE   namespace for the new image                 (default = POD namespace)
#   MODE              compact | shrink                            (default compact)
#   SLACK_MIB         free space to leave above NTFS minimum when MODE=shrink (default 1024)
#   WORK              scratch dir for the qcow2                   (default /work)
set -euo pipefail

SRC_DEV="${SRC_DEV:-/dev/src}"
MODE="${MODE:-compact}"
SLACK_MIB="${SLACK_MIB:-1024}"
WORK="${WORK:-/work}"
IMAGE_DISPLAY="${IMAGE_DISPLAY:-${IMAGE_NAME}}"
OUT="${WORK}/disk.qcow2"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Namespace for the new image = pod namespace unless overridden. (The source PVC
# must live in the Job's own namespace — a pod can only mount PVCs from there.)
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo default)}"

# Create the VirtualMachineImage (sourceType=upload) and stream the qcow2 to it.
# Backend = backingimage (the default): a single multipart POST with form field
# "chunk". We hit the harvester API service directly inside the cluster
# (harvester.harvester-system.svc:8443), which terminates auth upstream — so no
# token is needed for the upload action itself. The kubectl calls (create/wait)
# go through the kube-apiserver with the Job's ServiceAccount token (RBAC in
# rbac.yaml). See docs/shrink-and-export.md for the why.
upload_image() {
  local file="$1" size="$2"
  local ns="$IMAGE_NAMESPACE"
  local api="https://harvester.harvester-system.svc:8443"

  log "creating VirtualMachineImage ${ns}/${IMAGE_NAME} (backend=backingimage, sourceType=upload)"
  kubectl apply -f - <<EOF
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: ${IMAGE_NAME}
  namespace: ${ns}
spec:
  backend: backingimage
  displayName: "${IMAGE_DISPLAY}"
  sourceType: upload
EOF

  log "waiting for image to be Initialized (ready to receive the upload)..."
  kubectl -n "$ns" wait virtualmachineimage/"$IMAGE_NAME" \
    --for=condition=Initialized=True --timeout=180s

  log "uploading ${size} bytes ..."
  # size= query param + File-Size header are both required/expected by Harvester.
  # backend=backingimage => form field MUST be "chunk" (use "file" for cdi).
  curl -k -sS --fail-with-body --max-time 7200 -w '\nHTTP %{http_code}\n' -X POST \
    -H "File-Size: ${size}" \
    -F "chunk=@${file};type=application/octet-stream" \
    "${api}/v1/harvesterhci.io.virtualmachineimages/${ns}/${IMAGE_NAME}?action=upload&size=${size}"

  log "waiting for import to complete..."
  kubectl -n "$ns" wait virtualmachineimage/"$IMAGE_NAME" \
    --for=condition=Imported=True --timeout=1800s
}

[ -b "$SRC_DEV" ] || die "$SRC_DEV is not a block device (attach the PVC via volumeDevices)"
[ -n "${IMAGE_NAME:-}" ] || die "IMAGE_NAME is required"
mkdir -p "$WORK"

log "source device: $SRC_DEV ($(blockdev --getsize64 "$SRC_DEV") bytes)"
log "mode: $MODE"

# ---------------------------------------------------------------------------
# Optional: shrink the NTFS filesystem + partition table to the minimum.
# ---------------------------------------------------------------------------
if [ "$MODE" = "shrink" ]; then
  log "mapping partitions..."
  kpartx -av "$SRC_DEV"
  # kpartx names partitions /dev/mapper/<base>pN
  base="$(basename "$SRC_DEV")"
  # Pick the largest NTFS partition = the Windows (C:) volume.
  win_part=""; win_size=0
  for p in /dev/mapper/${base}p*; do
    [ -e "$p" ] || continue
    fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
    sz="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
    log "  partition $p type=${fstype:-?} size=$sz"
    if [ "$fstype" = "ntfs" ] && [ "$sz" -gt "$win_size" ]; then win_part="$p"; win_size="$sz"; fi
  done
  [ -n "$win_part" ] || die "no NTFS partition found to shrink"
  partnum="${win_part##*p}"
  log "windows partition: $win_part (partition #$partnum)"

  log "checking NTFS consistency..."
  ntfsfix -d "$win_part" || die "ntfsfix failed — NTFS is dirty; capture after a clean sysprep /shutdown"

  # Minimum size ntfsresize will allow, in bytes.
  min_bytes="$(ntfsresize --info --force "$win_part" \
    | awk -F'[:.]' '/You might resize at/{gsub(/[^0-9]/,"",$2); print $2}')"
  [ -n "$min_bytes" ] || die "could not determine NTFS minimum size"
  target_bytes=$(( min_bytes + SLACK_MIB * 1024 * 1024 ))
  # align target up to 1 MiB
  target_bytes=$(( (target_bytes + 1048575) / 1048576 * 1048576 ))
  log "NTFS min=${min_bytes}B, resizing filesystem to ${target_bytes}B (+${SLACK_MIB}MiB slack)"

  yes | ntfsresize --force --size "$target_bytes" "$win_part"

  # Release the partition mapping before editing the on-disk table.
  kpartx -dv "$SRC_DEV"

  log "shrinking the partition table entry #$partnum..."
  # Work directly on $SRC_DEV. parted resizepart needs an END in MiB.
  start_bytes="$(parted -sm "$SRC_DEV" unit B print | awk -F: -v n="$partnum" '$1==n{gsub(/B/,"",$2); print $2}')"
  end_bytes=$(( start_bytes + target_bytes ))
  # round the partition end up to 1 MiB
  end_mib=$(( (end_bytes + 1048575) / 1048576 ))
  log "  partition start=${start_bytes}B -> new end=${end_mib}MiB"
  parted -s "$SRC_DEV" resizepart "$partnum" "${end_mib}MiB"

  # If GPT, move the backup header next to the (now earlier) end of data.
  if parted -sm "$SRC_DEV" print | head -2 | grep -q ':gpt:'; then
    log "GPT detected — relocating backup header"
    sgdisk -e "$SRC_DEV" || log "sgdisk -e warning (continuing)"
  fi

  # New virtual disk size = end of the last partition + a little tail.
  new_disk_bytes=$(( end_mib * 1048576 + 1048576 ))
  log "target virtual disk size: ${new_disk_bytes}B"
fi

# ---------------------------------------------------------------------------
# Convert to a compact qcow2 (drops runs of zeros -> small physical size).
# ---------------------------------------------------------------------------
log "converting to compact qcow2 at $OUT ..."
qemu-img convert -p -f raw -O qcow2 "$SRC_DEV" "$OUT"

if [ "$MODE" = "shrink" ]; then
  log "shrinking qcow2 virtual size to ${new_disk_bytes}B ..."
  qemu-img resize --shrink "$OUT" "$new_disk_bytes"
fi

qemu-img info "$OUT"
UPLOAD_BYTES="$(stat -c %s "$OUT")"
log "qcow2 ready: ${UPLOAD_BYTES} bytes"

# ---------------------------------------------------------------------------
# Register + upload as a Harvester VirtualMachineImage.
# (filled in from upload-API research — see upload_image())
# ---------------------------------------------------------------------------
upload_image "$OUT" "$UPLOAD_BYTES"
log "done: VirtualMachineImage ${IMAGE_NAMESPACE:-?}/${IMAGE_NAME}"

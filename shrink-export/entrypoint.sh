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
# Where the resulting image is STORED:
#   BACKEND=backingimage  -> Longhorn backing image (Harvester's default).
#   BACKEND=cdi           -> a CDI-imported PVC; set TARGET_STORAGECLASS to land
#                            it on any tested CSI StorageClass instead of
#                            Longhorn. Leave TARGET_STORAGECLASS empty to use
#                            the cluster default StorageClass.
BACKEND="${BACKEND:-backingimage}"
TARGET_STORAGECLASS="${TARGET_STORAGECLASS:-}"
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
  # Connect to the API by ClusterIP, not by DNS name. The Harvester API
  # terminates TLS with a cert/vhost that rejects the in-cluster SNI
  # "harvester.harvester-system.svc" — the server answers the handshake with
  # TLS alert 112 (unrecognized_name), which OpenSSL 3 treats as fatal:
  #   curl: (35) ... error:0A000458:SSL routines::tlsv1 unrecognized name
  # An IP-literal host makes curl send NO SNI (RFC 6066 forbids IP SNI), so the
  # handshake completes; -k skips cert verification and we still send the proper
  # Host header so any name-based routing on the API side is satisfied.
  local svc_host="harvester.harvester-system.svc"
  local ip
  ip="$(getent hosts "$svc_host" 2>/dev/null | awk '{print $1; exit}')"
  [ -n "$ip" ] || die "could not resolve $svc_host (cluster DNS)"
  local api="https://${ip}:8443"

  # backend selects storage AND the multipart field name:
  #   backingimage -> form field "chunk" (Longhorn); ignores targetStorageClassName
  #   cdi          -> form field "file"; targetStorageClassName picks the CSI class
  local form_field target_line=""
  case "$BACKEND" in
    backingimage) form_field="chunk" ;;
    cdi)          form_field="file"
                  [ -n "$TARGET_STORAGECLASS" ] && target_line="  targetStorageClassName: ${TARGET_STORAGECLASS}" ;;
    *) die "unknown BACKEND '$BACKEND' (want backingimage|cdi)" ;;
  esac

  log "creating VirtualMachineImage ${ns}/${IMAGE_NAME} (backend=${BACKEND}, sourceType=upload${TARGET_STORAGECLASS:+, targetSC=$TARGET_STORAGECLASS})"
  kubectl apply -f - <<EOF
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: ${IMAGE_NAME}
  namespace: ${ns}
spec:
  backend: ${BACKEND}
  displayName: "${IMAGE_DISPLAY}"
  sourceType: upload
${target_line}
EOF

  log "waiting for image to be Initialized (ready to receive the upload)..."
  kubectl -n "$ns" wait virtualmachineimage/"$IMAGE_NAME" \
    --for=condition=Initialized=True --timeout=180s

  # The ?action=upload call itself is what provisions CDI's DataVolume + upload
  # pod (backend=cdi); the handler then waits for the upload proxy to be ready
  # before streaming. If provisioning is slow it can 500 with "context deadline
  # exceeded" on the FIRST attempt (the DataVolume/upload pod don't exist until
  # you call it, so you can't pre-wait). A retry once the upload pod is
  # UploadReady streams the bytes and returns 200. backingimage uploads in one
  # shot, so 1 attempt is enough there.
  # NOTE: CDI scratch space uses CDIConfig.scratchSpaceStorageClass (falls back
  # to the cluster-default class when unset) — keep it on a HEALTHY class, or the
  # scratch PVC can wedge here.
  local attempts=1
  [ "$BACKEND" = "cdi" ] && attempts=12
  local http=000
  for a in $(seq 1 "$attempts"); do
    log "uploading ${size} bytes (form field '${form_field}', attempt ${a}/${attempts}) ..."
    # size= query param + File-Size header are both required/expected by Harvester.
    http="$(curl -k -sS -o /tmp/upload.out -w '%{http_code}' --max-time 7200 -X POST \
      -H "Host: ${svc_host}:8443" \
      -H "File-Size: ${size}" \
      -F "${form_field}=@${file};type=application/octet-stream" \
      "${api}/v1/harvesterhci.io.virtualmachineimages/${ns}/${IMAGE_NAME}?action=upload&size=${size}" \
      || echo 000)"
    sed 's/^/    /' /tmp/upload.out 2>/dev/null || true; echo
    log "  HTTP ${http}"
    [ "$http" = "200" ] && break
    # If the import already reached Imported=True, we're done regardless of code.
    imp="$(kubectl -n "$ns" get virtualmachineimage "$IMAGE_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Imported")].status}' 2>/dev/null || true)"
    [ "$imp" = "True" ] && { http=200; break; }
    log "  not ready yet; retrying in 15s"
    sleep 15
  done
  [ "$http" = "200" ] || die "upload failed after ${attempts} attempt(s) (last HTTP ${http})"

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
  # kpartx names the maps after the RESOLVED device (e.g. an LVM LV becomes
  # /dev/mapper/<vg>-<lv>N), not after $SRC_DEV — so read the names it prints
  # instead of guessing. The "add map <name> ..." lines are in partition order.
  mapfile -t MAPS < <(kpartx -av "$SRC_DEV" | awk '/add map/{print "/dev/mapper/"$3}')
  # Always release the partition maps on exit, even if a later step fails.
  trap 'sync; kpartx -dv "$SRC_DEV" >/dev/null 2>&1 || true' EXIT
  udevadm settle 2>/dev/null || sleep 2
  [ "${#MAPS[@]}" -gt 0 ] || die "kpartx mapped no partitions on $SRC_DEV"
  # parted is the source of truth for partition NUMBER + geometry; its numbered
  # lines are in the same order as kpartx's maps.
  mapfile -t PLINES < <(parted -sm "$SRC_DEV" unit B print | awk -F: '/^[0-9]+:/{print $1":"$2":"$4}')

  # Pick the largest NTFS partition = the Windows (C:) volume. Detect the
  # filesystem via blkid on the mapped device (reliable), map back to parted's
  # partition number + start offset by list order.
  win_part=""; win_size=0; partnum=""; start_bytes=0
  for i in "${!PLINES[@]}"; do
    IFS=: read -r num start _size <<<"${PLINES[$i]}"
    dev="${MAPS[$i]:-}"
    [ -n "$dev" ] && [ -e "$dev" ] || continue
    fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    sz="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    log "  part#$num $dev type=${fstype:-?} size=$sz"
    if [ "$fstype" = "ntfs" ] && [ "$sz" -gt "$win_size" ]; then
      win_part="$dev"; win_size="$sz"; partnum="$num"; start_bytes="${start%B}"
    fi
  done
  [ -n "$win_part" ] || die "no NTFS partition found to shrink"
  log "windows partition: $win_part (partition #$partnum, start ${start_bytes}B)"

  log "checking NTFS consistency..."
  ntfsfix -d "$win_part" || die "ntfsfix failed — NTFS is dirty; capture after a clean sysprep /shutdown"

  # Minimum size ntfsresize will allow, in bytes. The relevant line is:
  #   "You might resize at 5179383808 bytes or 5180 MB (freeing 26629 MB)."
  min_bytes="$(ntfsresize --info --force "$win_part" \
    | grep -oP -m1 'You might resize at \K[0-9]+' || true)"
  [ -n "$min_bytes" ] || die "could not determine NTFS minimum size"
  target_bytes=$(( min_bytes + SLACK_MIB * 1024 * 1024 ))
  # align target up to 1 MiB
  target_bytes=$(( (target_bytes + 1048575) / 1048576 * 1048576 ))
  log "NTFS min=${min_bytes}B, resizing filesystem to ${target_bytes}B (+${SLACK_MIB}MiB slack)"

  # NOTE: never pipe `yes` into this under `set -o pipefail` — `yes` dies with
  # SIGPIPE (141) when ntfsresize exits, which trips pipefail and aborts the
  # script right after a *successful* resize. `echo y` writes once and exits 0.
  echo y | ntfsresize --force --size "$target_bytes" "$win_part"

  # Release the partition mapping before editing the on-disk table.
  sync
  kpartx -dv "$SRC_DEV"
  udevadm settle 2>/dev/null || sleep 2

  log "shrinking the partition table entry #$partnum..."
  # Work directly on $SRC_DEV. parted resizepart needs an END in MiB.
  # start_bytes was captured from parted above.
  end_bytes=$(( start_bytes + target_bytes ))
  # round the partition end up to 1 MiB
  end_mib=$(( (end_bytes + 1048575) / 1048576 ))
  log "  partition start=${start_bytes}B -> new end=${end_mib}MiB"
  # parted's script mode (-s) answers "No" to the "shrinking can cause data
  # loss" prompt and aborts. ---pretend-input-tty makes parted prompt so we can
  # feed "Yes" on stdin. (printf is finite, so no SIGPIPE/pipefail trap.)
  printf 'Yes\nYes\n' | parted ---pretend-input-tty "$SRC_DEV" resizepart "$partnum" "${end_mib}MiB"

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

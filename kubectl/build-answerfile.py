#!/usr/bin/env python3
"""Fold bootstrap.ps1 into Autounattend.xml to produce a SINGLE self-contained
answer file.

Why this exists
---------------
KubeVirt's `sysprep` volume mounts a Secret (or ConfigMap) as an ISO and Windows
Setup auto-detects `autounattend.xml` on it. If you drive the build from
`kubectl` or Terraform you can put *two* keys in that Secret
(`autounattend.xml` + `bootstrap.ps1`) and have FirstLogonCommands scan the CD
for the script -- that is the "two-file path".

The Harvester UI's **Windows Unattended & Sysprep** form (v1.9+) only writes a
Secret with a SINGLE key, `autounattend.xml`, and validates that it parses and
uses the `urn:schemas-microsoft-com:unattend` root namespace. There is nowhere
to attach a second file. So to run our first-boot logic through the UI we have to
embed bootstrap.ps1 *inside* the answer file.

How it works
------------
1. base64-encode bootstrap.ps1.
2. Split the base64 into <=CHUNK-char pieces (FirstLogonCommands `<CommandLine>`
   has a hard 1024-char limit -- exceed it and Windows fails the oobeSystem pass
   with "the answer file is invalid").
3. Emit FirstLogonCommands that append each chunk to a temp file with
   `cmd /c echo <chunk>>>C:\\Windows\\Temp\\bootstrap.b64`, then decode it to
   C:\\bootstrap.ps1 and run it. The decode tolerates the CRLFs `echo` inserts
   between chunks because base64 decoding ignores whitespace.

Windows version
---------------
`--windows-version` is REQUIRED and is not cosmetic. It selects the
`/IMAGE/NAME` edition string in `ImageInstall`, which must match an image name
in the ISO's `install.wim` *exactly*. Get it wrong and Setup either stops on the
"Select the operating system you want to install" screen (so the unattended run
hangs forever) or installs the wrong edition. See `docs/windows-versions.md`.

The output is written next to the inputs as
`Autounattend-selfcontained-<version>.xml`. Paste it into the UI's "Create New"
sysprep secret, or:

    kubectl create secret generic winbuild-unattend \
      --from-file=autounattend.xml=Autounattend-selfcontained-2025.xml

Usage
-----
    ./build-answerfile.py --windows-version 2025
    ./build-answerfile.py -w 2022 [Autounattend-2022.xml] [bootstrap.ps1] [-o out.xml]
    ./build-answerfile.py -w 2025 --edition 'Windows Server 2025 SERVERDATACENTER'
"""
import argparse
import base64
import os
import re
import sys
import textwrap
from xml.sax.saxutils import escape

CHUNK = 700  # base64 chars per echo; keeps each <CommandLine> well under 1024
B64 = r"C:\Windows\Temp\bootstrap.b64"
PS1 = r"C:\bootstrap.ps1"

# /IMAGE/NAME must match an image name inside the ISO's install.wim byte for
# byte. These are the Desktop Experience ("with GUI") editions, which is what
# the build expects -- Server Core has no Server Manager and a different AppX
# surface. Retail and Evaluation media use the SAME names. Override with
# --edition for Datacenter/Core. Verify against your own ISO with:
#     wiminfo /mnt/iso/sources/install.wim          # wimlib-imagex
#     dism /Get-WimInfo /WimFile:D:\sources\install.wim
EDITIONS = {
    "2022": "Windows Server 2022 SERVERSTANDARD",
    "2025": "Windows Server 2025 SERVERSTANDARD",
    "w11": "Windows 11 Pro",
}


def build_flc(ps1_bytes: bytes) -> str:
    """Return a <FirstLogonCommands> block that reconstructs and runs the PS1."""
    b64 = base64.b64encode(ps1_bytes).decode("ascii")
    chunks = textwrap.wrap(b64, CHUNK)

    cmds = []
    # order 1: start with a clean temp file
    cmds.append(f'cmd /c del /q "{B64}" 2>nul & rem init')
    # append each base64 chunk
    for c in chunks:
        cmds.append(f"cmd /c echo {c}>>{B64}")
    # decode -> PS1 (base64 decoder ignores the CRLFs echo inserted)
    cmds.append(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        f"\"[IO.File]::WriteAllBytes('{PS1}',"
        f"[Convert]::FromBase64String((Get-Content -Raw '{B64}')))\""
    )
    # run it
    cmds.append(f"powershell -NoProfile -ExecutionPolicy Bypass -File {PS1}")

    lines = ["      <FirstLogonCommands>"]
    for order, cmd in enumerate(cmds, start=1):
        too_long = len(cmd)
        if too_long >= 1024:
            sys.exit(
                f"ERROR: generated CommandLine is {too_long} chars (>=1024). "
                f"Lower CHUNK (currently {CHUNK})."
            )
        lines.append("        <SynchronousCommand wcm:action=\"add\">")
        lines.append(f"          <CommandLine>{escape(cmd)}</CommandLine>")
        lines.append(f"          <Description>winbuild step {order}</Description>")
        lines.append(f"          <Order>{order}</Order>")
        lines.append("        </SynchronousCommand>")
    lines.append("      </FirstLogonCommands>")
    return "\n".join(lines)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-w", "--windows-version", required=True,
                    choices=sorted(EDITIONS),
                    help="Windows version being installed; selects the "
                         "/IMAGE/NAME edition string (see docs/windows-versions.md)")
    ap.add_argument("--edition",
                    help="override /IMAGE/NAME, e.g. for Datacenter or Core "
                         f"(default per --windows-version: {EDITIONS})")
    ap.add_argument("autounattend", nargs="?",
                    help="default: Autounattend-<windows-version>.xml")
    ap.add_argument("bootstrap", nargs="?",
                    default=os.path.join(here, "bootstrap.ps1"))
    ap.add_argument("-o", "--output",
                    help="default: Autounattend-selfcontained-<windows-version>.xml")
    args = ap.parse_args()

    ver = args.windows_version
    edition = args.edition or EDITIONS[ver]
    if args.autounattend is None:
        args.autounattend = os.path.join(here, f"Autounattend-{ver}.xml")
    if args.output is None:
        args.output = os.path.join(here, f"Autounattend-selfcontained-{ver}.xml")

    with open(args.autounattend, "r", encoding="utf-8") as f:
        au = f.read()
    with open(args.bootstrap, "rb") as f:
        ps1 = f.read()

    # Pin the edition even when the base file already names it -- the base files
    # are per-version, but this keeps --edition working and catches a base file
    # that was copied from another version without updating ImageInstall.
    au, n = re.subn(
        r"(<Key>/IMAGE/NAME</Key>\s*<Value>)(.*?)(</Value>)",
        lambda m: m.group(1) + escape(edition) + m.group(3),
        au,
        flags=re.S,
    )
    if n != 1:
        sys.exit("ERROR: expected exactly one /IMAGE/NAME MetaData value in the "
                 f"answer file, found {n}.")

    flc = build_flc(ps1)

    # Replace the existing FirstLogonCommands block. Use a lambda replacement so
    # backslashes in the PowerShell commands are not treated as regex escapes.
    new_au, n = re.subn(
        r"      <FirstLogonCommands>.*?</FirstLogonCommands>",
        lambda _m: flc,
        au,
        flags=re.S,
    )
    if n != 1:
        sys.exit("ERROR: expected exactly one <FirstLogonCommands> block in the "
                 f"answer file, found {n}.")

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(new_au)

    longest = max(len(m) for m in re.findall(r"<CommandLine>(.*?)</CommandLine>",
                                             new_au, flags=re.S))
    print(f"wrote {args.output}")
    print(f"  bootstrap.ps1: {len(ps1)} bytes -> "
          f"{len(base64.b64encode(ps1))} base64 chars in "
          f"{len(textwrap.wrap(base64.b64encode(ps1).decode(), CHUNK))} chunks")
    print(f"  longest CommandLine: {longest} chars (limit 1024)")


if __name__ == "__main__":
    main()

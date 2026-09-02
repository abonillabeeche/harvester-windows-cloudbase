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

The output is written next to the inputs as `Autounattend-selfcontained.xml`.
Paste it into the UI's "Create New" sysprep secret, or:

    kubectl create secret generic winbuild-unattend \
      --from-file=autounattend.xml=Autounattend-selfcontained.xml

Usage
-----
    ./build-answerfile.py [Autounattend.xml] [bootstrap.ps1] [-o output.xml]
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
    ap.add_argument("autounattend", nargs="?",
                    default=os.path.join(here, "Autounattend.xml"))
    ap.add_argument("bootstrap", nargs="?",
                    default=os.path.join(here, "bootstrap.ps1"))
    ap.add_argument("-o", "--output",
                    default=os.path.join(here, "Autounattend-selfcontained.xml"))
    args = ap.parse_args()

    with open(args.autounattend, "r", encoding="utf-8") as f:
        au = f.read()
    with open(args.bootstrap, "rb") as f:
        ps1 = f.read()

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

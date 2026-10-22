# Soak waivers

A waiver lets one exact version skip criterion 5 (the soak period) and
nothing else. Signature and checksum are never waivable.

A waiver PR touches `versions.yaml` and one file here, so it needs both the
toolchain approvers and the waiver approvers (see CODEOWNERS).

```yaml
# waivers/2026-10-22-packer-1.16.1.yaml
component: packer            # product name: packer, packer-plugin-vsphere, ...
version: "1.16.1"            # must match the bump exactly, or it is ignored
cve: "CVE-2026-XXXXX"
applicability: "Not exploitable in our topology — build host has no inbound
  network path and does not process untrusted templates. Patching for register
  closure."
expires: "2026-11-22"        # YYYY-MM-DD; an expired waiver is rejected
```

Urgency is an attack vector. Manufactured CVE pressure shortens the review
window, which is exactly when a malicious release would land. Treat a waiver
as needing more attention than a routine bump, not less.

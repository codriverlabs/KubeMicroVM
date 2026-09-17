#!/usr/bin/env python3
"""
enrich-report.py — Post-process a Robot Framework output.xml to inject
documentation links into test descriptions before regenerating the HTML report.

Covers both the Community UAT suite (63 tests) and the PRO UAT suite (33 tests).
PRO test IDs are automatically recognised when present in the input.

Usage:
    # Enrich a single suite output
    python3 enrich-report.py --input output.xml --output output-enriched.xml

    # Merge multiple suite outputs first, then enrich
    python3 -m robot.rebot --output merged.xml suites/*/output.xml
    python3 enrich-report.py --input merged.xml --output enriched.xml
    python3 -m robot.rebot --outputdir report/ enriched.xml

The script appends a "Docs: <url>" line to each matched test's documentation
string. rebot renders this as a clickable link in the generated HTML report,
connecting every test result directly to its feature documentation.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# ---------------------------------------------------------------------------
# Base URL for published documentation.
# Override with --base-url for staging or custom domains.
# ---------------------------------------------------------------------------
DEFAULT_BASE_URL = "https://docs.codriverlabs.ai/kubemicrovm"

# ---------------------------------------------------------------------------
# Community test ID → (short feature description, docs path)
#
# Path is appended to BASE_URL. Anchors (#section) are supported.
# ---------------------------------------------------------------------------
COMMUNITY_DOCS = {
    # ── Quick Start ──────────────────────────────────────────────────────────
    "QS-00": ("Installer download and checksum",         "/user-guides/quick-start#install"),
    "QS-01": ("Operator running",                        "/user-guides/quick-start#operator"),
    "QS-02": ("Namespace labelled for MicroVMs",         "/user-guides/quick-start#namespace"),
    "QS-03": ("MicroVMImage created and built",          "/user-guides/quick-start#image"),
    "QS-04": ("MicroVM created and running",             "/user-guides/quick-start#run"),
    "QS-05": ("MicroVM list shows VM",                   "/user-guides/quick-start#run"),
    "QS-06": ("Token via --direct flag",                 "/user-guides/quick-start#token"),
    "QS-07": ("Curl endpoint returns OK",                "/user-guides/quick-start#call"),
    "QS-08": ("Teardown — delete VM",                   "/user-guides/quick-start#teardown"),

    # ── RBAC ────────────────────────────────────────────────────────────────
    "RBAC-01": ("ServiceAccount created",                      "/user-guides/rbac#setup"),
    "RBAC-02": ("Role with resourceNames created",             "/user-guides/rbac#role"),
    "RBAC-03": ("RoleBinding created",                         "/user-guides/rbac#rolebinding"),
    "RBAC-04": ("Auth can-i with subresource",                 "/user-guides/rbac#verify"),
    "RBAC-05": ("Authorised SA gets token via operator",       "/user-guides/rbac#token"),
    "RBAC-06": ("Authorised SA rejected for different VM",     "/user-guides/rbac#isolation"),
    "RBAC-07": ("Unauthorised SA rejected",                    "/user-guides/rbac#rejection"),
    "RBAC-08": ("Unlabelled namespace rejects MicroVM",        "/user-guides/rbac#namespace-label"),

    # ── Networking ──────────────────────────────────────────────────────────
    "NET-01": ("Internet egress connects to public internet",  "/user-guides/networking#internet"),
    "NET-02": ("Default egress has internet access",           "/user-guides/networking#default"),
    "NET-03": ("MicroVMNetwork becomes Active",                "/user-guides/networking#vpc"),
    "NET-04": ("VPC egress VM connects",                       "/user-guides/networking#vpc"),
    "NET-05": ("Network list shows connector",                 "/user-guides/networking#list"),

    # ── Pod Token Injection ──────────────────────────────────────────────────
    "INJ-01": ("Namespace has injection label",                "/user-guides/pod-token-injection#label"),
    "INJ-02": ("SA and RBAC created",                          "/user-guides/pod-token-injection#rbac"),
    "INJ-03": ("Annotated pod created",                        "/user-guides/pod-token-injection#annotation"),
    "INJ-04": ("Sidecar container injected",                   "/user-guides/pod-token-injection#sidecar"),
    "INJ-05": ("Token volume present",                         "/user-guides/pod-token-injection#volume"),
    "INJ-06": ("Token files written",                          "/user-guides/pod-token-injection#files"),
    "INJ-07": ("Auth token non-empty",                         "/user-guides/pod-token-injection#token"),
    "INJ-08": ("Token works to call MicroVM",                  "/user-guides/pod-token-injection#call"),
    "INJ-09": ("No-RBAC pod has empty token directory",        "/user-guides/pod-token-injection#no-rbac"),

    # ── ReplicaSet ───────────────────────────────────────────────────────────
    "RS-01": ("ReplicaSet creates 3 MicroVMs",                "/user-guides/replicaset#create"),
    "RS-02": ("RS list shows ReplicaSet",                     "/user-guides/replicaset#list"),
    "RS-03": ("Scale up to 5",                                "/user-guides/replicaset#scale"),
    "RS-04": ("Scale down to 2",                              "/user-guides/replicaset#scale"),
    "RS-05": ("Rolling update changes ImageRef",              "/user-guides/replicaset#rolling-update"),
    "RS-06": ("Delete ReplicaSet terminates all VMs",         "/user-guides/replicaset#delete"),

    # ── MicroVMClass ────────────────────────────────────────────────────────
    "CLASS-01": ("MicroVMClass created",                      "/user-guides/microvm-class#create"),
    "CLASS-02": ("VM inherits class values",                  "/user-guides/microvm-class#inheritance"),
    "CLASS-03": ("Spec shows all inherited values",           "/user-guides/microvm-class#inheritance"),
    "CLASS-04": ("User override takes precedence",            "/user-guides/microvm-class#override"),
    "CLASS-05": ("kubectl get lists class",                   "/user-guides/microvm-class#list"),
    "CLASS-06": ("Non-existent class rejected",               "/user-guides/microvm-class#validation"),

    # ── Drift Detection & Auto-Suspend ──────────────────────────────────────
    "DRIFT-01": ("External termination detected",             "/user-guides/drift-and-autosuspend#drift"),
    "DRIFT-02": ("Operator re-creates VM with new ID",        "/user-guides/drift-and-autosuspend#recovery"),
    "AUTO-01":  ("VM suspends after idle duration",           "/user-guides/drift-and-autosuspend#auto-suspend"),
    "AUTO-02":  ("Auto-resume on traffic",                    "/user-guides/drift-and-autosuspend#auto-resume"),
    "AUTO-03":  ("Operator does not fight idle policy",       "/user-guides/drift-and-autosuspend#no-fight"),

    # ── Memory Sizing ────────────────────────────────────────────────────────
    "MEM-01": ("Image with 4096 MiB shows correct status",   "/user-guides/memory-sizing#create"),
    "MEM-02": ("Image without memorySizeMiB defaults to 2048","/user-guides/memory-sizing#default"),
    "MEM-03": ("Invalid memorySizeMiB rejected",              "/user-guides/memory-sizing#validation"),
    "MEM-04": ("memorySizeMiB immutable on update",           "/user-guides/memory-sizing#immutability"),
    "MEM-05": ("CLI describe shows memory",                   "/user-guides/memory-sizing#cli"),
    "MEM-07": ("Run VM from 4096 MiB image",                 "/user-guides/memory-sizing#run"),

    # ── Admission & Failed State ─────────────────────────────────────────────
    "ADM-01": ("Missing idle policy rejected at admission",          "/user-guides/quick-start#idle-policy"),
    "ADM-02": ("Idle duration below minimum rejected",               "/user-guides/quick-start#idle-policy"),
    "ADM-03": ("Maximum duration above 28800 rejected",              "/user-guides/quick-start#idle-policy"),
    "ADM-04": ("ClassName bypasses inline idle policy requirement",  "/user-guides/microvm-class"),
    "ADM-05": ("Valid idle policy accepted",                         "/user-guides/quick-start"),
    "ADM-06": ("Failed creation stays in Failed state",              "/user-guides/quick-start#error-handling"),
    "ADM-07": ("Failed creation retries after spec change",          "/user-guides/quick-start#error-handling"),
    "ADM-08": ("Duplicate-named MicroVMImage rejected by webhook",   "/design/image-arn-collision-prevention"),
    "ADM-09": ("Delete blocked by running VMs emits Warning event",  "/design/image-arn-collision-prevention"),
}

# ---------------------------------------------------------------------------
# PRO test ID → (short feature description, docs path)
# ---------------------------------------------------------------------------
PRO_DOCS = {
    # ── Gateway Deploy ───────────────────────────────────────────────────────
    "GW-01": ("Create ReplicaSet pool",                f"/pro/gateway"),
    "GW-02": ("Wait for VMs to reach Running",         f"/user-guides/replicaset"),
    "GW-03": ("Create MicroVMGateway",                 f"/pro/gateway"),
    "GW-04": ("Gateway reaches Ready state",           f"/pro/gateway"),
    "GW-05": ("Gateway service endpoint exists",       f"/pro/gateway"),
    "GW-06": ("Gateway delete removes all resources",  f"/pro/gateway"),
    "GW-07": ("Gateway replicas scale via spec",       f"/pro/gateway"),
    "GW-08": ("Gateway status reflects readiness",     f"/pro/gateway"),

    # ── Multi-Tenant ─────────────────────────────────────────────────────────
    "MT-01": ("Tenant A cannot access Tenant B gateway",      "/pro/multi-tenant"),
    "MT-02": ("Tenant B cannot access Tenant A gateway",      "/pro/multi-tenant"),
    "MT-04": ("Valid SA accesses its own namespace gateway",  "/pro/multi-tenant"),
    "MT-05": ("Operator watches only labelled namespaces",    "/user-guides/rbac"),

    # ── Round-Robin ──────────────────────────────────────────────────────────
    "RR-01": ("Round-robin gateway reaches Ready",      "/pro/gateway"),
    "RR-02": ("Requests cycle through all pool VMs",    "/pro/gateway#load-balancing"),
    "RR-03": ("No session stickiness between requests", "/pro/gateway#load-balancing"),
    "RR-04": ("Token cache pre-warmed for all VMs",     "/pro/gateway"),
    "RR-05": ("X-Served-By-VM header present",          "/pro/gateway"),

    # ── Negative ─────────────────────────────────────────────────────────────
    "NEG-01":  ("Non-existent pool — gateway stays DOWN",           "/pro/gateway"),
    "NEG-02":  ("Pool scaled to zero — gateway DOWN and 503",       "/pro/gateway"),
    "NEG-03":  ("Pool deleted — gateway recovers without restart",  "/pro/gateway"),
    "NEG-04":  ("Token cache miss returns 503 not 500",             "/pro/gateway"),
    "NEG-05a": ("Missing auth header returns 401",                  "/user-guides/rbac"),
    "NEG-05b": ("Malformed bearer token returns 401",               "/user-guides/rbac"),
    "NEG-06":  ("Cross-namespace SA token rejected",                "/pro/multi-tenant"),
    "NEG-07":  ("VM fails mid-session — assignment cleared",        "/pro/gateway"),

    # ── Session Lifecycle ────────────────────────────────────────────────────
    "SL-01": ("Idle timeout triggers VM suspension",             "/user-guides/drift-and-autosuspend"),
    "SL-02": ("Access on suspended VM returns 202 Resuming",     "/pro/gateway#session-lifecycle"),
    "SL-03": ("Retry after 202 returns 200 once VM Running",     "/pro/gateway#session-lifecycle"),
    "SL-04": ("Max session duration forces release",             "/pro/gateway#session-lifecycle"),
    "SL-05": ("SuspendOnIdle=false — VM stays Running",          "/pro/gateway#session-lifecycle"),

    # ── Image Governance ─────────────────────────────────────────────────────
    "IMG-01": ("Duplicate-named MicroVMImage rejected by webhook",    "/design/image-arn-collision-prevention"),
    "IMG-02": ("Cross-namespace imageRef + Binding path unaffected",  "/pro/cross-namespace-imageref"),
    "IMG-03": ("Delete blocked by running VMs emits event",           "/design/image-arn-collision-prevention"),
}

# Unified map — PRO entries override Community if IDs collide (none currently do)
ALL_DOCS = {**COMMUNITY_DOCS, **PRO_DOCS}


def extract_test_id(test_name: str) -> str | None:
    """Extract structured test ID from name, e.g. 'MT-01 ...' → 'MT-01'."""
    parts = test_name.split()
    if not parts:
        return None
    candidate = parts[0]
    if re.match(r'^[A-Z]{2,5}-\d+[a-z]?$', candidate):
        return candidate
    return None


def enrich(input_path: str, output_path: str, base_url: str) -> tuple[int, int]:
    """
    Enrich output.xml with documentation links.
    Returns (tests_enriched, tests_skipped_no_mapping).
    """
    tree = ET.parse(input_path)
    root = tree.getroot()
    enriched = 0
    skipped = 0

    for test in root.iter("test"):
        name = test.get("name", "")
        test_id = extract_test_id(name)
        if not test_id:
            continue
        if test_id not in ALL_DOCS:
            skipped += 1
            continue

        feature_desc, path = ALL_DOCS[test_id]
        url = base_url.rstrip("/") + path

        doc_elem = test.find("doc")
        if doc_elem is None:
            doc_elem = ET.SubElement(test, "doc")
            doc_elem.text = ""

        existing = doc_elem.text or ""
        if url not in existing:
            doc_elem.text = existing.rstrip() + f"\n\nDocs: {url}"
            enriched += 1

    tree.write(output_path, encoding="unicode", xml_declaration=True)
    return enriched, skipped


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--input",    required=True,            help="Input output.xml path")
    parser.add_argument("--output",   required=True,            help="Enriched output.xml path")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="Documentation base URL")
    parser.add_argument("--verbose",  action="store_true",      help="Print per-test details")
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"ERROR: input not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    enriched, skipped = enrich(args.input, args.output, args.base_url)
    print(f"Enriched {enriched} test(s) with documentation links → {args.output}")
    if skipped:
        print(f"  {skipped} test(s) had no mapping (add to COMMUNITY_DOCS or PRO_DOCS)")


if __name__ == "__main__":
    main()

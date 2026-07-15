#!/usr/bin/env python3
"""Vendor perses/community-mixins' operator dashboards into helm/perses.

Fetches every PersesDashboard from a pinned commit of
https://github.com/perses/community-mixins (examples/dashboards/operator/**)
and rewrites each from the upstream v1alpha1 shape (dashboard body directly
under `spec:`) to v1alpha2 (body nested under `spec.config:`, plus an
`instanceSelector`) - see docs/architecture.md for why the rewrite is needed
(the operator's CRD conversion webhook is intentionally disabled in this repo,
so v1alpha1 objects are never auto-converted).

Re-run this after bumping MIXINS_COMMIT to refresh the vendored dashboards.
Requires: pip install pyyaml
"""

import json
import pathlib
import re
import urllib.request

import yaml

# YAML 1.1 (what Kubernetes' YAML parser speaks) resolves these bare words as
# bool/null rather than string - e.g. the dashboards' grid-layout `y:` keys.
# PyYAML's default dumper only quotes a string if *it* would misresolve it
# under its own (also YAML-1.1) rules, so this should already cover `y`/`n`
# grid keys - but force it explicitly so the vendored output never depends on
# that resolver behaving the same as the consumer's.
_AMBIGUOUS_SCALARS = {
    "y", "Y", "yes", "Yes", "YES", "n", "N", "no", "No", "NO",
    "true", "True", "TRUE", "false", "False", "FALSE",
    "on", "On", "ON", "off", "Off", "OFF",
    "null", "Null", "NULL", "~", "",
}


def _str_representer(dumper: yaml.Dumper, data: str):
    style = "'" if data in _AMBIGUOUS_SCALARS else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)


yaml.add_representer(str, _str_representer)

MIXINS_COMMIT = "cf419605e54868c45608cd590f47a150358da7a5"
RAW_BASE = f"https://cdn.jsdelivr.net/gh/perses/community-mixins@{MIXINS_COMMIT}/examples/dashboards/operator"

MIXINS = {
    "alertmanager": ["alertmanager-overview.yaml"],
    "blackbox-exporter": ["blackbox-overview.yaml"],
    "etcd": ["etcd-overview.yaml"],
    "istio": [
        "istio-control-plane.yaml",
        "istio-mesh.yaml",
        "istio-performance.yaml",
        "istio-service-dashboard.yaml",
        "istio-workload-dashboard.yaml",
        "istio-ztunnel-dashboard.yaml",
    ],
    "kubernetes": [
        "api-server-overview.yaml",
        "controller-manager-overview.yaml",
        "kubelet-overview.yaml",
        "kubernetes-cluster-networking-overview.yaml",
        "kubernetes-cluster-resources-overview.yaml",
        "kubernetes-multi-cluster-resources-overview.yaml",
        "kubernetes-namespace-networking-overview.yaml",
        "kubernetes-namespace-resources-overview.yaml",
        "kubernetes-node-resources-overview.yaml",
        "kubernetes-persistent-volume-overview.yaml",
        "kubernetes-pod-networking-overview.yaml",
        "kubernetes-pod-resources-overview.yaml",
        "kubernetes-workload-networking-overview.yaml",
        "kubernetes-workload-ns-networking-overview.yaml",
        "kubernetes-workload-ns-resources-overview.yaml",
        "kubernetes-workload-resources-overview.yaml",
        "proxy-overview.yaml",
        "scheduler-overview.yaml",
    ],
    "node-exporter": [
        "node-exporter-cluster-use-method.yaml",
        "node-exporter-nodes.yaml",
    ],
    "opentelemetry-collector": ["opentelemetry-collector.yaml"],
    "perses": ["perses-overview.yaml"],
    "prometheus": ["prometheus-overview.yaml", "prometheus-remote-write.yaml"],
    "tempo": ["tempo-tenant-overview.yaml", "tempo-writes-overview.yaml"],
    "thanos": [
        "thanos-compact-overview.yaml",
        "thanos-query-frontend-overview.yaml",
        "thanos-query-overview.yaml",
        "thanos-receive-overview.yaml",
        "thanos-ruler-overview.yaml",
        "thanos-store-overview.yaml",
    ],
}

# The Helm template placeholder for the instanceSelector label value. Written
# as a YAML string here and swapped in verbatim (Helm sees the {{ }} as its
# own template syntax once this file is emitted, not as literal text).
INSTANCE_SELECTOR_PLACEHOLDER = "__PERSES_INSTANCE_SELECTOR__"
NAMESPACE_PLACEHOLDER = "__RELEASE_NAMESPACE__"

# Dashboard content legitimately contains its own `{{label}}` templating
# (Perses/Grafana-style seriesNameFormat/legend placeholders, e.g.
# `{{instance}}`) - Helm's Go template engine would otherwise try to parse
# those as its own actions (and fail: e.g. `{{namespace}}` looks like a call
# to an undefined "namespace" function). Escape every such brace pair to a
# literal-printing action *before* injecting our own real `{{ .Release.* }}`
# expressions, so only our own placeholders end up as live Helm templating.
_BRACE_RE = re.compile(r"\{\{|\}\}")


def _escape_go_template_braces(text: str) -> str:
    return _BRACE_RE.sub(lambda m: "{{" + json.dumps(m.group(0)) + "}}", text)

OUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "helm" / "perses" / "templates" / "dashboards"


def convert(doc: dict) -> dict:
    assert doc["apiVersion"] == "perses.dev/v1alpha1", doc.get("apiVersion")
    assert doc["kind"] == "PersesDashboard"

    body = doc["spec"]
    doc["apiVersion"] = "perses.dev/v1alpha2"
    doc["metadata"]["namespace"] = NAMESPACE_PLACEHOLDER
    doc["spec"] = {
        "instanceSelector": {"matchLabels": {"perses-instance": INSTANCE_SELECTOR_PLACEHOLDER}},
        "config": body,
    }
    return doc


def main():
    for mixin, files in MIXINS.items():
        mixin_dir = OUT_DIR / mixin
        mixin_dir.mkdir(parents=True, exist_ok=True)
        for fname in files:
            url = f"{RAW_BASE}/{mixin}/{fname}"
            print(f"fetching {url}")
            with urllib.request.urlopen(url) as resp:
                raw = resp.read().decode("utf-8")
            doc = yaml.safe_load(raw)
            converted = convert(doc)
            out = yaml.dump(converted, sort_keys=False, default_flow_style=False, width=100)
            out = _escape_go_template_braces(out)
            out = out.replace(INSTANCE_SELECTOR_PLACEHOLDER, "{{ .Release.Name }}")
            out = out.replace(NAMESPACE_PLACEHOLDER, "{{ .Release.Namespace }}")
            header = (
                f"# Vendored from perses/community-mixins @ {MIXINS_COMMIT}\n"
                f"# https://github.com/perses/community-mixins/blob/{MIXINS_COMMIT}/examples/dashboards/operator/{mixin}/{fname}\n"
                f"# Rewritten from v1alpha1 to v1alpha2 by scripts/vendor-perses-dashboards.py - do not hand-edit.\n"
            )
            (mixin_dir / fname).write_text(header + out)
    print(f"done: wrote dashboards under {OUT_DIR}")


if __name__ == "__main__":
    main()

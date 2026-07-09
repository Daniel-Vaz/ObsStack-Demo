{{/*
Chart name / fullname helpers and the standard label set, so every object in
this chart shares one consistent set of metadata labels.
*/}}
{{- define "perses.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "perses.labels" -}}
app.kubernetes.io/name: perses
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Custom label applied in two places on the Perses CR (see templates/perses.yaml),
for two different consumers:
  - Top-level metadata.labels: what PersesGlobalDatasource/PersesDashboard
    instanceSelectors actually match against (a plain Kubernetes label
    selector over Perses objects — controllers/globaldatasources/globaldatasource_controller.go's
    r.List(ctx, &PersesList{}, opts)).
  - spec.metadata.labels: merged by the Operator onto every Deployment/Service/pod
    it generates for this instance (internal/perses/common/labels.go's
    LabelsForPerses — it preserves any caller-supplied label not already one
    of its 5 built-in keys), which is what this chart's own NodePort Service
    and ServiceMonitor select on.
Directly mirrors helm/grafana's grafana.instanceSelectorLabels, which is
likewise applied to the Grafana CR's own top-level metadata.labels.
*/}}
{{- define "perses.instanceSelectorLabels" -}}
perses-instance: {{ .Release.Name | quote }}
{{- end -}}

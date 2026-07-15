{{/*
Chart name / fullname helpers and the standard label set, so every object in
this chart shares one consistent set of metadata labels.
*/}}
{{- define "grafana.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "grafana.labels" -}}
app.kubernetes.io/name: grafana
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Label carried on the Grafana CR itself (and, via the Operator's label
inheritance, onto every Service/Deployment it generates) so that
GrafanaDatasource/GrafanaDashboard instanceSelectors - and this chart's own
ServiceMonitor - can target this one Grafana instance specifically.
*/}}
{{- define "grafana.instanceSelectorLabels" -}}
grafana-instance: {{ .Release.Name | quote }}
{{- end -}}

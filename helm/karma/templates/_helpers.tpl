{{/*
Chart name / fullname helpers and the standard label set, so every object in
this chart shares one consistent set of selector and metadata labels.
*/}}
{{- define "karma.name" -}}
karma
{{- end -}}

{{- define "karma.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "karma.labels" -}}
app.kubernetes.io/name: {{ include "karma.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "karma.selectorLabels" -}}
app.kubernetes.io/name: {{ include "karma.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

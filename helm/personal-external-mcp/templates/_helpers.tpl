{{- define "personal-external-mcp.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "personal-external-mcp.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "personal-external-mcp.labels" -}}
app.kubernetes.io/name: {{ include "personal-external-mcp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

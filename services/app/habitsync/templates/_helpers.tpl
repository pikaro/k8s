{{- define "habitsync.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "habitsync.labels" -}}
app.kubernetes.io/name: {{ include "habitsync.name" . }}
app.kubernetes.io/part-of: habitsync
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "habitsync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "habitsync.name" . }}
{{- end -}}

{{- define "habitsync.datasourceUrl" -}}
{{- printf "jdbc:postgresql://%s:%v/%s?sslmode=verify-full&sslrootcert=%s" .Values.database.host .Values.database.port .Values.database.name .Values.database.sslRootCert -}}
{{- end -}}

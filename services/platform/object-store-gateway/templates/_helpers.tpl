{{- define "object-store-gateway.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "object-store-gateway.labels" -}}
app.kubernetes.io/name: {{ include "object-store-gateway.name" . }}
app.kubernetes.io/part-of: object-storage
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "object-store-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "object-store-gateway.name" . }}
{{- end -}}

{{- define "object-store-gateway.remotePath" -}}
{{- printf "%s:%s" .Values.rsyncnet.remoteName .Values.rsyncnet.root -}}
{{- end -}}

{{- define "object-store-gateway.resticRemotePath" -}}
{{- printf "%s:%s/%s" .Values.rsyncnet.remoteName .Values.rsyncnet.root .Values.restic.root -}}
{{- end -}}

{{- define "object-store-gateway.rsyncEnv" -}}
{{- $prefix := printf "RCLONE_CONFIG_%s" (.Values.rsyncnet.remoteName | upper | replace "-" "_") -}}
- name: RCLONE_CONFIG
  value: /dev/null
- name: {{ $prefix }}_TYPE
  value: sftp
- name: {{ $prefix }}_PORT
  value: {{ .Values.rsyncnet.port | quote }}
- name: {{ $prefix }}_KEY_FILE
  value: /ssh/id_ed25519
- name: {{ $prefix }}_KNOWN_HOSTS_FILE
  value: /known-hosts/known_hosts
- name: {{ $prefix }}_SHELL_TYPE
  value: {{ .Values.rsyncnet.shellType | quote }}
- name: {{ $prefix }}_HOST
  value: {{ .Values.rsyncnet.host | quote }}
- name: {{ $prefix }}_USER
  value: {{ .Values.rsyncnet.user | quote }}
{{- end -}}

{{- define "object-store-gateway.resticSecretName" -}}
{{- printf "volsync-restic-%s" .namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "object-store-gateway.resticPasswordGeneratorName" -}}
{{- printf "%s-password" (include "object-store-gateway.resticSecretName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "object-store-gateway.resticPasswordKey" -}}
{{- printf "password_%s" (.namespace | replace "-" "_") -}}
{{- end -}}

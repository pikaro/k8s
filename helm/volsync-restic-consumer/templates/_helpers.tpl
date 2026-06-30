{{- define "volsync-restic-consumer.namespace" -}}
{{- required "namespace is required" .Values.namespace -}}
{{- end -}}

{{- define "volsync-restic-consumer.resticSecretName" -}}
{{- required "objectStore.resticSecretName is required" .Values.objectStore.resticSecretName -}}
{{- end -}}

{{- define "volsync-restic-consumer.repositoryPrefix" -}}
{{- required "restic.repositoryPrefix is required" .Values.restic.repositoryPrefix | trimAll "/" -}}
{{- end -}}

{{- define "volsync-restic-consumer.endpoint" -}}
{{- printf "rest:http://%s.%s.svc.cluster.local:%v" .Values.objectStore.serviceName .Values.objectStore.namespace .Values.objectStore.port -}}
{{- end -}}

{{- define "volsync-restic-consumer.repository" -}}
{{- $root := index . 0 -}}
{{- $backup := index . 1 -}}
{{- printf "%s/%s/%s/" (include "volsync-restic-consumer.endpoint" $root) (include "volsync-restic-consumer.repositoryPrefix" $root) $backup.name -}}
{{- end -}}

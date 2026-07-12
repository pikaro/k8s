{{- define "simple-web-service.namespace" -}}
{{- required "namespace is required" .Values.namespace -}}
{{- end -}}

{{- define "simple-web-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "simple-web-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "simple-web-service.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "simple-web-service.serviceName" -}}
{{- default (include "simple-web-service.fullname" .) .Values.serviceName -}}
{{- end -}}
{{- define "simple-web-service.deploymentName" -}}
{{- default (include "simple-web-service.fullname" .) .Values.deploymentName -}}
{{- end -}}
{{- define "simple-web-service.ingressName" -}}
{{- default (include "simple-web-service.fullname" .) .Values.ingressName -}}
{{- end -}}

{{- define "simple-web-service.image" -}}
{{- required "image.repository is required" .Values.image.repository -}}
{{- required "image.tag is required" .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

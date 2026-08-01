{{- define "simple-web-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "simple-web-service.namespace" -}}
{{- required "namespace is required" .Values.namespace -}}
{{- end -}}

{{- define "simple-web-service.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "simple-web-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "simple-web-service.name" . -}}
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
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- $tag := required "image.tag is required" .Values.image.tag -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}

{{- define "simple-web-service.rolloutTriggerChecksum" -}}
{{- $triggerName := .triggerName -}}
{{- $selector := .selector -}}
{{- $kind := required (printf "deployment.rolloutTriggers.%s.kind is required" $triggerName) $selector.kind -}}
{{- $name := required (printf "deployment.rolloutTriggers.%s.name is required" $triggerName) $selector.name -}}
{{- $matches := list -}}
{{- range $resource := .resources -}}
{{- if and (eq (dig "kind" "" $resource) $kind) (eq (dig "metadata" "name" "" $resource) $name) -}}
{{- $matches = append $matches $resource -}}
{{- end -}}
{{- end -}}
{{- if ne (len $matches) 1 -}}
{{- fail (printf "deployment.rolloutTriggers.%s must match exactly one additional resource with kind %q and name %q; matched %d" $triggerName $kind $name (len $matches)) -}}
{{- end -}}
{{- first $matches | toJson | sha256sum -}}
{{- end -}}

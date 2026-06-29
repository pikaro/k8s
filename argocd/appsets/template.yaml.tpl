apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: "${TYPE}"
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]

  syncPolicy:
    applicationsSync: create-update
    automated:
      sync: true
      prune: false
      selfHeal: true

  generators:
    - git:
        repoURL: https://github.com/pikaro/k8s.git
        revision: main
        files:
          - path: "argocd/catalog/${TYPE}/*.yaml"

  template:
    metadata:
      name: "{{ .name }}"
    spec:
      project: '{{ dig "project" "${TYPE}" . }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ dig "namespace" .name . }}'

  templatePatch: |
    {{- $name := .name }}
    {{- $sourceType := dig "sourceType" "helm" . }}
    {{- $basePath := dig "basePath" (printf "services/${TYPE}/%s" $name) . }}
    {{- $chart := dig "chart" $name . }}
    {{- $releaseName := dig "releaseName" $name . }}
    {{- $valuesFile := dig "valuesFile" (printf "services/${TYPE}/%s/values.yaml" $name) . }}
    {{- $requirementsPath := dig "requirementsPath" "" . }}
    {{- $resourcesPath := dig "resourcesPath" "" . }}
    {{- $serverSideApply := eq (dig "serverSideApply" "false" .) "true" }}
    {{- $skipDryRunOnMissingResource := eq (dig "skipDryRunOnMissingResource" "false" .) "true" }}
    spec:
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
      {{- if $serverSideApply }}
          - ServerSideApply=true
      {{- end }}
      {{- if $skipDryRunOnMissingResource }}
          - SkipDryRunOnMissingResource=true
      {{- end }}
      sources:
        {{- if eq $sourceType "kustomize" }}
        - repoURL: https://github.com/pikaro/k8s.git
          targetRevision: main
          path: {{ $basePath }}
        {{- else if eq $sourceType "helm" }}
        - repoURL: {{ .chartRepo }}
          chart: {{ $chart }}
          targetRevision: {{ .chartVersion }}
          helm:
            releaseName: {{ $releaseName }}
            valueFiles:
              - $values/{{ $valuesFile }}
        - repoURL: https://github.com/pikaro/k8s.git
          targetRevision: main
          ref: values
        {{- if $requirementsPath }}
        - repoURL: https://github.com/pikaro/k8s.git
          targetRevision: main
          path: {{ $requirementsPath }}
        {{- end }}
        {{- if $resourcesPath }}
        - repoURL: https://github.com/pikaro/k8s.git
          targetRevision: main
          path: {{ $resourcesPath }}
        {{- end }}
        {{- end }}

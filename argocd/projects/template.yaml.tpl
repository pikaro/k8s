apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: "${TYPE}"
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-20"
spec:
  description: "${TYPE} applications"
  sourceRepos:
    - "*"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "*"
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"

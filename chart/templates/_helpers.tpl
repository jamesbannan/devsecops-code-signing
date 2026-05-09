{{/*
_helpers.tpl — Named template library for the devsecops-demo umbrella chart.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "devsecops-demo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "devsecops-demo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label value.
*/}}
{{- define "devsecops-demo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "devsecops-demo.labels" -}}
helm.sh/chart: {{ include "devsecops-demo.chart" . }}
{{ include "devsecops-demo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "devsecops-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devsecops-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace helpers — returns the namespace for each component group.
These read from values so that namespaceOverride in sub-chart values
is the single source of truth.
*/}}
{{- define "devsecops-demo.pkiNamespace" -}}
{{- default "pki" .Values.stepca.namespaceOverride }}
{{- end }}

{{- define "devsecops-demo.registryNamespace" -}}
{{- default "registry" .Values.registry.namespace }}
{{- end }}

{{- define "devsecops-demo.workloadNamespace" -}}
{{- default "workload" .Values.workload.namespace }}
{{- end }}

{{- define "devsecops-demo.policyNamespace" -}}
{{- default "policy" .Values.kyverno.namespaceOverride }}
{{- end }}

{{/*
isLocal — returns true when global.environment is "local".
Used to gate insecure registry flags and NodePort service types.
*/}}
{{- define "devsecops-demo.isLocal" -}}
{{- eq .Values.global.environment "local" }}
{{- end }}

{{/*
registryInsecureFlag — emits "--allow-insecure-registry" for local environments.
Usage in templates:  {{ include "devsecops-demo.registryInsecureFlag" . }}
*/}}
{{- define "devsecops-demo.registryInsecureFlag" -}}
{{- if eq .Values.global.environment "local" -}}
--allow-insecure-registry
{{- end -}}
{{- end }}

{{/*
podmanTLSFlag — emits "--tls-verify=false" for local environments.
*/}}
{{- define "devsecops-demo.podmanTLSFlag" -}}
{{- if eq .Values.global.environment "local" -}}
--tls-verify=false
{{- end -}}
{{- end }}

{{/*
cosignImage — the pinned cosign image used in all signing/verification jobs.
*/}}
{{- define "devsecops-demo.cosignImage" -}}
{{- .Values.workload.cosign.image }}
{{- end }}

{{/*
stepCliImage — the pinned step-cli image used in signing init containers.
*/}}
{{- define "devsecops-demo.stepCliImage" -}}
{{- .Values.workload.stepCli.image }}
{{- end }}

{{/*
kubectlImage — the kubectl image used in post-install hook jobs.
*/}}
{{- define "devsecops-demo.kubectlImage" -}}
{{- .Values.workload.kubectlImage }}
{{- end }}

{{/*
registryServiceDNS — in-cluster DNS for the registry service.
Format: <service>.<namespace>.svc.cluster.local:<port>
*/}}
{{- define "devsecops-demo.registryServiceDNS" -}}
{{- printf "registry.%s.svc.cluster.local:5000" (include "devsecops-demo.registryNamespace" .) }}
{{- end }}

{{/*
demoImage — the full demo app image reference used in workload jobs.
*/}}
{{- define "devsecops-demo.demoImage" -}}
{{- printf "%s:%s" .Values.workload.demoApp.image .Values.workload.demoApp.tag }}
{{- end }}

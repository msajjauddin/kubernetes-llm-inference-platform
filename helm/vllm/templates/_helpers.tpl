{{- define "vllm.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "vllm.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "vllm.labels" -}}
{{ include "vllm.selectorLabels" . }}
app.kubernetes.io/component: inference
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "vllm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "vllm.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* PromQL label filter that picks this release's vLLM pods. */}}
{{- define "vllm.metricSelector" -}}
namespace="{{ .Release.Namespace }}",model_name="{{ .Values.model.servedName }}"
{{- end -}}

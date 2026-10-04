{{- define "litellm.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "litellm.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "litellm.commonLabels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Gateway pods. NetworkPolicies elsewhere (k8s/network) select them by these labels. */}}
{{- define "litellm.gatewaySelectorLabels" -}}
{{ include "litellm.selectorLabels" . }}
app.kubernetes.io/component: gateway
{{- end -}}

{{- define "litellm.labels" -}}
{{ include "litellm.gatewaySelectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{ include "litellm.commonLabels" . }}
{{- end -}}

{{- define "litellm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "litellm.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "litellm.postgres.fullname" -}}
{{- printf "%s-postgres" (include "litellm.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "litellm.redis.fullname" -}}
{{- printf "%s-redis" (include "litellm.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The LiteLLM config file: .Values.config (plain LiteLLM config.yaml) with the settings that come
from Secrets and from the bundled Postgres/Redis filled in as os.environ/ references.
*/}}
{{- define "litellm.config" -}}
{{- $cfg := deepCopy .Values.config -}}
{{- $general := default dict $cfg.general_settings -}}
{{- $_ := set $general "master_key" "os.environ/LITELLM_MASTER_KEY" -}}
{{- if include "litellm.hasDatabase" . -}}
{{- $_ := set $general "database_url" "os.environ/DATABASE_URL" -}}
{{- end -}}
{{- if .Values.redis.enabled -}}
{{- /* Cross-pod RPM/TPM and parallel-request counters, spend buffer, pod locks. */ -}}
{{- $_ := set $general "coordination_redis" (dict "host" "os.environ/REDIS_HOST" "port" "os.environ/REDIS_PORT" "password" "os.environ/REDIS_PASSWORD") -}}
{{- else -}}
{{- $_ := unset $general "use_redis_transaction_buffer" -}}
{{- end -}}
{{- $_ := set $cfg "general_settings" $general -}}
{{- if not .Values.metrics.requireAuth -}}
{{- $ls := default dict $cfg.litellm_settings -}}
{{- $_ := set $ls "require_auth_for_metrics_endpoint" false -}}
{{- $_ := set $cfg "litellm_settings" $ls -}}
{{- end -}}
{{- if .Values.redis.enabled -}}
{{- /* Router state (deployment cooldowns, usage-based routing) shared across pods. */ -}}
{{- $router := default dict $cfg.router_settings -}}
{{- $_ := set $router "redis_host" "os.environ/REDIS_HOST" -}}
{{- $_ := set $router "redis_port" "os.environ/REDIS_PORT" -}}
{{- $_ := set $router "redis_password" "os.environ/REDIS_PASSWORD" -}}
{{- $_ := set $cfg "router_settings" $router -}}
{{- end -}}
{{- /* Helm prints small floats like 5e-08, which YAML 1.1 (PyYAML) reads as a string: add ".0". */ -}}
{{- regexReplaceAll "(:\\s+-?[0-9]+)([eE][-+][0-9]+)" (toYaml $cfg) "${1}.0${2}" -}}
{{- end -}}

{{- define "litellm.hasDatabase" -}}
{{- if or .Values.postgres.enabled .Values.externalDatabase.existingSecret }}true{{ end -}}
{{- end -}}

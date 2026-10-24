{{/*
Expand the name of the chart.
*/}}
{{- define "agentforge.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — required by Kyverno require-helmsman-labels policy
*/}}
{{- define "agentforge.labels" -}}
app.kubernetes.io/managed-by: helmsman
app.kubernetes.io/part-of: {{ include "agentforge.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "agentforge.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agentforge.name" . }}
{{- end }}

{{/*
Gateway-specific selector labels
*/}}
{{- define "agentforge.gateway.selectorLabels" -}}
app.kubernetes.io/name: agentforge-gateway
{{- end }}

{{/*
Worker-specific selector labels
*/}}
{{- define "agentforge.worker.selectorLabels" -}}
app.kubernetes.io/name: agentforge-worker
{{- end }}

{{/*
Pod security context — required by Kyverno require-non-root policy
*/}}
{{- define "agentforge.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1001
fsGroup: 1001
{{- end }}

{{/*
Container security context — required by Kyverno disallow-privilege-escalation policy
*/}}
{{- define "agentforge.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end }}

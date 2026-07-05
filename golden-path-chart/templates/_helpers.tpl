{{/*
Full set of labels applied to every resource.
Includes Helm standard labels plus Helmsman governance labels.
*/}}
{{- define "golden-path-chart.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Values.appName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: helmsman
helmsman.dev/owning-team: {{ .Values.owningTeam }}
helmsman.dev/cost-center: {{ .Values.costCenterId | quote }}
{{- end }}

{{/*
Selector labels — used by StatefulSet.spec.selector and Service.spec.selector.
Must be stable across upgrades; never include chart version here.
*/}}
{{- define "golden-path-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.appName }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

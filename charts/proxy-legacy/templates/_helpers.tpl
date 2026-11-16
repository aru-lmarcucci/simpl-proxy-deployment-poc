{{- define "proxy.selectorLabels" -}}
app.kubernetes.io/name: proxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "proxy.labels" -}}
{{ include "proxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
{{- end }}

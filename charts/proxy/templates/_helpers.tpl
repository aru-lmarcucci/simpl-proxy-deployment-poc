{{- define "proxy.selectorLabels" -}}
app.kubernetes.io/name: proxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "proxy.labels" -}}
{{ include "proxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
{{- end }}

{{- define "proxy.secretPath" -}}
{{- .Values.rootCa.secretPath | default (printf "secret/data/proxy/%s/root-ca" .Release.Namespace) }}
{{- end }}

{{- define "proxy.initRole" -}}
{{- .Values.rootCa.init.role | default (printf "proxy-ca-init-%s" .Release.Namespace) }}
{{- end }}

{{- define "proxy.proxyRole" -}}
{{- .Values.openbao.proxyRole | default (printf "proxy-%s" .Release.Namespace) }}
{{- end }}

{{- define "proxy.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{- define "proxy.podSecurityContext" -}}
runAsUser: {{ .Values.uid }}
runAsGroup: {{ .Values.uid }}
runAsNonRoot: true
fsGroup: {{ .Values.uid }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

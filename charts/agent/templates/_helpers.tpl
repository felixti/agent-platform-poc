{{- define "agent.validate" -}}
{{- if not .Values.employee }}{{ fail "employee is required" }}{{ end -}}
{{- if not .Values.name }}{{ fail "name is required" }}{{ end -}}
{{- if not .Values.model }}{{ fail "model is required" }}{{ end -}}
{{- if and .Values.channels.msteams.enabled (or (not .Values.channels.msteams.appId) (not .Values.channels.msteams.tenantId)) }}{{ fail "channels.msteams needs appId and tenantId" }}{{ end -}}
{{- if and .Values.channels.msteams.enabled (not .Values.ingress.enabled) }}{{ fail "channels.msteams needs ingress.enabled (Teams calls a public webhook)" }}{{ end -}}
{{- if not (has .Values.brainKind (list "openclaw")) }}{{ fail (printf "brainKind %q not supported yet" .Values.brainKind) }}{{ end -}}
{{- end -}}
{{- define "agent.labels" -}}
app.kubernetes.io/part-of: agent-platform
agentplatform.io/employee: {{ .Values.employee }}
agentplatform.io/agent: {{ .Values.name }}
{{- end -}}
{{- define "agent.computerHost" -}}{{ .Values.name }}-computer{{- end -}}
{{- /* Hosts the BRAIN may reach through its egress listener (platform-derived,
       never from the agent file): one entry per enabled channel. JSON list. */}}
{{- define "agent.brainEgressAllow" -}}
{{- $allow := list }}
{{- if .Values.channels.telegram.enabled }}{{ $allow = append $allow "api.telegram.org" }}{{ end }}
{{- if .Values.channels.msteams.enabled }}
{{- $allow = concat $allow (list "login.microsoftonline.com" "login.botframework.com" "*.botframework.com" "smba.trafficmanager.net") }}
{{- end }}
{{- toJson $allow }}
{{- end -}}

{{- define "agent.publicHost" -}}{{ .Values.employee }}-{{ .Values.name }}.{{ .Values.ingress.domain }}{{- end -}}

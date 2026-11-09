{{- define "agent.validate" -}}
{{- if not .Values.employee }}{{ fail "employee is required" }}{{ end -}}
{{- if not .Values.name }}{{ fail "name is required" }}{{ end -}}
{{- if not .Values.model }}{{ fail "model is required" }}{{ end -}}
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
{{- toJson $allow }}
{{- end -}}

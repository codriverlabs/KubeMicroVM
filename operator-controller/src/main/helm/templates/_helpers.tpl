{{/*
Environment variables for the operator container.
Iterates over app.envs (declared vars) and app.extraEnvs (user-injected vars).
*/}}
{{- define "kube-microvm-operator.envVars" -}}
- name: KUBERNETES_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- range $key, $val := .Values.app.envs }}
{{- if ne (toString $val) "" }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
{{- end }}
{{- range $key, $val := .Values.extraEnvs }}
{{- if ne (toString $val) "" }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
{{- end }}
{{- end }}

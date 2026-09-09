{{- /*
Fluxer chart helpers. Resource names and the public URL derive from the
release/values so the chart installs under any release name or hostname.
*/}}

{{- define "fluxer.publicUrl" -}}
{{- printf "%s://%s" .Values.fluxer.scheme .Values.fluxer.domain -}}
{{- end -}}

{{- define "fluxer.publicPort" -}}
{{- if (eq .Values.fluxer.scheme "https") }}443{{- else }}80{{- end -}}
{{- end -}}

{{- define "fluxer.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{- define "fluxer.configmapName" -}}
{{- .Values.configmapName | default "fluxer-config" -}}
{{- end -}}

{{- define "fluxer.secretName" -}}
{{- .Values.secretName | default "fluxer-secrets" -}}
{{- end -}}

{{- define "fluxer.waitSeaweedfs" -}}
{{- if .Values.init.waitForSeaweedfs -}}
- name: wait-seaweedfs
  image: docker.io/library/busybox:1.36
  imagePullPolicy: IfNotPresent
  command:
    - /bin/sh
    - -c
    - |
      until nc -z -w 2 {{ .Values.serviceNames.seaweedfs }} 9333; do
        echo "waiting for seaweedfs master..."; sleep 3
      done
{{- end -}}
{{- end -}}

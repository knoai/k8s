{{/*
Shared environment variables for Job and CronJob containers
*/}}
{{- define "k8s-acceptance.env" -}}
- name: CLUSTER_NAME
  value: {{ .Values.clusterName | quote }}
- name: REPORT_DIR
  value: /opt/k8s-acceptance/report
{{- if .Values.report.persistence.enabled }}
- name: OUTPUT_DIR
  value: /opt/k8s-acceptance/report
{{- end }}
{{- if .Values.notification.feishu.enabled }}
- name: FEISHU_WEBHOOK_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "k8s-acceptance.secretName" . }}
      key: {{ .Values.secrets.feishuWebhookUrlKey }}
      optional: true
{{- end }}
{{- if .Values.export.s3.enabled }}
- name: REPORT_S3_ENDPOINT
  value: {{ .Values.export.s3.endpoint | quote }}
- name: REPORT_S3_BUCKET
  value: {{ .Values.export.s3.bucket | quote }}
- name: REPORT_S3_KEY_PREFIX
  value: {{ .Values.export.s3.keyPrefix | quote }}
- name: REPORT_S3_REGION
  value: {{ .Values.export.s3.region | quote }}
- name: REPORT_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "k8s-acceptance.secretName" . }}
      key: {{ .Values.secrets.s3AccessKeyKey }}
      optional: true
- name: REPORT_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "k8s-acceptance.secretName" . }}
      key: {{ .Values.secrets.s3SecretKeyKey }}
      optional: true
{{- end }}
{{- if .Values.export.http.enabled }}
- name: REPORT_HTTP_URL
  value: {{ .Values.export.http.url | quote }}
{{- end }}
{{- end }}

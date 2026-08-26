{{/*
Expand the name of the chart.
*/}}
{{- define "recipes-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.
*/}}
{{- define "recipes-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "recipes-api.labels" -}}
helm.sh/chart: {{ include "recipes-api.name" . }}
app.kubernetes.io/name: {{ include "recipes-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "recipes-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "recipes-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Init container that blocks until the CNPG Postgres read-write service is
accepting connections. Shared by the Deployment and the db-init Job so the
wait logic can't drift between the two.
*/}}
{{- define "recipes-api.waitForPostgres" -}}
- name: wait-for-postgres
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      echo "Waiting for PostgreSQL to be ready..."
      # CNPG creates a read-write service named: <cluster-name>-rw
      until nc -z -w 2 {{ .Release.Name }}-postgres-rw 5432; do
        echo "Postgres is not ready yet... sleeping 2s"
        sleep 2
      done
      echo "PostgreSQL is reachable!"
{{- end }}
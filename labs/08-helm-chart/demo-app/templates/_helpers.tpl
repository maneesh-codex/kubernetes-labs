{{/*
Expand the name of the chart.

Every generated name is truncated to 63 characters because that is the maximum
length of a DNS label, which is what Kubernetes object names must be. The
trailing `trimSuffix "-"` matters: truncating at exactly 63 can leave a dangling
hyphen, and a name ending in "-" is rejected by the API server.
*/}}
{{- define "demo-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.

Precedence: fullnameOverride wins outright. Otherwise the release name is used,
prefixed with the chart name unless the release name already contains it (so a
release called "demo-app" does not produce "demo-app-demo-app").
*/}}
{{- define "demo-app.fullname" -}}
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
Chart name and version as used by the helm.sh/chart label.

The `+` in a SemVer build-metadata suffix is illegal in a label value, so it is
replaced with `_`.
*/}}
{{- define "demo-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The image tag actually used, defaulting to the chart's appVersion.
Kept in one place so the Deployment, the version label and NOTES.txt can never
disagree about what is running.
*/}}
{{- define "demo-app.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{/*
Full image reference.
*/}}
{{- define "demo-app.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "demo-app.imageTag" .) }}
{{- end }}

{{/*
Common labels applied to every object this chart creates.

`selectorLabels` is deliberately a strict subset: label values like
app.kubernetes.io/version change on every upgrade, and a Deployment's
`spec.selector` is immutable, so putting a changing label in the selector makes
the next `helm upgrade` fail with "field is immutable".
*/}}
{{- define "demo-app.labels" -}}
helm.sh/chart: {{ include "demo-app.chart" . }}
{{ include "demo-app.selectorLabels" . }}
app.kubernetes.io/version: {{ include "demo-app.imageTag" . | quote }}
app.kubernetes.io/component: web
app.kubernetes.io/part-of: kubernetes-labs
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels. Immutable across the life of the release.
*/}}
{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "demo-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "demo-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

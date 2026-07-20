# Lab 03 — ConfigMaps and Secrets

Configuration is where most Kubernetes outages actually start. Not because the primitives are complicated — a ConfigMap is a map of strings — but because their runtime behaviour is counter-intuitive in two specific ways that bite everyone once. First, environment variables are frozen at container start and can never change without a restart, while mounted files update in place. Second, editing a ConfigMap restarts nothing at all: the Deployment controller watches the pod template, not the objects the template references, so a config change can be "applied" and have no effect whatsoever. This lab makes both behaviours visible, then shows the checksum annotation that is the standard fix. It also confronts the thing the name "Secret" oversells: base64 is encoding, not encryption.

## Objectives

- Consume one ConfigMap three ways: `envFrom`, an individual `valueFrom`, and a mounted volume.
- Observe that mounted config updates live while env vars do not, and explain why.
- Prove that editing a ConfigMap does not restart pods, then force a rollout with a `checksum/config` annotation.
- Decode a Secret with `kubectl get -o jsonpath` and `base64 -d`, and internalise what that means for your threat model.
- Mount a Secret as a file with a restrictive mode, and understand why `0400` fails under a non-root `securityContext`.
- Use `immutable: true` and articulate both the safety and the API-server-scale reasons for it.
- Supply writable scratch space with an `emptyDir` under `readOnlyRootFilesystem: true`.

## Prerequisites

- A running kind cluster named `k8s-labs` from `make cluster-up`.
- `kubectl` v1.29+, plus `base64` and `shasum` (both standard on macOS and Linux).
- The demo image `ghcr.io/maneeshm/k8s-labs-demo:1.0.0` side-loaded into the cluster, and `busybox:1.36` pullable (the inspection pod uses it — the demo image is built `FROM scratch` and has no shell).

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates namespace `lab-03-config` under the `restricted` Pod Security Standard. |
| `10-configmap-app.yaml` | Mutable ConfigMap holding both scalar keys (env vars) and file keys (`app.properties`, `proxy.conf`). |
| `11-configmap-immutable.yaml` | `demo-build-info-v1` with `immutable: true` — cannot be edited, only replaced. |
| `20-secret.yaml` | `Opaque` Secret via `stringData`, consumed as the `API_KEY` env var and as `credentials.ini`. |
| `30-deployment.yaml` | Consumes everything: `envFrom`, `valueFrom`, two mounted volumes, `emptyDir` for `/tmp`, and `checksum/config` + `checksum/secret` annotations. |
| `40-service.yaml` | ClusterIP Service so `kubectl port-forward` can reach the app. |
| `50-pod-config-reader.yaml` | A busybox pod mounting the same ConfigMap and Secret, so you can `exec` in and inspect the projected files. |

## Walkthrough

### 1. Apply everything

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f . -n lab-03-config
kubectl rollout status deployment/demo-config -n lab-03-config --timeout=120s
kubectl wait --for=condition=ready pod/config-reader -n lab-03-config --timeout=60s
```

That the `config-reader` pod reaches Ready is itself a test: its readiness probe is `test -r /etc/demo-secret/credentials.ini`, so it only passes if the Secret was projected with a mode the non-root UID can actually read.

### 2. See all three consumption styles at once

```bash
kubectl exec -n lab-03-config config-reader -- sh -c 'ls -l /etc/demo /etc/demo-secret'
kubectl exec -n lab-03-config config-reader -- cat /etc/demo/app.properties
```

Look at the ownership and modes. The files are owned `root:65532` — *not* by `runAsUser` — which is why `defaultMode: 0400` would make them unreadable and `0440` is the tightest mode that works. This is the trap documented at length in `30-deployment.yaml`.

Now the env-var side:

```bash
POD=$(kubectl get pod -n lab-03-config -l app.kubernetes.io/name=demo-config -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n lab-03-config svc/demo-config 8080:80 >/dev/null 2>&1 &
sleep 2
curl -s http://localhost:8080/api/info
```

`message` comes from `GREETING`, which arrived via `envFrom`. `api_key_set` is `true` and `api_key_fingerprint` is populated — the app confirms the Secret arrived without ever echoing it. That fingerprint-not-value pattern is worth stealing for your own health endpoints.

### 3. Prove that base64 is encoding, not encryption

```bash
kubectl get secret demo-secret -n lab-03-config -o jsonpath='{.data.API_KEY}' | base64 -d; echo
kubectl get secret demo-secret -n lab-03-config -o yaml | head -20
```

There is the credential, in plaintext, from one command. Anyone with `get secrets` RBAC in this namespace has it. Nothing was decrypted — base64 is a transport encoding for arbitrary bytes, chosen so binary values survive YAML and JSON. Note also that `kubectl describe secret` deliberately hides values while `kubectl get -o yaml` shows them; that asymmetry protects against shoulder-surfing, not against an attacker.

The practical consequences: never `kubectl get secret -o yaml` into a terminal that is being recorded, never commit a Secret manifest to Git, and assume anyone with namespace-level read has every credential in it.

### 4. Watch a mounted ConfigMap update live — with no restart

```bash
kubectl exec -n lab-03-config config-reader -- grep log.level /etc/demo/app.properties
kubectl patch configmap demo-config -n lab-03-config --type merge \
  -p '{"data":{"app.properties":"app.name=kubernetes-labs-demo\napp.tier=backend\napp.log.level=debug\napp.feature.dark-mode=true\napp.upstream.timeout=60s\napp.metrics.path=/metrics\n"}}'
```

Then wait and re-check. The kubelet syncs projected volumes on its own period (roughly a minute by default, plus cache TTL):

```bash
sleep 70
kubectl exec -n lab-03-config config-reader -- grep log.level /etc/demo/app.properties
```

The file now reads `debug`. No pod restarted; `kubectl get pods -n lab-03-config` shows the same names and `RESTARTS` still at 0. The kubelet swaps a symlink to a new atomically-written directory, so a reader never sees a half-written file.

### 5. Now prove the env var did *not* change

```bash
kubectl exec -n lab-03-config config-reader -- sh -c 'echo "reader env is irrelevant - check the app:"'
curl -s http://localhost:8080/api/info | grep -o '"message":"[^"]*"'
```

`GREETING` still holds the original value. Environment variables are written into the process image by `execve()` at container start; there is no mechanism by which the kubelet could change them in a running process. **If your app reads config from env vars, a ConfigMap edit is a no-op until something restarts the pod.** This is the single most common "I applied the config and nothing happened" bug.

### 6. Force a rollout the two supported ways

The blunt instrument:

```bash
kubectl rollout restart deployment/demo-config -n lab-03-config
kubectl rollout status deployment/demo-config -n lab-03-config
```

This bumps a `kubectl.kubernetes.io/restartedAt` annotation on the pod template — a template change, so a normal rolling update follows, respecting `maxSurge`/`maxUnavailable`. It is auditable and safe, unlike deleting pods by hand.

The declarative fix, which is what you actually want in GitOps:

```bash
shasum -a 256 10-configmap-app.yaml 20-secret.yaml
```

Paste those digests into the `checksum/config` and `checksum/secret` annotations in `30-deployment.yaml`, then `kubectl apply -f 30-deployment.yaml -n lab-03-config`. Because the annotation lives *in the pod template*, the template hash changes, a new ReplicaSet is created, and the fleet rolls automatically. Helm generates this with `sha256sum`; Kustomize solves the same problem differently, by appending a content hash to the ConfigMap's *name* via `configMapGenerator`.

### 7. Try to edit the immutable ConfigMap

```bash
kubectl patch configmap demo-build-info-v1 -n lab-03-config --type merge \
  -p '{"data":{"BUILD_VERSION":"1.0.1"}}'
```

Expected: the API server rejects it with `field is immutable`. The only path forward is delete-and-recreate, or — better — create `demo-build-info-v2` and point the pod template at it, which also triggers the rollout you wanted anyway.

### 8. Confirm the emptyDir is what makes `/tmp` writable

```bash
kubectl exec -n lab-03-config config-reader -- sh -c 'touch /tmp/ok && echo "/tmp writable"'
kubectl exec -n lab-03-config config-reader -- sh -c 'touch /etc/ok 2>&1 || true'
```

The first succeeds because `/tmp` is a `medium: Memory` emptyDir. The second fails with a read-only filesystem error, because `readOnlyRootFilesystem: true` is doing its job. Note the `sizeLimit: 16Mi` on the emptyDir — a memory-backed emptyDir counts against the pod's memory limit, and without a limit a runaway temp file can OOM-kill the pod.

Clean up the port-forward:

```bash
kill %1
```

## Verification

```bash
kubectl get secret demo-secret -n lab-03-config -o jsonpath='{.data.API_KEY}' | base64 -d; echo
```

Expected output:

```text
lab03-demo-key-not-a-real-credential
```

```bash
kubectl exec -n lab-03-config config-reader -- stat -c '%n %U:%G %a' /etc/demo-secret/credentials.ini
```

Expected output:

```text
/etc/demo-secret/credentials.ini root:65532 440
```

```bash
kubectl port-forward -n lab-03-config svc/demo-config 8080:80 >/dev/null 2>&1 &
sleep 2 && curl -s http://localhost:8080/api/info | grep -o '"api_key_set":[a-z]*' && kill %1
```

Expected output:

```text
"api_key_set":true
```

```bash
kubectl get configmap demo-build-info-v1 -n lab-03-config -o jsonpath='{.immutable}{"\n"}'
```

Expected output:

```text
true
```

```bash
kubectl get deployment demo-config -n lab-03-config \
  -o jsonpath='{.spec.template.metadata.annotations.checksum/config}{"\n"}'
```

Expected output: a 64-character hex digest matching `shasum -a 256 10-configmap-app.yaml`.

```bash
kubectl get pods -n lab-03-config -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready
```

Expected output: all pods `true`, confirming the Secret mode is readable by UID 65532.

## Cleanup

```bash
kubectl delete namespace lab-03-config --wait=true
```

## What you learned

- Environment variables are snapshotted at `execve()` and cannot change in a running container; mounted ConfigMap and Secret keys are updated in place by the kubelet within roughly a minute. Apps needing live reload must read files.
- Editing a ConfigMap or Secret triggers no rollout, because the Deployment controller diffs the pod template, not the objects it references.
- A `checksum/config` annotation on the pod template is the declarative fix; `kubectl rollout restart` is the imperative one. Kustomize's `configMapGenerator` achieves the same by hashing into the object name.
- `stringData` is a write-only convenience that saves you from hand-encoding base64 and its trailing-newline bugs.
- Base64 is encoding, not encryption. A Secret's real advantages over a ConfigMap are separate RBAC, tmpfs-backed mounts, suppression from `describe`, and a hook for etcd envelope encryption.
- Secret and ConfigMap volumes are projected as `root:<fsGroup>`, so `defaultMode: 0400` is unreadable by a non-root `runAsUser`. `0440` is the tightest mode that works.
- Mounting a secret beats injecting it as an env var: env vars leak via crash dumps, `describe pod`, child processes, and startup logging.
- `immutable: true` prevents drift and lets the kubelet stop watching the object, which reduces API server load at scale.
- `readOnlyRootFilesystem: true` requires an explicit writable volume for scratch space; cap memory-backed emptyDirs with `sizeLimit`.
- `automountServiceAccountToken: false` removes a real cluster credential from pods that never call the API server.

## Going further / production notes

- **Do not store real secrets in etcd Secrets if you can avoid it.** On EKS the strongest pattern is the **Secrets Store CSI Driver** with the AWS provider: a `SecretProviderClass` names the AWS Secrets Manager or Parameter Store entries, and the driver mounts them as tmpfs files at pod start. Secrets never become Kubernetes Secret objects at all, so `kubectl get secret` cannot leak them, and rotation is picked up on the driver's poll interval.
- **External Secrets Operator (ESO)** is the alternative, and the trade-off is worth understanding. ESO *syncs* an external secret into a real Kubernetes Secret, so anything that consumes Secrets normally (including `envFrom`) just works — at the cost of the plaintext landing in etcd. Choose the CSI driver when you want secrets out of etcd entirely; choose ESO when compatibility with existing manifests matters more.
- **IRSA / EKS Pod Identity.** Either approach needs the pod to authenticate to AWS without static credentials. IRSA annotates a ServiceAccount with `eks.amazonaws.com/role-arn` and exchanges a projected OIDC token for STS credentials; EKS Pod Identity is the newer, simpler association that avoids managing an OIDC provider per cluster. Both eliminate the long-lived IAM access key that would otherwise sit in a Secret — which is the actual win, larger than any encryption-at-rest control.
- **Enable KMS envelope encryption for etcd.** Without it, Secrets sit base64-encoded but unencrypted in etcd, and anyone with an etcd backup has them all. On EKS this is the `encryptionConfig` block on the cluster referencing a customer-managed KMS key; the API server then encrypts Secret resources with a DEK wrapped by that key. Note it encrypts data at rest only — it does nothing about RBAC-based access.
- **Lock down RBAC on secrets specifically.** `get`, `list`, and `watch` on `secrets` is equivalent to holding every credential in the namespace. Grant it by named resource (`resourceNames`) where possible, never cluster-wide, and audit it — `kubectl auth can-i --list` per service account is a good periodic check.
- **Never commit Secret manifests.** If secrets must live in Git for GitOps, encrypt them: **SOPS** with a KMS key, or **Sealed Secrets**, both of which store ciphertext that only the cluster can decrypt. Pair with a pre-commit scanner (gitleaks, trufflehog) — the failure mode is a developer bypassing the process once, not the process being wrong.
- **Rotation needs a restart story.** Rotating a value in Secrets Manager does nothing for pods that read it as an env var at startup. Either read from the mounted file on every use, or wire rotation to a rollout — Reloader is a common controller that watches ConfigMaps and Secrets and issues `rollout restart` automatically, which is the dynamic version of the checksum annotation.
- **Size limits are real.** A ConfigMap or Secret is capped at 1MiB because it must fit in a single etcd value. Large config (TLS bundles, GeoIP databases, ML model configs) belongs in S3 or a volume, fetched by an init container — not in etcd.

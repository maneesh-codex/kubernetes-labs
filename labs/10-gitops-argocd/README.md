# Lab 10 — GitOps with Argo CD

Every previous lab deployed by running a command: `kubectl apply`, `helm
upgrade`. That model has two structural problems. Nobody can tell you what is
*supposed* to be running without asking the cluster, and any change made by
hand persists silently until it causes an incident — usually months later, when
someone rebuilds the cluster from the manifests and discovers the manifests were
never the truth. GitOps inverts the flow: git holds desired state, a controller
inside the cluster continuously reconciles toward it, and drift is either
corrected automatically or reported loudly. This lab builds the app-of-apps
pattern with Argo CD, complete with an AppProject that bounds the blast radius,
sync waves, PreSync/PostSync hooks, Kustomize overlays for dev and prod, and a
hands-on demonstration of self-heal and prune actually firing.

## Objectives

- Install Argo CD and reach the UI and CLI.
- Build the app-of-apps pattern: one root Application that creates all the others.
- Constrain what an Application may do with an AppProject (`sourceRepos`, `destinations`, `clusterResourceWhitelist`).
- Order a sync with `argocd.argoproj.io/sync-wave` annotations.
- Run PreSync and PostSync hook Jobs and understand what a failure in each actually does.
- Deploy the same base to two environments with Kustomize overlays.
- Source an Application from a Helm chart instead of manifests.
- Watch `selfHeal` revert a manual change, and `prune` delete a resource removed from git.
- Use `ignoreDifferences` to stop Argo fighting other controllers.

## Prerequisites

- A running kind cluster (see `kind/` at the repo root).
- `kubectl` on your PATH; `argocd` CLI recommended (`brew install argocd`).
- The demo image loaded: `kind load docker-image ghcr.io/maneeshm/k8s-labs-demo:1.0.0 --name kubernetes-labs`
- **A fork of this repository.** Argo CD pulls from git, so it can only deploy
  what is in a repo it can reach. Fork it, then replace `repoURL` in
  `bootstrap/root-app.yaml` and in every file under `apps/`:

  ```bash
  gh repo fork maneeshm/kubernetes-labs --clone
  cd kubernetes-labs

  # macOS sed; use `sed -i` without the '' on Linux
  grep -rl 'github.com/maneeshm/kubernetes-labs' labs/10-gitops-argocd \
    | xargs sed -i '' 's|github.com/maneeshm/kubernetes-labs|github.com/YOUR-USER/kubernetes-labs|g'

  git commit -am "Point Argo CD at my fork" && git push
  ```

  Skipping this is the number one reason this lab appears not to work: Argo
  syncs the upstream repo, your local edits are never deployed, and `selfHeal`
  reverts anything you change by hand.

## Manifests in this lab

| File | Kind | Purpose |
| --- | --- | --- |
| `bootstrap/root-app.yaml` | Application | The app-of-apps root. **The only object applied by hand.** |
| `apps/00-appproject.yaml` | AppProject | Blast-radius boundary: allowed repos, destinations, cluster-scoped kinds, RBAC roles, sync windows. |
| `apps/demo-app-dev.yaml` | Application | Dev overlay → `lab-10-gitops`. `selfHeal: true`. |
| `apps/demo-app-prod.yaml` | Application | Prod overlay → `lab-10-gitops-prod`. `selfHeal: false`, with the trade-off explained inline. |
| `apps/monitoring.yaml` | Application | kube-prometheus-stack from a pinned Helm chart version. |
| `manifests/demo-app/base/kustomization.yaml` | Kustomization | Shared base; generates the ConfigMap so config changes roll pods. |
| `manifests/demo-app/base/deployment.yaml` | Deployment | Hardened pod spec, `envFrom` the generated ConfigMap. |
| `manifests/demo-app/base/service.yaml` | Service | ClusterIP, named `http` port. |
| `manifests/demo-app/base/presync-job.yaml` | Job | `PreSync` hook standing in for a schema migration. |
| `manifests/demo-app/base/postsync-job.yaml` | Job | `PostSync` smoke test that curls the live Service. |
| `manifests/demo-app/overlays/dev/kustomization.yaml` | Kustomization | 1 replica, debug logging, JSON 6902 patch. |
| `manifests/demo-app/overlays/prod/kustomization.yaml` | Kustomization | 3 replicas, warn logging, strategic-merge patch, topology spread. |
| `manifests/demo-app/overlays/prod/pdb.yaml` | PodDisruptionBudget | Prod-only resource — shows overlays adding, not just patching. |

## Walkthrough

1. **Install Argo CD.**

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

   kubectl wait --for=condition=available --timeout=300s \
     deployment --all -n argocd
   kubectl get pods -n argocd
   ```

   You should see the repo-server (clones git and renders manifests), the
   application-controller (the reconcile loop), the API server (UI and CLI),
   Redis (cache), Dex (SSO), and the notifications and ApplicationSet
   controllers. `stable` tracks the latest stable release — pin a version tag
   in production so a cluster rebuild is reproducible.

2. **Get the admin password and log in.**

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo

   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```

   Open <https://localhost:8080> (accept the self-signed certificate) and log
   in as `admin`. Then the CLI, in another terminal:

   ```bash
   ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d)
   argocd login localhost:8080 --username admin \
     --password "$ARGOCD_PASSWORD" --insecure

   argocd account update-password
   ```

   `argocd-initial-admin-secret` is a bootstrap credential. Once you have
   changed the password, delete it — it is not regenerated and serves no
   further purpose:

   ```bash
   kubectl -n argocd delete secret argocd-initial-admin-secret
   ```

3. **Apply the root Application.** This is the only `kubectl apply` in the lab.

   ```bash
   kubectl apply -f bootstrap/root-app.yaml
   ```

4. **Watch the cascade.** The root app syncs `apps/`, which creates the
   AppProject and three child Applications, each of which then syncs its own
   workloads.

   ```bash
   argocd app list
   kubectl get applications -n argocd -w
   ```

   The ordering comes from the sync waves: the AppProject is wave `-1` (it must
   exist before any Application references it), monitoring is wave `0`, dev is
   `1`, prod is `2`. Argo completes each wave — waiting for resources to become
   Healthy — before starting the next.

   ```bash
   argocd app get root
   argocd app get demo-app-dev
   ```

5. **Watch the hooks run.** Sync the dev app manually to see the full sequence:

   ```bash
   argocd app sync demo-app-dev
   kubectl get jobs -n lab-10-gitops
   kubectl logs -n lab-10-gitops job/demo-app-presync
   kubectl logs -n lab-10-gitops job/demo-app-postsync
   ```

   The order is: PreSync Job runs to completion → normal resources are applied
   by wave → everything becomes Healthy → PostSync smoke test runs.

   The two failure modes differ in an important way. A failing **PreSync**
   aborts the sync and nothing is applied, leaving the previous version running
   untouched — this is why migrations belong here. A failing **PostSync** marks
   the sync failed but does *not* roll anything back; the new version is already
   live. For automatic rollback on a failed smoke test you need Argo Rollouts
   with an analysis template, not a hook.

   Note also `hook-delete-policy: BeforeHookCreation` on both Jobs. A Job's
   `spec.template` is immutable, so without it the *second* sync fails when
   Argo tries to patch the existing Job. It is the most common way hook Jobs
   break, and it always breaks on the second run rather than the first.

6. **Compare the two environments.** Same base, different overlays:

   ```bash
   kubectl get deploy,pods,cm,pdb -n lab-10-gitops
   kubectl get deploy,pods,cm,pdb -n lab-10-gitops-prod

   # Dev: 1 replica, LOG_LEVEL=debug, no PDB
   kubectl get cm -n lab-10-gitops -o yaml | grep -E 'LOG_LEVEL|APP_TIER'
   # Prod: 3 replicas, LOG_LEVEL=warn, plus a PodDisruptionBudget
   kubectl get cm -n lab-10-gitops-prod -o yaml | grep -E 'LOG_LEVEL|APP_TIER'
   ```

   Render the overlays locally to see exactly what Argo applies — this is the
   fastest way to debug a Kustomize problem, with no cluster involved:

   ```bash
   kubectl kustomize manifests/demo-app/overlays/dev
   kubectl kustomize manifests/demo-app/overlays/prod
   ```

   Notice the ConfigMap name carries a content hash (`demo-app-config-27ch...`)
   and that the Deployment's `envFrom` references that exact hashed name. That
   is what makes a config change roll the pods: a new hash means a new
   ConfigMap name, which changes the pod template. A plain checked-in ConfigMap
   would be updated in place and the running pods would keep their old
   environment indefinitely — the same trap lab 08 avoids in Helm with a
   `checksum/config` annotation.

7. **Demonstrate self-heal.** This is the part worth doing slowly.

   ```bash
   kubectl get deploy demo-app -n lab-10-gitops
   kubectl scale deployment demo-app -n lab-10-gitops --replicas=5
   kubectl get pods -n lab-10-gitops -w
   ```

   Within seconds Argo reverts it to 1. Watch it happen from Argo's side:

   ```bash
   argocd app get demo-app-dev
   kubectl get events -n lab-10-gitops --sort-by=.lastTimestamp | tail -20
   ```

   The reconcile loop polls git every 3 minutes by default, but a *cluster*
   change is detected by watch and corrected almost immediately.

   Now try the same in prod, where `selfHeal: false`:

   ```bash
   kubectl scale deployment demo-app -n lab-10-gitops-prod --replicas=5
   argocd app get demo-app-prod
   ```

   Argo reports `OutOfSync` and does nothing. The diff is visible, but a human
   decides. That is the trade-off stated in `apps/demo-app-prod.yaml`: self-heal
   corrects drift in seconds, but it will also revert an emergency manual fix
   out from under whoever is mitigating an incident. Restore it deliberately:

   ```bash
   argocd app diff demo-app-prod
   argocd app sync demo-app-prod
   ```

8. **Demonstrate prune.** Prune is the setting that deletes things, so see it
   work before trusting it. Remove the prod PDB from git:

   ```bash
   kubectl get pdb -n lab-10-gitops-prod   # exists

   # Remove it from the overlay's resource list
   sed -i '' '/- pdb.yaml/d' manifests/demo-app/overlays/prod/kustomization.yaml
   git commit -am "Remove prod PDB" && git push

   argocd app get demo-app-prod --refresh
   argocd app sync demo-app-prod
   kubectl get pdb -n lab-10-gitops-prod   # gone
   ```

   Deleting a file deleted a live resource. That is the GitOps contract working
   as designed, and exactly why `prune: false` is set on the monitoring app —
   there, an accidental prune could remove a CRD and take every ServiceMonitor
   in the cluster with it.

   Put it back:

   ```bash
   git revert --no-edit HEAD && git push
   argocd app sync demo-app-prod --refresh
   ```

9. **Explore diff and history.**

   ```bash
   argocd app diff demo-app-dev
   argocd app history demo-app-prod
   argocd app rollback demo-app-prod <REVISION-ID>
   argocd app manifests demo-app-dev     # exactly what Argo renders
   ```

   Each history entry records the git SHA that produced it, which makes this an
   audit log of every change the environment has ever seen.

10. **Test the AppProject boundary.** The restrictions are only real if you
    verify them. Try to deploy to a namespace the project does not allow:

    ```bash
    argocd app create rogue \
      --repo https://github.com/maneeshm/kubernetes-labs.git \
      --path labs/10-gitops-argocd/manifests/demo-app/overlays/dev \
      --dest-server https://kubernetes.default.svc \
      --dest-namespace kube-system \
      --project kubernetes-labs
    ```

    This is rejected: `kube-system` is not in the project's `destinations`.
    Without an AppProject — that is, using `default` — it would have been
    applied without complaint. The same boundary blocks unlisted `sourceRepos`
    and cluster-scoped kinds outside `clusterResourceWhitelist`.

## Verification

```bash
# All Applications Synced and Healthy
argocd app list
kubectl get applications -n argocd

# The project exists with its restrictions
kubectl get appproject kubernetes-labs -n argocd -o yaml \
  | grep -A8 'sourceRepos\|destinations'

# Workloads are running in both environments
kubectl get deploy,svc,cm -n lab-10-gitops
kubectl get deploy,svc,cm,pdb -n lab-10-gitops-prod

# Dev has 1 replica, prod has 3
kubectl get deploy demo-app -n lab-10-gitops -o jsonpath='{.spec.replicas}'; echo
kubectl get deploy demo-app -n lab-10-gitops-prod -o jsonpath='{.spec.replicas}'; echo

# The overlays produced different config
kubectl get cm -n lab-10-gitops -o jsonpath='{.items[0].data.LOG_LEVEL}'; echo      # debug
kubectl get cm -n lab-10-gitops-prod -o jsonpath='{.items[0].data.LOG_LEVEL}'; echo # warn

# Hooks completed
kubectl get jobs -n lab-10-gitops

# Self-heal is armed on dev, off on prod
kubectl get application demo-app-dev -n argocd \
  -o jsonpath='{.spec.syncPolicy.automated.selfHeal}'; echo   # true
kubectl get application demo-app-prod -n argocd \
  -o jsonpath='{.spec.syncPolicy.automated.selfHeal}'; echo   # false

# The app actually serves
kubectl port-forward -n lab-10-gitops svc/demo-app 8080:8080 &
curl -s localhost:8080/api/info | jq
kill %1

# Overlays render cleanly without a cluster
kubectl kustomize manifests/demo-app/overlays/dev  > /dev/null && echo "dev OK"
kubectl kustomize manifests/demo-app/overlays/prod > /dev/null && echo "prod OK"
```

## Cleanup

```bash
# Deleting the root cascades to every child Application and their workloads,
# because of the resources-finalizer on each one.
kubectl delete -f bootstrap/root-app.yaml

# Watch the cascade finish before removing Argo CD itself. Deleting Argo while
# finalizers are pending leaves Applications stuck terminating forever, since
# nothing remains to process the finalizer.
kubectl get applications -n argocd -w

kubectl delete namespace lab-10-gitops lab-10-gitops-prod monitoring \
  --ignore-not-found

kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

If an Application does hang in `Terminating`, the escape hatch is to strip the
finalizer — accepting that it orphans whatever the app created:

```bash
kubectl patch application <name> -n argocd \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

## What you learned

- The app-of-apps pattern makes "what runs in this cluster" a reviewable file in git rather than tribal knowledge.
- `resources-finalizer.argocd.argoproj.io` is what makes deletion cascade; without it, deleting an Application orphans everything it created.
- AppProjects bound the blast radius — allowed repos, destinations and cluster-scoped kinds — and `default` bounds nothing.
- Sync waves order what kind-ordering cannot express; the AppProject at wave `-1` must exist before any Application referencing it.
- A failing PreSync aborts the sync; a failing PostSync does not roll anything back.
- `hook-delete-policy: BeforeHookCreation` is mandatory for hook Jobs, and its absence breaks the *second* sync, not the first.
- Kustomize `configMapGenerator` hashes solve the same problem as Helm's `checksum/config` annotation.
- Separate environments by namespace rather than `namePrefix` when manifests reference Services by name — a prefix renames objects but not hostnames in container args.
- `selfHeal` is a genuine trade-off, not a best practice: it fixes drift in seconds and reverts emergency fixes just as fast.
- `ignoreDifferences` stops Argo fighting HPAs, webhooks and defaulting controllers in a loop that never converges.

## Going further — production notes

**Argo CD on EKS, in HA mode.** The `install.yaml` used here is the
non-HA manifest: one replica of everything, and Redis as a single point of
failure whose loss makes every application show `Unknown` until it recovers.
Production wants `ha/install.yaml` — three Redis replicas with HAProxy, two API
servers, and a sharded application-controller. The controller is the component
that runs out of headroom first; shard it with `ARGOCD_CONTROLLER_REPLICAS` once
you pass roughly a thousand applications or several remote clusters. Run it in
its own node group: an Argo CD that cannot schedule is an Argo CD that cannot
fix the cluster, which is precisely when you need it most.

**SSO via OIDC and IAM Identity Center.** The `admin` account should be
disabled (`admin.enabled: false` in `argocd-cm`) once SSO works. Point the OIDC
config at IAM Identity Center, then map groups to the AppProject roles defined
in `apps/00-appproject.yaml` through `argocd-rbac-cm`:

```yaml
policy.csv: |
  g, kubernetes-labs:platform, proj:kubernetes-labs:admin
  g, kubernetes-labs:developers, proj:kubernetes-labs:developer
policy.default: role:readonly
```

`policy.default: role:readonly` matters more than the group mappings: without
it the default is no access at all, and people work around that by sharing the
admin account, which destroys the audit trail you installed SSO to get.

**ApplicationSets replace hand-written Applications.** Three Application files
is fine; thirty environments across five clusters is not. An ApplicationSet
generates Applications from a generator — a `git` generator that creates one per
directory under `overlays/`, a `cluster` generator that fans an app out across
every registered cluster, or a `matrix` combining both. The `pullRequest`
generator is the standout: it spins up an ephemeral preview environment per open
PR and tears it down on merge. Migrating this lab would mean deleting
`demo-app-dev.yaml` and `demo-app-prod.yaml` and replacing them with one
ApplicationSet whose git generator discovers the overlay directories.

**Secrets in GitOps.** Plaintext secrets cannot go in git, so pick one of two
models. **Sealed Secrets** encrypts with a controller-held key so the
ciphertext is safe to commit — simple, fully git-native, but the controller's
keypair becomes a disaster-recovery obligation, and losing it means every
sealed secret in every repo is unrecoverable. **External Secrets Operator** is
the better default on EKS: git holds only an `ExternalSecret` *reference*, and
ESO materialises the value from AWS Secrets Manager or Parameter Store using an
IRSA-annotated ServiceAccount. Rotation happens in AWS with no commit, secrets
never touch git in any form, and access is auditable through CloudTrail. The
trade-off is that the cluster is no longer reconstructible from git alone.

**Image updates without a human.** Argo CD Image Updater watches a registry and
commits an updated image tag back to git — write-back is the important part,
because updating the live cluster without updating git creates permanent drift
that self-heal then fights. Constrain it with a semver policy
(`~1.0` for patches only) so a new major version cannot ship itself. For most
teams the better pattern is having CI commit the digest as part of the build
pipeline: same outcome, one fewer controller with write access to the repo.

**Drift detection as a signal, not just a fix.** Even with `selfHeal: false`,
`OutOfSync` is valuable telemetry. Argo CD exports Prometheus metrics —
`argocd_app_info` carries a `sync_status` label — so alert on applications that
have been OutOfSync for more than fifteen minutes. Repeated drift in one app is
usually a symptom worth investigating: a missing `ignoreDifferences` rule, a
mutating webhook nobody documented, or a team still deploying by hand.

**Repository structure.** Keep application *source* and application *config* in
separate repositories. Sharing one repo means every CI image bump commits to the
repo Argo watches, so `targetRevision: main` redeploys on commits that changed
nothing deployable, and the git history becomes useless as a deployment log.
Separating them also lets the config repo have different reviewers and stricter
branch protection than the code repo — which is what you want, since it is the
config repo that has cluster-admin by proxy. Infrastructure (Terraform for VPC,
EKS, IAM) belongs in a third repo entirely; Argo CD reconciles Kubernetes
objects, not AWS resources, and blurring that boundary produces circular
dependencies at bootstrap time.

**Progressive delivery with Argo Rollouts.** The `PostSync` smoke test in this
lab detects a bad deploy *after* it is fully live. Argo Rollouts replaces the
Deployment with a `Rollout` resource supporting canary and blue-green
strategies, shifting a percentage of traffic and running AnalysisTemplates
against Prometheus between steps — querying the very metrics lab 09 exposes. If
`demo_app_http_requests_total{status=~"5.."}` climbs during the canary, the
rollout aborts and reverts automatically, having exposed the fault to 5% of
traffic instead of everyone. That is the capability a PostSync hook structurally
cannot provide, and it composes with everything built here: the Rollout object
lives in the same Kustomize base, managed by the same Application.

# Migrate from Hand-Crafted Helm Chart to Quarkus Helm Extension

**Branch**: `feat/quarkus-helm-migration`  
**Reference implementation**: `eks-d-xpress-control-plane` (same stack: Quarkus + JOSDK, same org)

---

## Why Migrate

The current `charts/kube-microvm-operator/` is a hand-crafted chart maintained separately from
the operator code. This causes several problems:

| Problem | Impact |
|---------|--------|
| Image tag pinned in `values.yaml` as `latest` — requires `yq` sed-hacks in CI to set release version | Fragile, easy to forget |
| Chart templates duplicate what Quarkus Kubernetes extension already generates (Deployment, Service, ServiceAccount, RBAC, health probes, resource limits) | Double maintenance |
| Adding a new env var or config property requires updating both `application.properties` AND `values.yaml` manually | Error-prone drift |
| CRD files in `charts/kube-microvm-operator/crds/` are hand-maintained, can go out of sync with model classes | Silent breakage |

With Quarkus Helm extension (`io.quarkiverse.helm:quarkus-helm`):
- Deployment, Service, ServiceAccount, RBAC, probes, resources → **auto-generated** from
  `application.properties` + `quarkus.kubernetes.*` properties
- Image tag → set at build time via `-Dquarkus.container-image.tag=${VERSION}`, no post-processing
- Custom resources (CRDs, MutatingWebhookConfiguration, ClusterRole for tokens) → declared in
  `src/main/kubernetes/kubernetes.yml`, merged into chart at build time
- `values.yaml` overrides → placed in `src/main/helm/values.yaml`, merged at build time

---

## How It Works (eks-d-xpress pattern)

```
src/main/resources/application.properties
  quarkus.helm.name=kube-microvm-operator
  quarkus.helm.create-tar-file=true
  quarkus.container-image.registry=ghcr.io
  quarkus.container-image.group=codriverlabs
  quarkus.container-image.name=kube-microvm-operator
  quarkus.container-image.tag=latest   ← overridden at build: -Dquarkus.container-image.tag=0.0.1
  quarkus.kubernetes.service-type=ClusterIP
  quarkus.kubernetes.namespace=kube-microvm
  quarkus.kubernetes.resources.requests.cpu=100m
  ... etc

src/main/kubernetes/kubernetes.yml    ← custom k8s objects merged into chart
  ClusterRole (RBAC for operator)
  ClusterRole (microvm-token-requester)
  MutatingWebhookConfiguration
  ValidatingWebhookConfiguration
  CRDs (microvms, microvmimages, ...)

src/main/helm/values.yaml             ← only the overrides that need to be user-configurable
  {}  (or specific overrides)

↓ mvn package -Dquarkus.helm.version=${VERSION} -Dquarkus.container-image.tag=${VERSION}

target/helm/kubernetes/kube-microvm-operator/
  Chart.yaml          ← version + appVersion from build properties
  values.yaml         ← generated: image, probes, resources, env vars
  values.schema.json  ← generated
  templates/
    deployment.yaml   ← generated
    service.yaml      ← generated
    serviceaccount.yaml ← generated
    clusterrole.yaml  ← from kubernetes.yml
    clusterrolebinding.yaml
    mutatingwebhookcfg.yaml
    validatingwebhookcfg.yaml
    crds/             ← from kubernetes.yml
```

---

## Migration Steps

### Step 1: Add `quarkus-helm` dependency to `operator-controller/pom.xml`

```xml
<dependency>
    <groupId>io.quarkiverse.helm</groupId>
    <artifactId>quarkus-helm</artifactId>
</dependency>
```

Add to parent `pom.xml` dependencyManagement (get version from Quarkiverse BOM):

```xml
<dependency>
    <groupId>io.quarkiverse.helm</groupId>
    <artifactId>quarkus-helm</artifactId>
    <version>${quarkus-helm.version}</version>
</dependency>
```

Check current Quarkiverse Helm version compatible with Quarkus 3.36.x:
```bash
mvn dependency:get -Dartifact=io.quarkiverse.helm:quarkus-helm:LATEST
```

### Step 2: Configure `operator-controller/src/main/resources/application.properties`

Add Quarkus Helm + Kubernetes + container-image configuration:

```properties
# ─── Helm chart generation ────────────────────────────────────────────────
quarkus.helm.name=kube-microvm-operator
quarkus.helm.description=Kubernetes operator for AWS Lambda MicroVMs
quarkus.helm.create-tar-file=true
quarkus.helm.notes=templates/NOTES.txt
quarkus.helm.version=0.0.1-SNAPSHOT

# ─── Container image ──────────────────────────────────────────────────────
quarkus.container-image.registry=ghcr.io
quarkus.container-image.group=codriverlabs
quarkus.container-image.name=kube-microvm-operator
quarkus.container-image.tag=latest

# ─── Kubernetes deployment ────────────────────────────────────────────────
quarkus.kubernetes.namespace=kube-microvm
quarkus.kubernetes.service-type=ClusterIP
quarkus.kubernetes.service-account=kube-microvm-operator
quarkus.kubernetes.replicas=1

# Resources
quarkus.kubernetes.resources.requests.cpu=100m
quarkus.kubernetes.resources.requests.memory=256Mi
quarkus.kubernetes.resources.limits.cpu=500m
quarkus.kubernetes.resources.limits.memory=512Mi

# Env vars (user-overridable via values.yaml)
quarkus.kubernetes.env.vars.microvm.aws.region=us-east-1

# Health probes — map to Quarkus SmallRye health endpoints
quarkus.kubernetes.liveness-probe.http-action-path=/q/health/live
quarkus.kubernetes.readiness-probe.http-action-path=/q/health/ready

# Ports
quarkus.kubernetes.ports.http.container-port=8080
quarkus.kubernetes.ports.https.container-port=8443
```

### Step 3: Create `operator-controller/src/main/kubernetes/kubernetes.yml`

This file is merged into the generated chart at build time. It contains all resources that
Quarkus Kubernetes extension cannot auto-generate:

```yaml
# ─── Operator ClusterRole ─────────────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-microvm-operator
rules:
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms", "microvmimages", "microvmnetworks", "microvmclasses",
              "microvmreplicasets", "microvmtemplates"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms/status", "microvmimages/status", "microvmnetworks/status",
              "microvmreplicasets/status"]
  verbs: ["get", "update", "patch"]
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms/finalizers", "microvmimages/finalizers", "microvmnetworks/finalizers"]
  verbs: ["update"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["events", "serviceaccounts", "pods"]
  verbs: ["get", "list", "watch", "create", "patch"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
  verbs: ["get", "list", "watch"]
---
# ─── Token requester ClusterRole (for pods that need VM tokens) ───────────
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: microvm-token-requester
rules:
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms/token"]
  verbs: ["create"]
---
# ─── MutatingWebhookConfiguration ────────────────────────────────────────
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kube-microvm-operator-mutating
  annotations:
    cert-manager.io/inject-ca-from: "kube-microvm/kube-microvm-operator-webhook-cert"
webhooks:
- name: mutate.microvms.lambda.aws.amazon.com
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Ignore
  clientConfig:
    service:
      name: kube-microvm-operator
      namespace: kube-microvm
      path: /mutate-microvm
      port: 443
  rules:
  - apiGroups: ["lambda.aws.amazon.com"]
    apiVersions: ["v1alpha1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["microvms"]
- name: pod-inject.lambda.aws.amazon.com
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Ignore
  clientConfig:
    service:
      name: kube-microvm-operator
      namespace: kube-microvm
      path: /mutate-pod
      port: 443
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
  namespaceSelector:
    matchLabels:
      lambda.microvm.auth/inject: "enabled"
---
# ─── ValidatingWebhookConfiguration ──────────────────────────────────────
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: kube-microvm-operator-validating
  annotations:
    cert-manager.io/inject-ca-from: "kube-microvm/kube-microvm-operator-webhook-cert"
webhooks:
- name: validate.microvms.lambda.aws.amazon.com
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Fail
  clientConfig:
    service:
      name: kube-microvm-operator
      namespace: kube-microvm
      path: /validate-microvm
      port: 443
  rules:
  - apiGroups: ["lambda.aws.amazon.com"]
    apiVersions: ["v1alpha1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["microvms", "microvmimages", "microvmnetworks"]
---
# ─── CRDs ────────────────────────────────────────────────────────────────
# CRDs are included via quarkus.helm.values[0].property pointing to charts/kube-microvm-operator/crds/
# OR copied into src/main/kubernetes/ — see notes below
```

> **Note on CRDs**: Quarkus JOSDK auto-generates CRD YAML files into `target/kubernetes/*.yaml`
> when `quarkus.operator-sdk.generate-csv=true` or when the model classes carry `@Group/@Version/@Kind`
> annotations (which they do). The CRD files can be included in the Helm chart by setting
> `quarkus.helm.values-schema.enabled=true` or by referencing them from `kubernetes.yml`.
> The simplest approach: let JOSDK generate CRDs and copy them into the chart's `crds/` directory
> as part of the Maven build (`maven-resources-plugin`), replacing the current hand-maintained files.

### Step 4: Create `operator-controller/src/main/helm/values.yaml`

Only configurable values that operators need to override — not the full default set:

```yaml
# User-overridable values for kube-microvm-operator
# Full defaults are in the generated values.yaml

# AWS configuration (required)
app:
  envs:
    microvm.aws.region: ""   # Set this: us-east-1, us-east-2, etc.

# IRSA role ARN (if using IRSA instead of Pod Identity)
serviceAccount:
  annotations: {}
  # example for IRSA:
  # eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/ROLE

# Token injection sidecar
authAgent:
  image:
    repository: ghcr.io/codriverlabs/microvm-auth-agent
    tag: latest

tokenEndpoint:
  enabled: true
  maxExpiryMinutes: 60
```

### Step 5: Update CI workflow — `helm-chart` job

Replace the current `sed`+`yq` approach with Quarkus Helm build:

```yaml
- name: Build and push Helm chart to GHCR (OCI)
  run: |
    VERSION=${GITHUB_REF_NAME#v}
    OWNER=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
    REGISTRY=ghcr.io/${OWNER}

    mvn -B -pl operator-controller package -DskipTests \
      -Dquarkus.helm.version=${VERSION} \
      -Dquarkus.container-image.tag=${VERSION} \
      -Dquarkus.container-image.build=false   # don't build Docker image here (done separately)

    helm push operator-controller/target/helm/kubernetes/kube-microvm-operator-${VERSION}.tar.gz \
      oci://${REGISTRY}/helm
```

The `-Dquarkus.container-image.tag=${VERSION}` sets the image tag in the generated `values.yaml`
automatically — no `yq` or `sed` needed.

### Step 6: Delete the hand-crafted chart

```bash
git rm -r charts/kube-microvm-operator/
```

---

## What Quarkus Helm Generates vs What We Keep Custom

| Resource | Generated by Quarkus | Custom (kubernetes.yml) |
|----------|---------------------|-------------------------|
| Deployment | ✅ (from app.properties) | — |
| Service | ✅ | — |
| ServiceAccount | ✅ | — |
| ConfigMap (env vars) | ✅ | — |
| Health probes | ✅ | — |
| Resource limits | ✅ | — |
| ClusterRole (operator RBAC) | ❌ | ✅ |
| ClusterRole (token-requester) | ❌ | ✅ |
| ClusterRoleBinding | ✅ (from SA config) | — |
| MutatingWebhookConfiguration | ❌ | ✅ |
| ValidatingWebhookConfiguration | ❌ | ✅ |
| Certificate (cert-manager) | ❌ | ✅ |
| CRDs | Via JOSDK generate → copy | ✅ |

---

## Generated `values.yaml` Structure (Quarkus Helm default)

Quarkus Helm puts everything under `app:`:

```yaml
app:
  image: ghcr.io/codriverlabs/kube-microvm-operator:0.0.1-rc1
  envs:
    microvm.aws.region: us-east-1
  ports:
    http: 8080
    https: 8443
  livenessProbe: ...
  readinessProbe: ...
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {cpu: 500m, memory: 512Mi}
```

The deployment template uses `{{ .Values.app.image }}` — this is the **key difference** from the
current hand-crafted chart which uses `{{ .Values.image.repository }}:{{ .Values.image.tag }}`.
Helm install command remains the same; the internal structure changes.

---

## Updated `build-local.sh`

After migration, `build-local.sh` passes Quarkus Helm + container-image properties directly to
Maven — no separate chart packaging step.

Key differences from current script:
- `--push` triggers `quarkus.container-image.push=true` (Quarkus builds and pushes the image, no
  separate `docker push`)
- `--helm` generates the Helm chart tarball into `operator-controller/target/helm/`
- `quarkus.helm.version=${IMAGE_TAG}` and `quarkus.container-image.tag=${IMAGE_TAG}` are always
  passed together so image tag and chart version stay in sync
- `--only operator|webhook|cli|agent` selects subsets

```bash
#!/usr/bin/env bash
# build-local.sh — KubeMicroVM operator local build
#
# Usage:
#   ./build-local.sh                          # JVM build, all modules
#   ./build-local.sh --native                 # GraalVM native (CLI + operator)
#   ./build-local.sh --skip-tests             # skip unit + integration tests
#   ./build-local.sh --push                   # build + push container images
#   ./build-local.sh --helm                   # generate Helm chart tarball
#   ./build-local.sh --only operator          # build only operator-controller
#   ./build-local.sh --only cli               # build only kubectl-microvm CLI
#   ./build-local.sh --only operator,cli      # multiple modules
#   ./build-local.sh --registry 123.dkr.ecr.us-east-1.amazonaws.com
#   ./build-local.sh --push --helm --registry 123.dkr.ecr.us-east-1.amazonaws.com
#
set -euo pipefail

NATIVE=false
SKIP_TESTS=false
PUSH=false
HELM=false
ONLY=""
REGISTRY=""

for arg in "$@"; do
  case $arg in
    --help)
      echo "Usage: ./build-local.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --native              Build GraalVM native binaries (operator + CLI)"
      echo "  --skip-tests          Skip tests"
      echo "  --push                Push container images after build"
      echo "  --helm                Generate Helm chart tarball"
      echo "  --only <list>         Comma-separated: operator, webhook, cli, agent, tests"
      echo "  --registry <url>      Container registry (default: ghcr.io/codriverlabs)"
      echo "  --help                Show this help"
      echo ""
      echo "Examples:"
      echo "  ./build-local.sh --skip-tests"
      echo "  ./build-local.sh --push --helm --registry 123.dkr.ecr.us-east-1.amazonaws.com"
      echo "  ./build-local.sh --native --only cli"
      exit 0
      ;;
    --native)     NATIVE=true ;;
    --skip-tests) SKIP_TESTS=true ;;
    --push)       PUSH=true ;;
    --helm)       HELM=true ;;
    --only=*)     ONLY="${arg#--only=}" ;;
    --registry=*) REGISTRY="${arg#--registry=}" ;;
    --only)       ;;
    --registry)   ;;
    *)
      if [[ "${PREV_ARG:-}" == "--only" ]];     then ONLY="$arg"
      elif [[ "${PREV_ARG:-}" == "--registry" ]]; then REGISTRY="$arg"
      fi
      ;;
  esac
  PREV_ARG="$arg"
done

should_build() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

SKIP_FLAG=""; $SKIP_TESTS && SKIP_FLAG="-DskipTests"

# Resolve image tag from git (strip leading 'v' and dirty suffix)
IMAGE_TAG=$(git describe --tags 2>/dev/null | sed 's/^v//;s/-[0-9]*-g[0-9a-f]*$//' || echo "dev")

# ECR login if pushing to ECR
if $PUSH && [[ "$REGISTRY" =~ \.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com ]]; then
  ECR_REGION="${BASH_REMATCH[1]}"
  echo "==> ECR login (${ECR_REGION})"
  aws ecr get-login-password --region "${ECR_REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}"
fi

# Container image flags (passed to Quarkus — it builds and optionally pushes)
image_flags() {
  local flags="-Dquarkus.container-image.build=true -Dquarkus.container-image.push=${PUSH}"
  flags+=" -Dquarkus.container-image.tag=${IMAGE_TAG}"
  [[ -n "$REGISTRY" ]] && flags+=" -Dquarkus.container-image.registry=${REGISTRY}"
  echo "$flags"
}

echo "==> KubeMicroVM build  native=${NATIVE}  skipTests=${SKIP_TESTS}  only=${ONLY:-all}  push=${PUSH}  helm=${HELM}  tag=${IMAGE_TAG}"

# 0. Parent POM + core + SDK clients (always required)
echo "--- [0] parent + operator-core + SDK clients"
./mvnw -B -N install $SKIP_FLAG
./mvnw -B -pl operator-core,operator-aws-client,operator-aws-client-core install $SKIP_FLAG

# 1. Operator controller (Quarkus builds image + Helm chart)
if should_build "operator"; then
  echo "--- [1] operator-controller"
  HELM_FLAGS=""
  $HELM && HELM_FLAGS="-Dquarkus.helm.version=${IMAGE_TAG} -Dquarkus.helm.create-tar-file=true"
  if $NATIVE; then
    ./mvnw -B -pl operator-controller package $SKIP_FLAG -Dnative \
      -Dquarkus.native.container-build=false \
      $(image_flags) $HELM_FLAGS
  else
    ./mvnw -B -pl operator-controller package $SKIP_FLAG \
      $(image_flags) $HELM_FLAGS
  fi
  $HELM && echo "==> Helm chart: operator-controller/target/helm/kubernetes/kube-microvm-operator-${IMAGE_TAG}.tar.gz"
fi

# 2. Webhook (bundled inside operator-controller — separate module only if split in future)

# 3. CLI
if should_build "cli"; then
  echo "--- [2] operator-cli"
  if $NATIVE; then
    ./mvnw -B -pl operator-cli package $SKIP_FLAG -Dnative \
      -Dquarkus.native.container-build=false
    echo "==> CLI binary: operator-cli/target/operator-cli-*-runner"
  else
    ./mvnw -B -pl operator-cli package $SKIP_FLAG
    echo "==> CLI jar: operator-cli/target/quarkus-app/"
  fi
fi

# 4. Auth agent sidecar
if should_build "agent"; then
  echo "--- [3] operator-auth-agent"
  if $NATIVE; then
    AGENT_REGISTRY="${REGISTRY:-ghcr.io/codriverlabs}"
    ./mvnw -B -pl operator-auth-agent package $SKIP_FLAG -Dnative \
      -Dquarkus.native.container-build=false \
      -Dquarkus.container-image.build=true \
      -Dquarkus.container-image.push=${PUSH} \
      -Dquarkus.container-image.tag=${IMAGE_TAG} \
      -Dquarkus.container-image.registry=${AGENT_REGISTRY%%/*} \
      -Dquarkus.container-image.group=${AGENT_REGISTRY#*/}
  else
    ./mvnw -B -pl operator-auth-agent package $SKIP_FLAG
  fi
fi

# 5. Integration tests
if should_build "tests"; then
  echo "--- [4] operator-tests"
  ./mvnw -B -pl operator-tests verify
fi

echo ""
echo "==> Build complete  (tag: ${IMAGE_TAG})"
```

---

## Updated `deploy-local.sh`

After migration, deploy uses `helm upgrade --install` pointing to either:
- The generated tarball at `operator-controller/target/helm/kubernetes/kube-microvm-operator-*.tar.gz`
- Or the GHCR OCI registry (for production)

Key differences from current script:
- No `aws eks create-pod-identity-association` scaffolding (moved to one-time `setup.sh`)
- Supports `--from-registry` to deploy directly from GHCR OCI
- `--region` and `--cluster` are explicit flags
- `--dry-run` for validation without deploying

```bash
#!/usr/bin/env bash
# deploy-local.sh — deploy KubeMicroVM operator to an EKS cluster
#
# Usage:
#   ./deploy-local.sh                              # deploy from local build
#   ./deploy-local.sh --skip-build                 # helm upgrade only (reuse existing chart)
#   ./deploy-local.sh --from-registry              # deploy from GHCR OCI (no local build)
#   ./deploy-local.sh --region us-east-1           # target AWS region
#   ./deploy-local.sh --cluster my-cluster         # EKS cluster name
#   ./deploy-local.sh --profile my-aws-profile     # AWS CLI profile
#   ./deploy-local.sh --dry-run                    # helm upgrade --dry-run
#   ./deploy-local.sh --set key=val                # extra helm values (repeatable)
#
set -euo pipefail

SKIP_BUILD=false
FROM_REGISTRY=false
DRY_RUN=false
REGION="${AWS_REGION:-us-east-1}"
CLUSTER=""
AWS_PROFILE=""
EXTRA_SET_ARGS=""
NAMESPACE="kube-microvm"
RELEASE="kube-microvm-operator"

while [[ $# -gt 0 ]]; do
  case $1 in
    --help)
      echo "Usage: ./deploy-local.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-build          Skip Maven build; use existing chart tarball"
      echo "  --from-registry       Deploy from GHCR OCI (ignores local build)"
      echo "  --region <region>     AWS region (default: \$AWS_REGION or us-east-1)"
      echo "  --cluster <name>      EKS cluster name (default: auto-detect from kubeconfig)"
      echo "  --profile <name>      AWS CLI profile"
      echo "  --namespace <ns>      Kubernetes namespace (default: kube-microvm)"
      echo "  --dry-run             Helm dry-run (no actual deploy)"
      echo "  --set key=val         Extra helm --set values (repeatable)"
      echo "  --help                Show this help"
      echo ""
      echo "Examples:"
      echo "  ./deploy-local.sh --region us-east-1 --cluster my-cluster"
      echo "  ./deploy-local.sh --skip-build --dry-run"
      echo "  ./deploy-local.sh --from-registry --region us-east-2"
      echo "  ./deploy-local.sh --set app.envs.microvm\\.aws\\.region=us-east-1"
      exit 0
      ;;
    --skip-build)    SKIP_BUILD=true ;;
    --from-registry) FROM_REGISTRY=true; SKIP_BUILD=true ;;
    --dry-run)       DRY_RUN=true ;;
    --region)        REGION="$2"; shift ;;
    --cluster)       CLUSTER="$2"; shift ;;
    --profile)       AWS_PROFILE="$2"; shift ;;
    --namespace)     NAMESPACE="$2"; shift ;;
    --set)           EXTRA_SET_ARGS="$EXTRA_SET_ARGS --set $2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

PROFILE_FLAG=""; [[ -n "$AWS_PROFILE" ]] && PROFILE_FLAG="--profile $AWS_PROFILE"
IMAGE_TAG=$(git describe --tags 2>/dev/null | sed 's/^v//;s/-[0-9]*-g[0-9a-f]*$//' || echo "dev")
DRY_RUN_FLAG=""; $DRY_RUN && DRY_RUN_FLAG="--dry-run"

# Update kubeconfig
if [[ -n "$CLUSTER" ]]; then
  echo "==> Updating kubeconfig for cluster ${CLUSTER} in ${REGION}"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" $PROFILE_FLAG
fi

# Build if needed
if ! $SKIP_BUILD; then
  echo "==> Building operator (tag: ${IMAGE_TAG})"
  ./build-local.sh --helm --skip-tests
fi

# Resolve chart source
if $FROM_REGISTRY; then
  CHART="oci://ghcr.io/codriverlabs/helm/kube-microvm-operator"
  echo "==> Deploying from GHCR OCI registry"
else
  CHART=$(ls operator-controller/target/helm/kubernetes/kube-microvm-operator-*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$CHART" ]]; then
    echo "ERROR: No chart tarball found. Run ./build-local.sh --helm first." >&2
    exit 1
  fi
  echo "==> Deploying from local chart: ${CHART}"
fi

# Ensure namespace exists
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Helm upgrade --install
echo "==> helm upgrade --install ${RELEASE} (namespace: ${NAMESPACE}, dry-run: ${DRY_RUN})"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set "app.envs.microvm\\.aws\\.region=${REGION}" \
  $EXTRA_SET_ARGS \
  $DRY_RUN_FLAG \
  --wait \
  --timeout 5m

if ! $DRY_RUN; then
  echo ""
  echo "==> Deploy complete"
  echo "    Operator: $(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=kube-microvm-operator -o name 2>/dev/null | head -1)"
  echo ""
  echo "    Install kubectl plugin:"
  echo "    ./install-kubectl-plugin.sh"
fi
```

---

## Key Differences from Current Scripts

| | Current | After migration |
|-|---------|-----------------|
| Image build | `docker buildx` in CI only | `quarkus.container-image.build=true` — Maven drives it |
| Image tag | `yq` post-processing in CI | `-Dquarkus.container-image.tag=${VERSION}` at build time |
| Helm chart | `helm package charts/kube-microvm-operator/` | `mvn package -Dquarkus.helm.version=${VERSION}` |
| Chart source on deploy | `charts/kube-microvm-operator/` | `operator-controller/target/helm/kubernetes/` |
| Push | Separate `docker push` step | `quarkus.container-image.push=true` |
| ECR repo creation | `deploy-local.sh` | `build-local.sh` (`ensure_ecr_repo`) |
| Namespace setup | `deploy-local.sh` manages Pod Identity | `deploy-local.sh` just `kubectl create namespace` + `helm upgrade` |

| Action | File |
|--------|------|
| Add dependency | `operator-controller/pom.xml` |
| Add version to BOM | `pom.xml` |
| Add helm/k8s config | `operator-controller/src/main/resources/application.properties` |
| Create custom resources | `operator-controller/src/main/kubernetes/kubernetes.yml` |
| Create helm overrides | `operator-controller/src/main/helm/values.yaml` |
| Create helm notes | `operator-controller/src/main/helm/templates/NOTES.txt` |
| Update CI | `.github/workflows/native-build.yml` (helm-chart job) |
| Delete | `charts/kube-microvm-operator/` (entire directory) |
| Update | `deploy-local.sh` (chart path changes to `operator-controller/target/helm/kubernetes/`) |
| Update | `README.md` (helm install path stays the same — OCI registry URL unchanged) |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Generated `values.yaml` uses `app.image` instead of `image.repository`/`image.tag` | Document breaking change in release notes; update any user-facing docs |
| CRD generation order — JOSDK generates CRDs during `compile`, Helm packages during `package` | Use `maven-resources-plugin` to copy `target/kubernetes/*-v1.yml` into `src/main/kubernetes/` OR use `quarkus.operator-sdk.crd.generate-all=true` |
| Custom templates (NOTES.txt, cert-manager) must be in `src/main/helm/templates/` | Create the directory and place templates there — Quarkus Helm merges them |
| Helm release name collision on upgrade (old chart used different resource names) | Use `helm upgrade --force` on first upgrade; document in migration notes |

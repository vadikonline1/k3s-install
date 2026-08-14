#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# K3s + built-in Traefik + wildcard TLS + Rancher
# Domain: *.aalto.md
# Traefik dashboard: traefik.aalto.md
# Rancher: dashboard.aalto.md
# Configuration/data: /mnt/hdd/k3s
# Certificates: /mnt/hdd/cert
# ============================================================

DOMAIN="aalto.md"
TRAEFIK_DOMAIN="traefik.aalto.md"
RANCHER_DOMAIN="dashboard.aalto.md"

BASE_DIR="/mnt/hdd/k3s"
CERT_DIR="/mnt/hdd/cert"

CERT_FILE="${CERT_DIR}/wildcard.crt"
KEY_FILE="${CERT_DIR}/wildcard.key"

TRAEFIK_DIR="${BASE_DIR}/traefik"
RANCHER_DIR="${BASE_DIR}/rancher"
TLS_DIR="${BASE_DIR}/tls"

NAMESPACE="kube-system"

# Rancher repository
RANCHER_REPO="rancher-latest"
RANCHER_REPO_URL="https://releases.rancher.com/server-charts/latest"

# Rancher password file
RANCHER_PASSWORD_FILE="${BASE_DIR}/RANCHER_PASSWORD.txt"

echo
echo "============================================================"
echo " K3s + Traefik + Rancher installation"
echo "============================================================"
echo
echo "Domain:             ${DOMAIN}"
echo "Traefik dashboard:  https://${TRAEFIK_DOMAIN}/dashboard/"
echo "Rancher:            https://${RANCHER_DOMAIN}"
echo "Certificate:        ${CERT_FILE}"
echo "Key:                ${KEY_FILE}"
echo "Config directory:   ${BASE_DIR}"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

# ------------------------------------------------------------
# Check required files
# ------------------------------------------------------------

if [[ ! -f "${CERT_FILE}" ]]; then
    echo "ERROR: Certificate not found:"
    echo "  ${CERT_FILE}"
    exit 1
fi

if [[ ! -f "${KEY_FILE}" ]]; then
    echo "ERROR: Private key not found:"
    echo "  ${KEY_FILE}"
    exit 1
fi

# ------------------------------------------------------------
# Check certificate
# ------------------------------------------------------------

echo "[1/14] Checking certificate..."

openssl x509 \
    -in "${CERT_FILE}" \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext subjectAltName || {
        echo "ERROR: Invalid certificate."
        exit 1
    }

echo
echo "Certificate looks valid."
echo

# ------------------------------------------------------------
# Check curl
# ------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1; then
    echo "[2/14] Installing curl..."

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
    else
        echo "ERROR: curl is missing and dnf was not found."
        exit 1
    fi
else
    echo "[2/14] curl already installed."
fi

# ------------------------------------------------------------
# Create directory structure
# ------------------------------------------------------------

echo "[3/14] Creating directory structure..."

mkdir -p "${BASE_DIR}"
mkdir -p "${TRAEFIK_DIR}"
mkdir -p "${RANCHER_DIR}"
mkdir -p "${TLS_DIR}"

chmod 700 "${BASE_DIR}"
chmod 700 "${TLS_DIR}"
chmod 700 "${TRAEFIK_DIR}"
chmod 700 "${RANCHER_DIR}"

echo
echo "Created:"
echo "  ${BASE_DIR}"
echo "  ${TRAEFIK_DIR}"
echo "  ${RANCHER_DIR}"
echo "  ${TLS_DIR}"
echo

# ------------------------------------------------------------
# Generate Rancher password
# ------------------------------------------------------------

echo "[4/14] Generating Rancher password..."

if [[ -f "${RANCHER_PASSWORD_FILE}" ]]; then
    RANCHER_PASSWORD="$(grep '^Password:' "${RANCHER_PASSWORD_FILE}" 2>/dev/null | head -1 | sed 's/^Password:[[:space:]]*//')"
    
    if [[ -z "${RANCHER_PASSWORD}" ]]; then
        echo "Password file exists but is corrupt. Regenerating..."
        rm -f "${RANCHER_PASSWORD_FILE}"
    else
        echo "Using existing Rancher password."
    fi
fi

if [[ ! -f "${RANCHER_PASSWORD_FILE}" ]]; then
    RANCHER_PASSWORD="$(openssl rand -hex 24)"

    cat > "${RANCHER_PASSWORD_FILE}" <<EOF
============================================================
RANCHER CREDENTIALS
============================================================

Username:
admin

Password:
${RANCHER_PASSWORD}

URL:
https://${RANCHER_DOMAIN}

Generated:
$(date)

============================================================
IMPORTANT
============================================================

Keep this file safe!

============================================================
EOF

    chmod 600 "${RANCHER_PASSWORD_FILE}"
    echo "New Rancher password generated and saved to ${RANCHER_PASSWORD_FILE}"
fi

# ------------------------------------------------------------
# Check existing K3s
# ------------------------------------------------------------

if command -v k3s >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^k3s.service'; then
    echo
    echo "ERROR: K3s appears to already be installed."
    echo
    echo "If this is an old installation and you really want"
    echo "to reinstall from zero, first run:"
    echo
    echo "  /usr/local/bin/k3s-killall.sh"
    echo "  /usr/local/bin/k3s-uninstall.sh"
    echo
    exit 1
fi

# ------------------------------------------------------------
# Install K3s
# ------------------------------------------------------------

echo "[5/14] Installing K3s..."

curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644

echo
echo "K3s installation completed."
echo

# ------------------------------------------------------------
# Wait for Kubernetes API
# ------------------------------------------------------------

echo "[6/14] Waiting for Kubernetes..."

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

for i in {1..60}; do
    if kubectl get nodes >/dev/null 2>&1; then
        break
    fi

    echo "Waiting for Kubernetes API... ${i}/60"
    sleep 2
done

if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API did not become available."
    exit 1
fi

echo
kubectl get nodes
echo

# ------------------------------------------------------------
# Create wildcard TLS Secret
# ------------------------------------------------------------

echo "[7/14] Creating wildcard TLS Secret..."

kubectl create secret tls wildcard-tls \
    --cert="${CERT_FILE}" \
    --key="${KEY_FILE}" \
    --namespace="${NAMESPACE}" \
    --dry-run=client \
    -o yaml > "${TLS_DIR}/wildcard-tls.yaml"

chmod 600 "${TLS_DIR}/wildcard-tls.yaml"

kubectl apply -f "${TLS_DIR}/wildcard-tls.yaml"

echo
echo "TLS Secret:"
kubectl get secret wildcard-tls -n "${NAMESPACE}"
echo

# ------------------------------------------------------------
# Traefik HelmChartConfig
# ------------------------------------------------------------

echo "[8/14] Creating Traefik configuration..."

cat > "${TRAEFIK_DIR}/traefik-config.yaml" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system

spec:
  valuesContent: |-
    ports:
      web:
        port: 80
        exposedPort: 80
        expose:
          default: true
        redirections:
          entryPoint:
            to: websecure
            scheme: https
            permanent: true

      websecure:
        port: 443
        exposedPort: 443
        expose:
          default: true
        tls:
          enabled: true

    providers:
      kubernetesCRD:
        enabled: true

      kubernetesIngress:
        enabled: true
        publishedService:
          enabled: true

    api:
      dashboard: true
      insecure: false

    ingressRoute:
      dashboard:
        enabled: false
EOF

kubectl apply -f "${TRAEFIK_DIR}/traefik-config.yaml"

echo
echo "Traefik HelmChartConfig created."
echo

# ------------------------------------------------------------
# Wait for Traefik CRDs
# ------------------------------------------------------------

echo "[9/14] Waiting for Traefik CRDs..."

for i in {1..60}; do
    if kubectl get crd ingressroutes.traefik.io >/dev/null 2>&1; then
        break
    fi

    echo "Waiting for Traefik CRDs... ${i}/60"
    sleep 2
done

if ! kubectl get crd ingressroutes.traefik.io >/dev/null 2>&1; then
    echo "ERROR: Traefik CRDs were not installed."
    exit 1
fi

echo
echo "Traefik CRDs are available."
echo

# ------------------------------------------------------------
# TLSStore
# ------------------------------------------------------------

echo "[10/14] Creating Traefik default TLSStore..."

cat > "${TRAEFIK_DIR}/tls-store.yaml" <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: kube-system

spec:
  defaultCertificate:
    secretName: wildcard-tls
EOF

kubectl apply -f "${TRAEFIK_DIR}/tls-store.yaml"

echo
echo "Default TLS certificate configured."
echo

# ------------------------------------------------------------
# Traefik Dashboard authentication + IngressRoute
# ------------------------------------------------------------

echo "[11/14] Creating Traefik dashboard..."

cat > "${TRAEFIK_DIR}/dashboard.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: traefik-dashboard-auth
  namespace: kube-system

type: kubernetes.io/basic-auth

stringData:
  username: admin
  password: SCHIMBA_PAROLA_ASTA!

---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: traefik-dashboard-auth
  namespace: kube-system

spec:
  basicAuth:
    secret: traefik-dashboard-auth

---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: kube-system

spec:
  entryPoints:
    - websecure

  routes:
    - match: Host(`traefik.aalto.md`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      kind: Rule

      middlewares:
        - name: traefik-dashboard-auth

      services:
        - name: api@internal
          kind: TraefikService

  tls: {}
EOF

kubectl apply -f "${TRAEFIK_DIR}/dashboard.yaml"

chmod 600 "${TRAEFIK_DIR}/dashboard.yaml"

echo
echo "Dashboard configuration created."
echo

# ------------------------------------------------------------
# Wait for Traefik
# ------------------------------------------------------------

echo "[12/14] Waiting for Traefik..."

for i in {1..90}; do

    READY="$(kubectl get pods \
        -n kube-system \
        -l app.kubernetes.io/name=traefik \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
        2>/dev/null || true)"

    if echo "${READY}" | grep -q '^true$'; then
        break
    fi

    echo "Waiting for Traefik... ${i}/90"
    sleep 2
done

echo

# ============================================================
# RANCHER INSTALLATION
# ============================================================

echo "[13/14] Installing Rancher..."

# ------------------------------------------------------------
# Check Helm
# ------------------------------------------------------------

if ! command -v helm >/dev/null 2>&1; then
    echo "Helm not installed. Installing Helm 3..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm version

# ------------------------------------------------------------
# Add Rancher repository
# ------------------------------------------------------------

echo "Adding Rancher repository..."

helm repo add "${RANCHER_REPO}" "${RANCHER_REPO_URL}" --force-update
helm repo update

echo
echo "Available Rancher versions:"
helm search repo "${RANCHER_REPO}/rancher" --versions | head -15

# ------------------------------------------------------------
# Detect Kubernetes version
# ------------------------------------------------------------

echo
echo "Detecting Kubernetes version..."

KUBE_SERVER_VERSION="$(
    kubectl version -o json 2>/dev/null \
    | sed -n 's/.*"gitVersion":"\([^"]*\)".*/\1/p' \
    | head -1
)"

if [[ -z "${KUBE_SERVER_VERSION}" ]]; then
    KUBE_SERVER_VERSION="$(
        kubectl get nodes \
            -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' \
            2>/dev/null || true
    )"
fi

KUBE_VERSION="${KUBE_SERVER_VERSION#v}"
KUBE_VERSION_SHORT="$(echo "${KUBE_VERSION}" | cut -d. -f1-2)"

echo "Kubernetes: ${KUBE_SERVER_VERSION}"

# ------------------------------------------------------------
# Find compatible Rancher version
# ------------------------------------------------------------

echo
echo "Finding compatible Rancher version..."

RANCHER_VERSIONS=()
while IFS= read -r line; do
    RANCHER_VERSIONS+=("$line")
done < <(
    helm search repo \
        "${RANCHER_REPO}/rancher" \
        --versions \
        2>/dev/null \
        | awk 'NR > 1 {print $2}'
)

RANCHER_VERSION=""
RANCHER_FOUND="false"

for CANDIDATE_VERSION in "${RANCHER_VERSIONS[@]}"; do
    [[ -z "${CANDIDATE_VERSION}" ]] && continue

    echo "Testing Rancher ${CANDIDATE_VERSION} ..."

    KUBE_VERSION_CONSTRAINT="$(
        helm show chart \
            "${RANCHER_REPO}/rancher" \
            --version "${CANDIDATE_VERSION}" \
            2>/dev/null \
        | grep -i '^kubeVersion:' \
        | sed 's/^[kK][uU][bB][eE][vV][eE][rR][sS][iI][oO][nN]:[[:space:]]*//'
    )"

    if [[ -z "${KUBE_VERSION_CONSTRAINT}" ]]; then
        echo "  ✓ compatible (no kubeVersion restriction)"
        RANCHER_VERSION="${CANDIDATE_VERSION}"
        RANCHER_FOUND="true"
        break
    fi

    COMPATIBLE="false"
    
    if [[ "${CANDIDATE_VERSION}" == 2.15.* ]]; then
        if [[ "${KUBE_VERSION_SHORT}" == "1.36" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.37" ]]; then
            COMPATIBLE="true"
        fi
    elif [[ "${CANDIDATE_VERSION}" == 2.14.* ]]; then
        if [[ "${KUBE_VERSION_SHORT}" == "1.35" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.34" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.33" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.32" ]]; then
            COMPATIBLE="true"
        fi
    elif [[ "${CANDIDATE_VERSION}" == 2.13.* ]]; then
        if [[ "${KUBE_VERSION_SHORT}" == "1.34" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.33" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.32" ]]; then
            COMPATIBLE="true"
        fi
    elif [[ "${CANDIDATE_VERSION}" == 2.12.* ]]; then
        if [[ "${KUBE_VERSION_SHORT}" == "1.33" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.32" ]]; then
            COMPATIBLE="true"
        fi
    else
        COMPATIBLE="true"
    fi

    if [[ "${COMPATIBLE}" == "true" ]]; then
        RANCHER_VERSION="${CANDIDATE_VERSION}"
        RANCHER_FOUND="true"
        echo "  ✓ compatible"
        break
    else
        echo "  ✗ incompatible (kubeVersion: ${KUBE_VERSION_CONSTRAINT})"
    fi
done

if [[ "${RANCHER_FOUND}" != "true" ]]; then
    echo "ERROR: No compatible Rancher version found for Kubernetes ${KUBE_SERVER_VERSION}"
    exit 1
fi

echo
echo "Selected Rancher version: ${RANCHER_VERSION}"

# ------------------------------------------------------------
# Create Rancher namespace
# ------------------------------------------------------------

kubectl create namespace cattle-system \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Create Rancher TLS secret
# ------------------------------------------------------------

echo "Creating Rancher TLS secret..."

kubectl -n cattle-system create secret tls tls-rancher-ingress \
    --cert="${CERT_FILE}" \
    --key="${KEY_FILE}" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Create Rancher values
# ------------------------------------------------------------

cat > "${RANCHER_DIR}/values.yaml" <<EOF
hostname: ${RANCHER_DOMAIN}

bootstrapPassword: ${RANCHER_PASSWORD}

replicas: 1

ingress:
  tls:
    source: secret
  ingressClassName: traefik

privateCA: false

# Disable cert-manager since we use our own certificate
certmanager:
  enabled: false
EOF

chmod 600 "${RANCHER_DIR}/values.yaml"

# ------------------------------------------------------------
# Install Rancher
# ------------------------------------------------------------

echo "Installing Rancher ${RANCHER_VERSION}..."

MAX_RETRIES=3
RETRY_COUNT=0
INSTALLED=false

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do

    if helm upgrade --install rancher \
        "${RANCHER_REPO}/rancher" \
        --version "${RANCHER_VERSION}" \
        --namespace cattle-system \
        --create-namespace \
        -f "${RANCHER_DIR}/values.yaml" \
        --wait \
        --timeout 15m \
        2>&1; then
        
        INSTALLED=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    if [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; then
        echo "Installation failed, retry ${RETRY_COUNT}/${MAX_RETRIES}..."
        sleep 10
    fi
done

if [[ "${INSTALLED}" != "true" ]]; then
    echo "ERROR: Rancher installation failed after ${MAX_RETRIES} attempts."
    exit 1
fi

# ------------------------------------------------------------
# Wait for Rancher
# ------------------------------------------------------------

echo "Waiting for Rancher..."

kubectl -n cattle-system rollout status \
    deployment/rancher \
    --timeout=900s || true

kubectl wait \
    --namespace cattle-system \
    --for=condition=Ready \
    pod \
    -l app=rancher \
    --timeout=900s || true

echo
echo "Rancher installed successfully!"

# ============================================================
# FINAL CHECKS
# ============================================================

echo "[14/14] Final cluster checks..."
echo

echo "==================== NODES ===================="
kubectl get nodes -o wide

echo
echo "==================== PODS ====================="
kubectl get pods -A

echo
echo "==================== SERVICES ================="
kubectl get svc -n kube-system

echo
echo "==================== TRAEFIK =================="
kubectl get pods -n kube-system \
    -l app.kubernetes.io/name=traefik \
    -o wide

echo
echo "==================== HELM ====================="
kubectl get helmchart -n kube-system traefik

echo
echo "==================== TLS ======================"
kubectl get secret wildcard-tls -n kube-system

echo
echo "==================== TRAEFIK CRDS ============="
kubectl get ingressroute,middleware,tlsstore -n kube-system

echo
echo "==================== RANCHER =================="
kubectl get pods -n cattle-system -o wide

echo
echo "==================== RANCHER INGRESS =========="
kubectl get ingress -n cattle-system

echo
echo "============================================================"
echo " INSTALLATION FINISHED"
echo "============================================================"
echo
echo "Traefik dashboard:"
echo
echo "  https://${TRAEFIK_DOMAIN}/dashboard/"
echo
echo "Username: admin"
echo "Password: SCHIMBA_PAROLA_ASTA! (change in ${TRAEFIK_DIR}/dashboard.yaml)"
echo
echo "Rancher URL:"
echo
echo "  https://${RANCHER_DOMAIN}"
echo
echo "Rancher credentials:"
echo "  Username: admin"
echo "  Password: ${RANCHER_PASSWORD}"
echo
echo "Password saved to:"
echo "  ${RANCHER_PASSWORD_FILE}"
echo
echo "Configuration:"
echo "  ${BASE_DIR}/traefik/traefik-config.yaml"
echo "  ${BASE_DIR}/traefik/tls-store.yaml"
echo "  ${BASE_DIR}/traefik/dashboard.yaml"
echo "  ${RANCHER_DIR}/values.yaml"
echo "  ${TLS_DIR}/wildcard-tls.yaml"
echo
echo "Certificate source:"
echo "  ${CERT_FILE}"
echo "  ${KEY_FILE}"
echo
echo "============================================================"

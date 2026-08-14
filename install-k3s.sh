#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# K3s + built-in Traefik + wildcard TLS
# Domain: *.aalto.md
# Traefik dashboard: traefik.aalto.md
# Configuration/data: /mnt/hdd/k3s
# Certificates: /mnt/hdd/cert
# ============================================================

DOMAIN="aalto.md"
TRAEFIK_DOMAIN="traefik.aalto.md"

BASE_DIR="/mnt/hdd/k3s"
CERT_DIR="/mnt/hdd/cert"

CERT_FILE="${CERT_DIR}/wildcard.crt"
KEY_FILE="${CERT_DIR}/wildcard.key"

TRAEFIK_DIR="${BASE_DIR}/traefik"
TLS_DIR="${BASE_DIR}/tls"

NAMESPACE="kube-system"

echo
echo "============================================================"
echo " K3s + Traefik installation"
echo "============================================================"
echo
echo "Domain:             ${DOMAIN}"
echo "Traefik dashboard:  https://${TRAEFIK_DOMAIN}/dashboard/"
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

echo "[1/12] Checking certificate..."

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
    echo "[2/12] Installing curl..."

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
    else
        echo "ERROR: curl is missing and dnf was not found."
        exit 1
    fi
else
    echo "[2/12] curl already installed."
fi

# ------------------------------------------------------------
# Create directory structure
# ------------------------------------------------------------

echo "[3/12] Creating directory structure..."

mkdir -p "${BASE_DIR}"
mkdir -p "${TRAEFIK_DIR}"
mkdir -p "${TLS_DIR}"

chmod 700 "${BASE_DIR}"
chmod 700 "${TLS_DIR}"
chmod 700 "${TRAEFIK_DIR}"

echo
echo "Created:"
echo "  ${BASE_DIR}"
echo "  ${TRAEFIK_DIR}"
echo "  ${TLS_DIR}"
echo

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

echo "[4/12] Installing K3s..."

curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644

echo
echo "K3s installation completed."
echo

# ------------------------------------------------------------
# Wait for Kubernetes API
# ------------------------------------------------------------

echo "[5/12] Waiting for Kubernetes..."

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

echo "[6/12] Creating wildcard TLS Secret..."

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

echo "[7/12] Creating Traefik configuration..."

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

echo "[8/12] Waiting for Traefik CRDs..."

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

echo "[9/12] Creating Traefik default TLSStore..."

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

echo "[10/12] Creating Traefik dashboard..."

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

echo "[11/12] Waiting for Traefik..."

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

# ------------------------------------------------------------
# Final checks
# ------------------------------------------------------------

echo "[12/12] Final cluster checks..."
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
echo "============================================================"
echo " INSTALLATION FINISHED"
echo "============================================================"
echo
echo "Traefik dashboard:"
echo
echo "  https://${TRAEFIK_DOMAIN}/dashboard/"
echo
echo "Username:"
echo "  admin"
echo
echo "IMPORTANT:"
echo "Change the password in:"
echo
echo "  ${TRAEFIK_DIR}/dashboard.yaml"
echo
echo "Then apply:"
echo
echo "  kubectl apply -f ${TRAEFIK_DIR}/dashboard.yaml"
echo
echo "Configuration:"
echo
echo "  ${BASE_DIR}/traefik/traefik-config.yaml"
echo "  ${BASE_DIR}/traefik/tls-store.yaml"
echo "  ${BASE_DIR}/traefik/dashboard.yaml"
echo "  ${BASE_DIR}/tls/wildcard-tls.yaml"
echo
echo "Certificate source:"
echo "  ${CERT_FILE}"
echo "  ${KEY_FILE}"
echo
echo "============================================================"

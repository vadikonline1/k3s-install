#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# K3s + Traefik + Wildcard TLS + Rancher
#
# DNS:
#   dashboard.aalto.md -> Rancher
#
# Certificate:
#   /mnt/hdd/cert/wildcard.crt
#   /mnt/hdd/cert/wildcard.key
#
# Config:
#   /mnt/hdd/k3s/
# ============================================================

K3S_DIR="/mnt/hdd/k3s"
CERT_DIR="/mnt/hdd/cert"

CERT_FILE="${CERT_DIR}/wildcard.crt"
KEY_FILE="${CERT_DIR}/wildcard.key"

RANCHER_HOSTNAME="dashboard.aalto.md"

# ------------------------------------------------------------
# IMPORTANT
#
# Leave empty to use the current K3s version.
#
# If you want to pin a specific K3s version later:
#
# K3S_VERSION="v1.xx.x+k3s1"
#
# Make sure it is supported by your Rancher version.
# ------------------------------------------------------------
K3S_VERSION=""

# Rancher stable repository
RANCHER_REPO="rancher-stable"
RANCHER_REPO_URL="https://releases.rancher.com/server-charts/stable"

# ------------------------------------------------------------
# Rancher bootstrap password
#
# CHANGE THIS!
# ------------------------------------------------------------
RANCHER_PASSWORD="CHANGE_THIS_RANCHER_PASSWORD"

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: rulează scriptul ca root."
    exit 1
fi

echo
echo "============================================================"
echo " K3s + Traefik + Rancher installation"
echo "============================================================"
echo

if [[ ! -f "${CERT_FILE}" ]]; then
    echo "ERROR: nu există:"
    echo "  ${CERT_FILE}"
    exit 1
fi

if [[ ! -f "${KEY_FILE}" ]]; then
    echo "ERROR: nu există:"
    echo "  ${KEY_FILE}"
    exit 1
fi

if [[ "${RANCHER_PASSWORD}" == "CHANGE_THIS_RANCHER_PASSWORD" ]]; then
    echo
    echo "ERROR: schimbă RANCHER_PASSWORD în script înainte de instalare."
    echo
    exit 1
fi

# ------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------

echo "[1/12] Detectare sistem..."

if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PKG="apt-get"
else
    echo "ERROR: sistem Linux nesuportat."
    exit 1
fi

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

echo "[2/12] Instalare pachete necesare..."

if [[ "${PKG}" == "dnf" || "${PKG}" == "yum" ]]; then

    ${PKG} install -y \
        curl \
        wget \
        tar \
        gzip \
        openssl \
        ca-certificates \
        chrony

    systemctl enable --now chronyd || true

elif [[ "${PKG}" == "apt-get" ]]; then

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        wget \
        tar \
        gzip \
        openssl \
        ca-certificates \
        chrony

    systemctl enable --now chrony || true

fi

# ------------------------------------------------------------
# Firewalld
#
# Rancher documentation warns that firewalld can conflict with
# Kubernetes networking. We disable it for this simple single
# node installation.
# ------------------------------------------------------------

echo "[3/12] Configurare firewall..."

if systemctl list-unit-files | grep -q '^firewalld.service'; then
    systemctl disable --now firewalld || true
fi

# ------------------------------------------------------------
# Directory structure
# ------------------------------------------------------------

echo "[4/12] Pregătire directoare..."

mkdir -p "${K3S_DIR}"
mkdir -p "${K3S_DIR}/traefik"
mkdir -p "${K3S_DIR}/rancher"
mkdir -p "${K3S_DIR}/cert"

chmod 700 "${K3S_DIR}"

# Copy certificates into the configuration directory.
#
# We do not move them; we make a controlled copy.
#

cp -f "${CERT_FILE}" "${K3S_DIR}/cert/wildcard.crt"
cp -f "${KEY_FILE}" "${K3S_DIR}/cert/wildcard.key"

chmod 600 "${K3S_DIR}/cert/wildcard.key"
chmod 644 "${K3S_DIR}/cert/wildcard.crt"

# ------------------------------------------------------------
# Install K3s
# ------------------------------------------------------------

echo "[5/12] Instalare K3s..."

if systemctl is-active --quiet k3s; then

    echo "K3s este deja instalat și pornit."

else

    if [[ -n "${K3S_VERSION}" ]]; then

        echo "Instalez K3s versiunea: ${K3S_VERSION}"

        curl -sfL https://get.k3s.io \
            | INSTALL_K3S_VERSION="${K3S_VERSION}" \
              sh -s - server

    else

        echo "Instalez versiunea K3s implicită curentă."

        curl -sfL https://get.k3s.io \
            | sh -s - server

    fi

fi

systemctl enable --now k3s

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Wait for API

echo "[6/12] Aștept Kubernetes API..."

for i in {1..60}; do

    if kubectl get nodes >/dev/null 2>&1; then
        break
    fi

    sleep 2

done

kubectl get nodes

# ------------------------------------------------------------
# Save kubeconfig
# ------------------------------------------------------------

cp -f /etc/rancher/k3s/k3s.yaml "${K3S_DIR}/k3s.yaml"

chmod 600 "${K3S_DIR}/k3s.yaml"

# ------------------------------------------------------------
# Create wildcard TLS secret for Traefik
# ------------------------------------------------------------

echo "[7/12] Configurez wildcard TLS..."

kubectl create namespace kube-system \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

kubectl -n kube-system create secret tls wildcard-tls \
    --cert="${K3S_DIR}/cert/wildcard.crt" \
    --key="${K3S_DIR}/cert/wildcard.key" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Traefik configuration
#
# 1. HTTP :80 -> HTTPS :443
#
# 2. wildcard certificate becomes default certificate
#
# Traefik is the packaged K3s Traefik.
# ------------------------------------------------------------

echo "[8/12] Configurez Traefik..."

cat > "${K3S_DIR}/traefik/traefik-config.yaml" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        redirectTo:
          port: websecure

    tls:
      stores:
        default:
          defaultCertificate:
            secretName: wildcard-tls
EOF

cp "${K3S_DIR}/traefik/traefik-config.yaml" \
   /var/lib/rancher/k3s/server/manifests/traefik-config.yaml

# Wait for Traefik Helm controller

echo "Aștept configurarea Traefik..."

sleep 10

kubectl rollout status \
    deployment/traefik \
    -n kube-system \
    --timeout=300s || true

# ------------------------------------------------------------
# Rancher namespace
# ------------------------------------------------------------

echo "[9/12] Pregătesc Rancher..."

kubectl create namespace cattle-system \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Rancher TLS secret
#
# Rancher expects:
# cattle-system/tls-rancher-ingress
#
# We use the same wildcard certificate.
# ------------------------------------------------------------

kubectl -n cattle-system create secret tls tls-rancher-ingress \
    --cert="${K3S_DIR}/cert/wildcard.crt" \
    --key="${K3S_DIR}/cert/wildcard.key" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Install Helm
# ------------------------------------------------------------

echo "[10/12] Verific Helm..."

if ! command -v helm >/dev/null 2>&1; then

    echo "Helm nu este instalat. Instalez Helm..."

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | bash

fi

helm version

# ------------------------------------------------------------
# Rancher repository
# ------------------------------------------------------------

helm repo add "${RANCHER_REPO}" "${RANCHER_REPO_URL}" \
    --force-update

helm repo update

# ------------------------------------------------------------
# Rancher installation
#
# We use our own certificate:
#
# ingress.tls.source=secret
#
# and the Rancher ingress controller will be Traefik.
# ------------------------------------------------------------

echo "[11/12] Instalez Rancher..."

cat > "${K3S_DIR}/rancher/values.yaml" <<EOF
hostname: ${RANCHER_HOSTNAME}

bootstrapPassword: ${RANCHER_PASSWORD}

replicas: 1

ingress:
  tls:
    source: secret
  ingressClassName: traefik

privateCA: false
EOF

helm upgrade --install rancher \
    "${RANCHER_REPO}/rancher" \
    --namespace cattle-system \
    --create-namespace \
    -f "${K3S_DIR}/rancher/values.yaml"

# ------------------------------------------------------------
# Wait for Rancher
# ------------------------------------------------------------

echo
echo "[12/12] Aștept Rancher..."
echo

kubectl -n cattle-system rollout status \
    deployment/rancher \
    --timeout=600s

# ------------------------------------------------------------
# Save information
# ------------------------------------------------------------

cat > "${K3S_DIR}/README.txt" <<EOF
============================================================
K3s + Traefik + Rancher
============================================================

Rancher:
https://${RANCHER_HOSTNAME}

Rancher username:
admin

Rancher bootstrap password:
${RANCHER_PASSWORD}

TLS certificate:
${K3S_DIR}/cert/wildcard.crt

TLS key:
${K3S_DIR}/cert/wildcard.key

Traefik config:
${K3S_DIR}/traefik/traefik-config.yaml

Rancher values:
${K3S_DIR}/rancher/values.yaml

Kubeconfig:
/etc/rancher/k3s/k3s.yaml

Backup kubeconfig:
${K3S_DIR}/k3s.yaml

============================================================
IMPORTANT
============================================================

DNS trebuie să pointeze:

dashboard.aalto.md -> IP-ul serverului K3s

Traefik:
HTTP :80
   |
   +----> HTTPS :443

Rancher:
https://dashboard.aalto.md

============================================================
EOF

echo
echo "============================================================"
echo " INSTALAREA S-A TERMINAT"
echo "============================================================"
echo

echo "K3s:"
kubectl get nodes -o wide

echo
echo "Traefik:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik

echo
echo "Rancher:"
kubectl get pods -n cattle-system

echo
echo "Ingress:"
kubectl get ingress -n cattle-system

echo
echo "============================================================"
echo " Rancher:"
echo " https://${RANCHER_HOSTNAME}"
echo "============================================================"
echo

echo "Configurația este salvată în:"
echo "  ${K3S_DIR}"

echo
echo "NU uita să configurezi DNS:"
echo
echo "  dashboard.aalto.md -> IP_SERVER_K3S"
echo

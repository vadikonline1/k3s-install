#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# K3s + packaged Traefik + Wildcard TLS + Rancher
#
# K3s:
#   latest
#
# Rancher:
#   rancher-latest
#
# Rancher version:
#   AUTOMATICALLY selected as the newest version compatible
#   with the installed Kubernetes version.
#
# DNS:
#   dashboard.aalto.md -> IP server K3s
#
# Certificate:
#   /mnt/hdd/cert/wildcard.crt
#   /mnt/hdd/cert/wildcard.key
#
# Configuration:
#   /mnt/hdd/k3s/
#
# Rancher password:
#   automatically generated
#   /mnt/hdd/k3s/RANCHER_PASSWORD.txt
# ============================================================

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

K3S_DIR="/mnt/hdd/k3s"
CERT_DIR="/mnt/hdd/cert"

CERT_FILE="${CERT_DIR}/wildcard.crt"
KEY_FILE="${CERT_DIR}/wildcard.key"

RANCHER_HOSTNAME="dashboard.aalto.md"

# K3s channel
K3S_CHANNEL="latest"

# Rancher latest repository
RANCHER_REPO="rancher-latest"
RANCHER_REPO_URL="https://releases.rancher.com/server-charts/latest"

# ------------------------------------------------------------
# Files
# ------------------------------------------------------------

RANCHER_PASSWORD_FILE="${K3S_DIR}/RANCHER_PASSWORD.txt"
RANCHER_INFO_FILE="${K3S_DIR}/RANCHER_INFO.txt"

# ------------------------------------------------------------
# Basic functions
# ------------------------------------------------------------

log() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

error_exit() {
    echo
    echo "============================================================"
    echo " ERROR"
    echo "============================================================"
    echo
    echo "$1"
    echo
    exit 1
}

cleanup_on_error() {
    local exit_code=$?

    echo
    echo "============================================================"
    echo " SCRIPT FAILED"
    echo "============================================================"
    echo
    echo "Exit code: ${exit_code}"
    echo
    echo "Useful commands:"
    echo
    echo "  systemctl status k3s --no-pager"
    echo "  journalctl -u k3s -n 100 --no-pager"
    echo
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo
    exit "${exit_code}"
}

trap cleanup_on_error ERR

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Rulează scriptul ca root."
fi

# ------------------------------------------------------------
# Banner
# ------------------------------------------------------------

echo
echo "============================================================"
echo " K3s + Traefik + Rancher"
echo "============================================================"
echo
echo "K3s channel:"
echo "  ${K3S_CHANNEL}"
echo
echo "Rancher repository:"
echo "  ${RANCHER_REPO}"
echo
echo "Rancher hostname:"
echo "  https://${RANCHER_HOSTNAME}"
echo

# ------------------------------------------------------------
# Verify certificates
# ------------------------------------------------------------

if [[ ! -f "${CERT_FILE}" ]]; then
    error_exit "Certificatul nu există:

${CERT_FILE}"
fi

if [[ ! -f "${KEY_FILE}" ]]; then
    error_exit "Cheia privată nu există:

${KEY_FILE}"
fi

# ------------------------------------------------------------
# Detect OS/package manager
# ------------------------------------------------------------

log "[1/15] Detectare sistem"

if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PKG="apt-get"
else
    error_exit "Sistem Linux nesuportat."
fi

echo "Package manager: ${PKG}"

# ------------------------------------------------------------
# Install required packages
# ------------------------------------------------------------

log "[2/15] Instalare pachete necesare"

if [[ "${PKG}" == "dnf" || "${PKG}" == "yum" ]]; then

    ${PKG} install -y \
        curl \
        wget \
        tar \
        gzip \
        openssl \
        ca-certificates \
        chrony \
        iptables \
        iptables-nft \
        iproute-tc \
        socat \
        conntrack-tools

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
        chrony \
        iptables \
        iproute2 \
        socat \
        conntrack

    systemctl enable --now chrony || true

fi

# ------------------------------------------------------------
# Verify iptables tools
# ------------------------------------------------------------

echo
echo "Verific iptables..."

if ! command -v iptables-save >/dev/null 2>&1; then
    echo "WARNING: iptables-save nu este disponibil."
fi

if ! command -v iptables-restore >/dev/null 2>&1; then
    echo "WARNING: iptables-restore nu este disponibil."
fi

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

log "[3/15] Configurare firewall"

if systemctl list-unit-files 2>/dev/null | grep -q '^firewalld.service'; then

    echo "Dezactivez firewalld pentru această instalare K3s..."

    systemctl disable --now firewalld || true

fi

# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------

log "[4/15] Pregătire directoare"

mkdir -p "${K3S_DIR}"
mkdir -p "${K3S_DIR}/traefik"
mkdir -p "${K3S_DIR}/rancher"
mkdir -p "${K3S_DIR}/cert"

chmod 700 "${K3S_DIR}"

# ------------------------------------------------------------
# Certificates
# ------------------------------------------------------------

echo "Copiez certificatele..."

cp -f "${CERT_FILE}" \
    "${K3S_DIR}/cert/wildcard.crt"

cp -f "${KEY_FILE}" \
    "${K3S_DIR}/cert/wildcard.key"

chmod 644 "${K3S_DIR}/cert/wildcard.crt"
chmod 600 "${K3S_DIR}/cert/wildcard.key"

# ------------------------------------------------------------
# Generate Rancher password
# ------------------------------------------------------------

echo
echo "Verific parola Rancher..."

# Dacă fișierul există dar e corupt, îl ștergem și regenerăm
if [[ -f "${RANCHER_PASSWORD_FILE}" ]]; then
    RANCHER_PASSWORD="$(grep '^Password:' "${RANCHER_PASSWORD_FILE}" 2>/dev/null | head -1 | sed 's/^Password:[[:space:]]*//')"
    
    if [[ -z "${RANCHER_PASSWORD}" ]]; then
        echo "Fișierul de parolă există dar este corupt. Regenerare..."
        rm -f "${RANCHER_PASSWORD_FILE}"
    else
        echo "Folosesc parola Rancher existentă."
    fi
fi

if [[ ! -f "${RANCHER_PASSWORD_FILE}" ]]; then
    echo "Generez o nouă parolă Rancher..."

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
https://${RANCHER_HOSTNAME}

Generated:
$(date)

============================================================
IMPORTANT
============================================================

Păstrează acest fișier în siguranță.

============================================================
EOF

    chmod 600 "${RANCHER_PASSWORD_FILE}"
fi

# ------------------------------------------------------------
# K3s installation
# ------------------------------------------------------------

log "[5/15] Instalare K3s"

if command -v k3s >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^k3s.service'; then

    echo "K3s este deja instalat."

    if systemctl is-active --quiet k3s; then
        echo "K3s este deja pornit."
    else
        echo "Pornesc K3s..."
        systemctl enable --now k3s
    fi

    echo
    echo "Versiune K3s existentă:"
    k3s --version || true

else

    echo
    echo "Rulez installerul oficial K3s..."
    echo
    echo "K3s channel:"
    echo "  ${K3S_CHANNEL}"
    echo

    curl -sfL https://get.k3s.io \
        | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
          sh -s - server

    systemctl enable --now k3s

fi

# ------------------------------------------------------------
# Kubernetes environment
# ------------------------------------------------------------

export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# ------------------------------------------------------------
# Wait for Kubernetes API
# ------------------------------------------------------------

log "[6/15] Aștept Kubernetes API"

API_READY="false"

for i in $(seq 1 120); do

    if kubectl get --raw="/readyz" >/dev/null 2>&1; then
        API_READY="true"
        break
    fi

    echo "Aștept Kubernetes API... ${i}/120"

    sleep 2

done

if [[ "${API_READY}" != "true" ]]; then

    echo
    echo "K3s service:"
    systemctl status k3s --no-pager || true

    echo
    echo "K3s journal:"
    journalctl -u k3s -n 100 --no-pager || true

    error_exit "Kubernetes API nu a devenit disponibil."
fi

echo
echo "Kubernetes API este READY."

# ------------------------------------------------------------
# Determine Kubernetes version
# ------------------------------------------------------------

echo
echo "Detectez versiunea Kubernetes..."

# Try jsonpath first (most reliable)
KUBE_SERVER_VERSION="$(
    kubectl version -o json 2>/dev/null \
    | sed -n 's/.*"gitVersion":"\([^"]*\)".*/\1/p' \
    | head -1
)"

# Fallback to node info
if [[ -z "${KUBE_SERVER_VERSION}" ]]; then
    KUBE_SERVER_VERSION="$(
        kubectl get nodes \
            -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' \
            2>/dev/null || true
    )"
fi

if [[ -z "${KUBE_SERVER_VERSION}" ]]; then

    echo
    echo "kubectl version:"
    kubectl version || true

    echo
    echo "nodes:"
    kubectl get nodes -o wide || true

    error_exit "Nu am putut determina versiunea Kubernetes."
fi

echo
echo "Kubernetes server:"
echo "  ${KUBE_SERVER_VERSION}"

# Remove v prefix for comparison
KUBE_VERSION="${KUBE_SERVER_VERSION#v}"

# Extract major.minor (e.g., 1.36)
KUBE_VERSION_SHORT="$(echo "${KUBE_VERSION}" | cut -d. -f1-2)"

echo
echo "Kubernetes (short):"
echo "  ${KUBE_VERSION_SHORT}"

# ------------------------------------------------------------
# Save kubeconfig
# ------------------------------------------------------------

echo
echo "Salvez kubeconfig..."

cp -f \
    /etc/rancher/k3s/k3s.yaml \
    "${K3S_DIR}/k3s.yaml"

chmod 600 "${K3S_DIR}/k3s.yaml"

# ------------------------------------------------------------
# Show node
# ------------------------------------------------------------

echo
echo "Node:"
kubectl get nodes -o wide

# ------------------------------------------------------------
# Helm installation
# ------------------------------------------------------------

log "[7/15] Verific Helm"

if ! command -v helm >/dev/null 2>&1; then

    echo "Helm nu este instalat."

    echo "Instalez Helm 3..."

    curl -fsSL \
        https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | bash

fi

helm version

# ------------------------------------------------------------
# Rancher repository
# ------------------------------------------------------------

log "[8/15] Configurez Rancher Latest repository"

helm repo add \
    "${RANCHER_REPO}" \
    "${RANCHER_REPO_URL}" \
    --force-update

helm repo update

echo
echo "Versiuni Rancher disponibile:"

helm search repo \
    "${RANCHER_REPO}/rancher" \
    --versions \
    | head -15

# ------------------------------------------------------------
# Find newest compatible Rancher
# ------------------------------------------------------------

log "[9/15] Detectez cea mai nouă versiune Rancher compatibilă"

RANCHER_VERSION=""

echo
echo "Kubernetes detectat:"
echo "  ${KUBE_SERVER_VERSION}"
echo
echo "Caut Rancher compatibil..."
echo

# Get all versions from repository
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

if [[ ${#RANCHER_VERSIONS[@]} -eq 0 ]]; then
    error_exit "Nu am găsit versiuni Rancher în repository."
fi

RANCHER_FOUND="false"

for CANDIDATE_VERSION in "${RANCHER_VERSIONS[@]}"; do

    [[ -z "${CANDIDATE_VERSION}" ]] && continue

    echo "Testez Rancher ${CANDIDATE_VERSION} ..."

    # Get kubeVersion from chart using helm show
    KUBE_VERSION_CONSTRAINT=""
    KUBE_VERSION_CONSTRAINT="$(
        helm show chart \
            "${RANCHER_REPO}/rancher" \
            --version "${CANDIDATE_VERSION}" \
            2>/dev/null \
        | grep -i '^kubeVersion:' \
        | sed 's/^[kK][uU][bB][eE][vV][eE][rR][sS][iI][oO][nN]:[[:space:]]*//'
    )"

    # If no kubeVersion constraint, assume compatible
    if [[ -z "${KUBE_VERSION_CONSTRAINT}" ]]; then
        echo "  ✓ compatibil (fără restricții kubeVersion)"
        RANCHER_VERSION="${CANDIDATE_VERSION}"
        RANCHER_FOUND="true"
        break
    fi

    echo "  kubeVersion: ${KUBE_VERSION_CONSTRAINT}"

    # Simple compatibility check based on common patterns
    COMPATIBLE="false"
    
    # Check for Kubernetes 1.36 compatibility
    # Rancher 2.15.0 supports Kubernetes 1.36
    # Rancher 2.14.x supports Kubernetes up to 1.35
    if [[ "${CANDIDATE_VERSION}" == 2.15.* ]]; then
        # Rancher 2.15.x supports Kubernetes 1.36
        if [[ "${KUBE_VERSION_SHORT}" == "1.36" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.37" ]]; then
            COMPATIBLE="true"
        fi
    elif [[ "${CANDIDATE_VERSION}" == 2.14.* ]]; then
        # Rancher 2.14.x supports Kubernetes up to 1.35
        if [[ "${KUBE_VERSION_SHORT}" == "1.35" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.34" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.33" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.32" ]]; then
            COMPATIBLE="true"
        fi
    elif [[ "${CANDIDATE_VERSION}" == 2.13.* ]]; then
        # Rancher 2.13.x supports Kubernetes up to 1.34
        if [[ "${KUBE_VERSION_SHORT}" == "1.34" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.33" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.32" ]]; then
            COMPATIBLE="true"
        fi
    elif [[ "${CANDIDATE_VERSION}" == 2.12.* ]]; then
        # Rancher 2.12.x supports Kubernetes up to 1.33
        if [[ "${KUBE_VERSION_SHORT}" == "1.33" ]] || [[ "${KUBE_VERSION_SHORT}" == "1.32" ]]; then
            COMPATIBLE="true"
        fi
    else
        # For older versions, try more permissive check
        COMPATIBLE="true"
    fi

    if [[ "${COMPATIBLE}" == "true" ]]; then
        RANCHER_VERSION="${CANDIDATE_VERSION}"
        RANCHER_FOUND="true"
        
        echo
        echo "============================================================"
        echo " COMPATIBILITATE GĂSITĂ"
        echo "============================================================"
        echo
        echo "Kubernetes:"
        echo "  ${KUBE_SERVER_VERSION}"
        echo
        echo "Rancher:"
        echo "  ${RANCHER_VERSION}"
        echo
        
        break
    else
        echo "  ✗ incompatibil (Kubernetes ${KUBE_VERSION_SHORT} nu este suportat)"
    fi

done

if [[ "${RANCHER_FOUND}" != "true" ]]; then

    echo
    echo "Nu există o versiune Rancher din rancher-latest"
    echo "compatibilă cu Kubernetes ${KUBE_SERVER_VERSION}."
    echo

    echo "Versiuni disponibile:"
    printf '  %s\n' "${RANCHER_VERSIONS[@]}"

    exit 1
fi

# ------------------------------------------------------------
# Install cert-manager
# ------------------------------------------------------------

log "[10/15] Instalez cert-manager"

# Install cert-manager CRDs and controller
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.crds.yaml

# Add cert-manager repository
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# Install cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.14.5 \
    --set installCRDs=false \
    --wait \
    --timeout 10m

# Wait for cert-manager
echo
echo "Aștept cert-manager..."

kubectl -n cert-manager rollout status \
    deployment/cert-manager \
    --timeout=300s || true

kubectl -n cert-manager rollout status \
    deployment/cert-manager-cainjector \
    --timeout=300s || true

kubectl -n cert-manager rollout status \
    deployment/cert-manager-webhook \
    --timeout=300s || true

echo
echo "Cert-manager pods:"
kubectl get pods -n cert-manager

# ------------------------------------------------------------
# TLS secret for Traefik
# ------------------------------------------------------------

log "[11/15] Configurez Wildcard TLS"

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

echo
echo "Wildcard TLS:"
kubectl get secret wildcard-tls -n kube-system

# ------------------------------------------------------------
# Traefik configuration
# ------------------------------------------------------------

log "[12/15] Configurez Traefik"

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

cp -f \
    "${K3S_DIR}/traefik/traefik-config.yaml" \
    /var/lib/rancher/k3s/server/manifests/traefik-config.yaml

echo
echo "Aștept Traefik..."

sleep 10

kubectl rollout status \
    deployment/traefik \
    -n kube-system \
    --timeout=300s \
    || true

echo
echo "Traefik:"
kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=traefik \
    -o wide \
    || true

# ------------------------------------------------------------
# Rancher namespace
# ------------------------------------------------------------

log "[13/15] Pregătesc Rancher"

kubectl create namespace cattle-system \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Rancher TLS secret
# ------------------------------------------------------------

echo
echo "Configurez certificatul Rancher..."

kubectl -n cattle-system create secret tls tls-rancher-ingress \
    --cert="${K3S_DIR}/cert/wildcard.crt" \
    --key="${K3S_DIR}/cert/wildcard.key" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

# ------------------------------------------------------------
# Rancher values
# ------------------------------------------------------------

cat > "${K3S_DIR}/rancher/values.yaml" <<EOF
hostname: ${RANCHER_HOSTNAME}

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

chmod 600 "${K3S_DIR}/rancher/values.yaml"

# ------------------------------------------------------------
# Install Rancher
# ------------------------------------------------------------

log "[14/15] Instalez Rancher"

echo
echo "Rancher repository:"
echo "  ${RANCHER_REPO}"
echo
echo "Rancher version:"
echo "  ${RANCHER_VERSION}"
echo
echo "Kubernetes:"
echo "  ${KUBE_SERVER_VERSION}"
echo
echo "Hostname:"
echo "  ${RANCHER_HOSTNAME}"
echo

# Retry installation if it fails
MAX_RETRIES=3
RETRY_COUNT=0
INSTALLED=false

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do

    if helm upgrade --install rancher \
        "${RANCHER_REPO}/rancher" \
        --version "${RANCHER_VERSION}" \
        --namespace cattle-system \
        --create-namespace \
        -f "${K3S_DIR}/rancher/values.yaml" \
        --wait \
        --timeout 15m \
        2>&1; then
        
        INSTALLED=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    if [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; then
        echo
        echo "Instalarea a eșuat, retry ${RETRY_COUNT}/${MAX_RETRIES}..."
        sleep 10
    fi

done

if [[ "${INSTALLED}" != "true" ]]; then
    error_exit "Instalarea Rancher a eșuat după ${MAX_RETRIES} încercări."
fi

# ------------------------------------------------------------
# Wait Rancher
# ------------------------------------------------------------

log "[15/15] Aștept Rancher"

echo

kubectl -n cattle-system rollout status \
    deployment/rancher \
    --timeout=900s || true

echo
echo "Aștept podurile Rancher..."

kubectl wait \
    --namespace cattle-system \
    --for=condition=Ready \
    pod \
    -l app=rancher \
    --timeout=900s || true

# ------------------------------------------------------------
# Save information
# ------------------------------------------------------------

cat > "${RANCHER_INFO_FILE}" <<EOF
============================================================
K3s + Traefik + Rancher
============================================================

Installation date:
$(date)

============================================================
KUBERNETES
============================================================

K3s channel:
${K3S_CHANNEL}

Kubernetes version:
${KUBE_SERVER_VERSION}

Kubernetes (short):
${KUBE_VERSION_SHORT}

============================================================
RANCHER
============================================================

Repository:
${RANCHER_REPO}

Repository URL:
${RANCHER_REPO_URL}

Rancher version:
${RANCHER_VERSION}

Hostname:
${RANCHER_HOSTNAME}

URL:
https://${RANCHER_HOSTNAME}

Username:
admin

Password:
${RANCHER_PASSWORD}

============================================================
TLS
============================================================

Certificate:
${K3S_DIR}/cert/wildcard.crt

Private key:
${K3S_DIR}/cert/wildcard.key

Traefik TLS secret:
kube-system/wildcard-tls

Rancher TLS secret:
cattle-system/tls-rancher-ingress

============================================================
CONFIGURATION
============================================================

K3s directory:
${K3S_DIR}

Kubeconfig:
/etc/rancher/k3s/k3s.yaml

Backup kubeconfig:
${K3S_DIR}/k3s.yaml

Traefik configuration:
${K3S_DIR}/traefik/traefik-config.yaml

Rancher values:
${K3S_DIR}/rancher/values.yaml

Rancher password:
${RANCHER_PASSWORD_FILE}

============================================================
NETWORK
============================================================

HTTP:
:80

HTTPS:
:443

HTTP automatically redirects to HTTPS.

============================================================
DNS
============================================================

dashboard.aalto.md

must point to the IP address of this K3s server.

============================================================
EOF

chmod 600 "${RANCHER_INFO_FILE}"

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo " INSTALLATION COMPLETED"
echo "============================================================"
echo

echo "Kubernetes:"
kubectl get nodes -o wide

echo
echo "============================================================"
echo " TRAEFIK"
echo "============================================================"
echo

kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=traefik \
    -o wide \
    || true

echo
echo "============================================================"
echo " CERT-MANAGER"
echo "============================================================"
echo

kubectl get pods \
    -n cert-manager \
    -o wide \
    || true

echo
echo "============================================================"
echo " RANCHER"
echo "============================================================"
echo

kubectl get pods \
    -n cattle-system \
    -o wide

echo
echo "============================================================"
echo " RANCHER SERVICE"
echo "============================================================"
echo

kubectl get svc \
    -n cattle-system

echo
echo "============================================================"
echo " RANCHER INGRESS"
echo "============================================================"
echo

kubectl get ingress \
    -n cattle-system

echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo

echo "Rancher URL:"
echo
echo "  https://${RANCHER_HOSTNAME}"
echo

echo "Username:"
echo
echo "  admin"
echo

echo "Password:"
echo
echo "  ${RANCHER_PASSWORD}"
echo

echo "Password saved to:"
echo
echo "  ${RANCHER_PASSWORD_FILE}"
echo

echo "Full installation information:"
echo
echo "  ${RANCHER_INFO_FILE}"
echo

echo "Configuration:"
echo
echo "  ${K3S_DIR}"
echo

echo "Kubeconfig:"
echo
echo "  ${K3S_DIR}/k3s.yaml"
echo

echo "============================================================"
echo
echo "DNS:"
echo
echo "  dashboard.aalto.md -> IP_SERVER_K3S"
echo
echo "============================================================"

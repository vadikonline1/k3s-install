#!/bin/bash

# ============================================
# K3s Cluster Manager
# Instalare/Gestiune K3s + Traefik + AdGuard + Vaultwarden + MinIO + Headlamp
# ============================================

set -e

# Culori pentru afișare
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
# FUNCȚII DE AFIȘARE
# ============================================
print_header() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}    $1${NC}"
    echo -e "${BLUE}=========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️ $1${NC}"
}

# ============================================
# FUNCȚII DE INSTALARE COMPONENTE
# ============================================

# --- Instalare K3s (separată) ---
install_k3s_only() {
    print_header "INSTALARE K3S (doar Kubernetes)"
    echo "Data: $(date)"
    echo "Host: $(hostname -f)"
    echo ""

    # Detectare IP automat
    echo "=== Detectare IP automat ==="
    NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi
    echo "✅ IP detectat: $NODE_IP"

    # Instalare pachete necesare
    dnf install -y tar git openssl curl mc nano jq

    # Configurare K3s
    configure_k3s

    # Instalare K3s
    install_k3s

    # Configurare kubectl
    configure_kubectl

    # Instalare Helm
    install_helm

    # Instalare Headlamp (pentru management UI)
    install_headlamp

    print_success "K3s + Helm + Headlamp instalat cu succes!"
    echo ""
    echo "📋 Pentru a verifica:"
    echo "   kubectl get nodes"
    echo "   kubectl get pods -A"
    echo "   Headlamp: https://dashboard.aalto.md"
}

# --- Instalare completă ---
install_full() {
    print_header "INSTALARE COMPLETĂ K3S CLUSTER"
    echo "Data: $(date)"
    echo "Host: $(hostname -f)"
    echo ""

    # Detectare IP automat
    echo "=== Detectare IP automat ==="
    NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi
    echo "✅ IP detectat: $NODE_IP"

    # Instalare pachete necesare
    dnf install -y tar git openssl curl mc nano httpd-tools jq

    # Creare structură directoare
    mkdir -p /mnt/hdd/k8s/{traefik,adguard,vaultwarden,minio,headlamp}
    mkdir -p /mnt/hdd/cert
    cd /mnt/hdd/k8s

    # Generare parole
    generate_credentials

    # Configurare nftables
    configure_nftables
    configure_nftables_backup

    # Configurare K3s
    configure_k3s
    install_k3s
    configure_kubectl
    install_helm

    # Instalare servicii
    install_traefik
    install_adguard
    install_vaultwarden
    install_minio
    install_headlamp
    create_tls_secrets

    # Verificare finală
    final_verification

    print_success "Instalare completă!"
}

# --- Instalare doar Traefik ---
install_traefik_only() {
    print_header "INSTALARE DOAR TRAEFIK DASHBOARD"
    
    # Setează NODE_IP
    NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi
    
    # Refolosește parola dacă există
    if [ -f /root/k8s-credentials.txt ]; then
        TRAEFIK_PASSWORD=$(grep -A1 "TRAEFIK DASHBOARD" /root/k8s-credentials.txt | grep "Password:" | awk '{print $2}' | head -1)
    fi
    if [ -z "$TRAEFIK_PASSWORD" ]; then
        TRAEFIK_PASSWORD=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9!?%=' | head -c 16)
    fi
    
    install_traefik
    print_success "Traefik Dashboard instalat!"
    echo "🔑 Parolă: ${TRAEFIK_PASSWORD}"
    echo "🌐 Accesează: https://traefik.aalto.md/dashboard/"
}

# --- Instalare doar AdGuard ---
install_adguard_only() {
    print_header "INSTALARE DOAR ADGUARD"
    # Setează NODE_IP
    NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi
    install_adguard
    print_success "AdGuard instalat!"
    echo "🌐 Accesează: https://adguard.aalto.md"
}

# --- Instalare doar Vaultwarden ---
install_vaultwarden_only() {
    print_header "INSTALARE DOAR VAULTWARDEN"
    # Setează NODE_IP
    NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi
    
    # Refolosește token-ul dacă există
    if [ -f /root/k8s-credentials.txt ]; then
        VAULTWARDEN_ADMIN_TOKEN=$(grep -A1 "VAULTWARDEN" /root/k8s-credentials.txt | grep "Admin Token:" | awk '{print $3}' | head -1)
    fi
    if [ -z "$VAULTWARDEN_ADMIN_TOKEN" ]; then
        VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    fi
    
    install_vaultwarden
    print_success "Vaultwarden instalat!"
    echo "🔑 Admin Token: ${VAULTWARDEN_ADMIN_TOKEN}"
    echo "🌐 Accesează: https://vault.aalto.md"
}

# --- Instalare doar MinIO ---
install_minio_only() {
    print_header "INSTALARE DOAR MINIO"
    # Setează NODE_IP
    NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi
    
    # Refolosește parola dacă există
    if [ -f /root/k8s-credentials.txt ]; then
        MINIO_PASSWORD=$(grep -A1 "MINIO" /root/k8s-credentials.txt | grep "Root Password:" | awk '{print $3}' | head -1)
    fi
    if [ -z "$MINIO_PASSWORD" ]; then
        MINIO_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
    fi
    
    install_minio
    print_success "MinIO instalat!"
    echo "🔑 Root Password: ${MINIO_PASSWORD}"
    echo "🌐 Accesează: https://minio.aalto.md (API) / https://minio-console.aalto.md (Console)"
}

# ============================================
# FUNCȚIA DE ȘTERGERE COMPLETĂ
# ============================================
uninstall_full() {
    print_header "ȘTERGERE COMPLETĂ K3S CLUSTER"
    
    read -p "⚠️  Ești sigur că vrei să ștergi complet clusterul? (da/nu): " confirm
    if [ "$confirm" != "da" ]; then
        print_info "Operațiune anulată."
        return
    fi

    echo "=== Ștergere K3s și toate resursele ==="
    
    sudo systemctl stop k3s 2>/dev/null || true
    sudo systemctl stop nftables 2>/dev/null || true
    
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        sudo /usr/local/bin/k3s-uninstall.sh || true
    fi
    
    sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /mnt/hdd/k8s /mnt/hdd/cert /root/k8s-credentials.txt /root/headlamp-token.txt
    sudo rm -f /etc/nftables/nftables.conf /etc/sysconfig/nftables.conf
    sudo rm -f /usr/local/bin/nftables-backup.sh
    
    sudo systemctl reset-failed k3s.service 2>/dev/null || true
    
    sudo crontab -l 2>/dev/null | grep -v "nftables-backup.sh" | sudo crontab - 2>/dev/null || true
    
    print_success "Cluster șters complet. Serverul este curat."
}

# ============================================
# FUNCȚII AUXILIARE
# ============================================

generate_credentials() {
    echo "=== Gestionare credențiale ==="
    if [ -f /root/k8s-credentials.txt ]; then
        print_info "Fișierul cu credențiale există. Se reutilizează parolele existente..."
        TRAEFIK_PASSWORD=$(grep -A1 "TRAEFIK DASHBOARD" /root/k8s-credentials.txt | grep "Password:" | awk '{print $2}' | head -1)
        VAULTWARDEN_ADMIN_TOKEN=$(grep -A1 "VAULTWARDEN" /root/k8s-credentials.txt | grep "Admin Token:" | awk '{print $3}' | head -1)
        MINIO_PASSWORD=$(grep -A1 "MINIO" /root/k8s-credentials.txt | grep "Root Password:" | awk '{print $3}' | head -1)
        HEADLAMP_TOKEN=$(grep -A1 "HEADLAMP" /root/k8s-credentials.txt | grep "Token:" | awk '{print $2}' | head -1)

        [ -z "$TRAEFIK_PASSWORD" ] && TRAEFIK_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
        [ -z "$VAULTWARDEN_ADMIN_TOKEN" ] && VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
        [ -z "$MINIO_PASSWORD" ] && MINIO_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
        [ -z "$HEADLAMP_TOKEN" ] && HEADLAMP_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    else
        print_info "Se generează parole noi..."
        TRAEFIK_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
        VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
        MINIO_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
        HEADLAMP_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    fi

    cat > /root/k8s-credentials.txt << EOF2
===========================================
   KUBERNETES CLUSTER CREDENTIALS
   Data generare: $(date '+%Y-%m-%d %H:%M:%S')
   Hostname: $(hostname -f)
   Node IP: ${NODE_IP}
===========================================

=== TRAEFIK DASHBOARD ===
URL: https://traefik.aalto.md
Username: admin
Password: ${TRAEFIK_PASSWORD}

=== HEADLAMP DASHBOARD ===
URL: https://dashboard.aalto.md
Token: ${HEADLAMP_TOKEN}

=== ADGUARD ===
URL: https://adguard.aalto.md
(Configurare inițială prin interfața web)

=== VAULTWARDEN ===
URL: https://vault.aalto.md
Admin Token: ${VAULTWARDEN_ADMIN_TOKEN}
(Configurare primul utilizator prin interfața web)

=== MINIO ===
API URL: https://minio.aalto.md
Console URL: https://minio-console.aalto.md
Root User: admin
Root Password: ${MINIO_PASSWORD}

===========================================
FISIER: /root/k8s-credentials.txt
===========================================
EOF2

    chmod 600 /root/k8s-credentials.txt
    print_success "Credențialele au fost salvate în /root/k8s-credentials.txt"
}

configure_k3s() {
    if [ ! -f /etc/rancher/k3s/config.yaml ] || ! grep -q "$NODE_IP" /etc/rancher/k3s/config.yaml 2>/dev/null; then
        echo "=== Configurare K3s ==="
        sudo mkdir -p /etc/rancher/k3s
        sudo tee /etc/rancher/k3s/config.yaml > /dev/null << EOF6
# K3s Server Configuration
node-ip: ${NODE_IP}
node-external-ip: ${NODE_IP}
https-listen-port: 6443
write-kubeconfig-mode: "0600"
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
flannel-backend: vxlan
disable:
  - traefik
tls-san:
  - "${NODE_IP}"
EOF6
    fi
}

install_k3s() {
    if ! command -v k3s &> /dev/null; then
        echo "=== Instalare K3s ==="
        curl -sfL https://get.k3s.io | sh -
        print_success "K3s instalat"
        echo "=== Așteptăm pornirea K3s (30 secunde) ==="
        sleep 30
    else
        print_info "K3s este deja instalat - se sare peste instalare"
        sudo systemctl restart k3s
        sleep 15
    fi
}

configure_kubectl() {
    echo "=== Configurare kubectl ==="
    export PATH=$PATH:/usr/local/bin
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl nu a fost găsit. Verificați instalarea K3s."
        exit 1
    fi
    print_success "kubectl găsit: $(which kubectl)"

    sudo sed -i "s/127.0.0.1/${NODE_IP}/g" /etc/rancher/k3s/k3s.yaml 2>/dev/null || true
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true
    sudo chown $(id -u):$(id -g) ~/.kube/config 2>/dev/null || true
    chmod 600 ~/.kube/config 2>/dev/null || true
    export KUBECONFIG=~/.kube/config
    print_success "kubectl configurat"

    echo "=== Verificare K3s ==="
    sudo systemctl status k3s --no-pager || true
    kubectl get nodes -o wide --insecure-skip-tls-verify 2>/dev/null || echo "⏳ K3s încă nu este complet pornit..."
}

install_helm() {
    if ! command -v helm &> /dev/null; then
        echo "=== Instalare Helm ==="
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        print_success "Helm instalat"
    else
        print_info "Helm este deja instalat: $(helm version --short)"
    fi
}

install_traefik() {
    echo "=== Instalare Traefik Dashboard ==="
    
    helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
    helm repo update

    kubectl create namespace kube-system 2>/dev/null || true

    if [ -f /mnt/hdd/cert/wildcard.crt ] && [ -f /mnt/hdd/cert/wildcard.key ]; then
        kubectl create secret tls traefik-dashboard-tls \
            --cert=/mnt/hdd/cert/wildcard.crt \
            --key=/mnt/hdd/cert/wildcard.key \
            -n kube-system 2>/dev/null || print_info "Secretul TLS există deja"
    fi

    sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
    sudo tee /var/lib/rancher/k3s/server/manifests/traefik-dashboard-config.yaml << 'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    api:
      dashboard: true
      insecure: false
    logs:
      general:
        level: INFO
      access:
        enabled: true
EOF

    kubectl apply -f /var/lib/rancher/k3s/server/manifests/traefik-dashboard-config.yaml 2>/dev/null || true
    kubectl rollout status deployment/traefik -n kube-system 2>/dev/null || true

    htpasswd -nbB admin "${TRAEFIK_PASSWORD}" > /tmp/dashboard-auth.txt
    kubectl create secret generic traefik-dashboard-auth \
        --from-file=users=/tmp/dashboard-auth.txt \
        -n kube-system 2>/dev/null || true
    rm /tmp/dashboard-auth.txt

    cat > /tmp/traefik-middleware.yaml << 'EOF'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: dashboard-auth
  namespace: kube-system
spec:
  basicAuth:
    secret: traefik-dashboard-auth
    removeHeader: true
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: dashboard-ip-allowlist
  namespace: kube-system
spec:
  ipAllowList:
    sourceRange:
      - "10.0.0.0/8"
      - "172.16.0.0/12"
      - "192.168.0.0/16"
      - "127.0.0.1/32"
EOF
    kubectl apply -f /tmp/traefik-middleware.yaml

    cat > /tmp/traefik-ingressroute.yaml << 'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard-https
  namespace: kube-system
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`traefik.aalto.md`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      middlewares:
        - name: dashboard-auth
          namespace: kube-system
        - name: dashboard-ip-allowlist
          namespace: kube-system
      services:
        - name: api@internal
          kind: TraefikService
  tls:
    secretName: traefik-dashboard-tls
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: https-redirect
  namespace: kube-system
spec:
  redirectScheme:
    scheme: https
    permanent: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard-http
  namespace: kube-system
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`traefik.aalto.md`)
      middlewares:
        - name: https-redirect
          namespace: kube-system
      services:
        - name: api@internal
          kind: TraefikService
EOF
    kubectl apply -f /tmp/traefik-ingressroute.yaml

    print_success "Traefik configurat în namespace-ul kube-system"
}

install_adguard() {
    echo "=== Instalare AdGuard ==="
    kubectl create namespace adguard 2>/dev/null || true
    cat > /mnt/hdd/k8s/adguard/adguard-deploy.yaml << 'EOF8'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adguard
  namespace: adguard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adguard
  template:
    metadata:
      labels:
        app: adguard
    spec:
      containers:
        - name: adguard
          image: adguard/adguardhome:latest
          ports:
            - containerPort: 53
              protocol: UDP
            - containerPort: 53
              protocol: TCP
            - containerPort: 80
            - containerPort: 443
            - containerPort: 853
              protocol: TCP
          volumeMounts:
            - name: certificates
              mountPath: /mnt/hdd/cert
              readOnly: true
      volumes:
        - name: certificates
          hostPath:
            path: /mnt/hdd/cert
---
apiVersion: v1
kind: Service
metadata:
  name: adguard
  namespace: adguard
spec:
  type: ClusterIP
  ports:
    - name: dns-udp
      port: 53
      protocol: UDP
      targetPort: 53
    - name: dns-tcp
      port: 53
      protocol: TCP
      targetPort: 53
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
    - name: dot
      port: 853
      protocol: TCP
      targetPort: 853
  selector:
    app: adguard
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: adguard-admin
  namespace: adguard
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`adguard.aalto.md\`)
      services:
        - name: adguard
          port: 80
  tls:
    secretName: wildcard-tls
EOF8
    kubectl apply -f /mnt/hdd/k8s/adguard/adguard-deploy.yaml
    print_success "AdGuard instalat"
}

install_vaultwarden() {
    echo "=== Instalare Vaultwarden ==="
    kubectl create namespace vaultwarden 2>/dev/null || true
    cat > /mnt/hdd/k8s/vaultwarden/vaultwarden-deploy.yaml << EOF9
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vaultwarden
  namespace: vaultwarden
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vaultwarden
  template:
    metadata:
      labels:
        app: vaultwarden
    spec:
      containers:
        - name: vaultwarden
          image: vaultwarden/server:latest
          env:
            - name: DOMAIN
              value: "https://vault.aalto.md"
            - name: ROCKET_PORT
              value: "80"
            - name: WEBSOCKET_ENABLED
              value: "true"
            - name: WEBSOCKET_PORT
              value: "3012"
            - name: SIGNUPS_ALLOWED
              value: "true"
            - name: ADMIN_TOKEN
              value: "${VAULTWARDEN_ADMIN_TOKEN}"
          ports:
            - containerPort: 80
            - containerPort: 3012
---
apiVersion: v1
kind: Service
metadata:
  name: vaultwarden
  namespace: vaultwarden
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: websocket
      port: 3012
      targetPort: 3012
  selector:
    app: vaultwarden
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: vaultwarden
  namespace: vaultwarden
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`vault.aalto.md\`)
      services:
        - name: vaultwarden
          port: 80
    - kind: Rule
      match: Host(\`vault.aalto.md\`) && PathPrefix(\`/notifications/hub\`)
      services:
        - name: vaultwarden
          port: 3012
  tls:
    secretName: wildcard-tls
EOF9
    kubectl apply -f /mnt/hdd/k8s/vaultwarden/vaultwarden-deploy.yaml
    print_success "Vaultwarden instalat"
}

install_minio() {
    echo "=== Instalare MinIO ==="
    kubectl create namespace minio 2>/dev/null || true
    cat > /mnt/hdd/k8s/minio/minio-deploy.yaml << EOF10
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args:
            - server
            - /data
            - --console-address
            - ":9001"
          env:
            - name: MINIO_ROOT_USER
              value: "admin"
            - name: MINIO_ROOT_PASSWORD
              value: "${MINIO_PASSWORD}"
          ports:
            - containerPort: 9000
            - containerPort: 9001
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  type: ClusterIP
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
  selector:
    app: minio
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: minio-api
  namespace: minio
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`minio.aalto.md\`)
      services:
        - name: minio
          port: 9000
  tls:
    secretName: wildcard-tls
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: minio-console
  namespace: minio
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`minio-console.aalto.md\`)
      services:
        - name: minio
          port: 9001
  tls:
    secretName: wildcard-tls
EOF10
    kubectl apply -f /mnt/hdd/k8s/minio/minio-deploy.yaml
    print_success "MinIO instalat"
}

install_headlamp() {
    echo "=== Instalare Headlamp ==="
    helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ 2>/dev/null || true
    helm repo update
    
    if helm list -n kube-system | grep -q my-headlamp; then
        print_info "Headlamp există deja"
    else
        helm install my-headlamp headlamp/headlamp --namespace kube-system 2>/dev/null || true
    fi

    cat > /mnt/hdd/k8s/headlamp/headlamp-ingress.yaml << 'EOF11'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
  namespace: kube-system
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`dashboard.aalto.md`)
      services:
        - name: my-headlamp
          port: 80
  tls:
    secretName: wildcard-tls
EOF11
    kubectl apply -f /mnt/hdd/k8s/headlamp/headlamp-ingress.yaml
    print_success "Headlamp instalat"
}

configure_nftables() {
    if ! grep -q "WHITELIST_DMZ" /etc/nftables/nftables.conf 2>/dev/null; then
        echo "=== Configurare nftables ==="
        sudo tee /etc/nftables/nftables.conf > /dev/null <<'EOF3'
#!/usr/sbin/nft -f

flush ruleset

define WHITELIST_DMZ = {
        194.33.42.0/24,
        83.218.219.0/24,
        93.113.159.0/24
}

table inet filter {

    chain input {
        type filter hook input priority filter;
        policy drop;

        ct state established,related accept
        iifname "lo" accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        tcp dport 22 accept comment "SSH"
        tcp dport 3004 ip saddr != { 127.0.0.1, 192.168.100.0/24, 192.168.88.0/24, $WHITELIST_DMZ } drop
        tcp dport { 80, 8080-9500 } accept comment "HTTP"
        tcp dport 443 accept comment "HTTPS"
        ip saddr 192.168.100.0/24 tcp dport 6443 accept comment "K3s API"
        ip saddr 192.168.100.0/24 udp dport 8472 accept comment "Flannel VXLAN"
        ip saddr 192.168.100.0/24 tcp dport 10250 accept comment "Kubelet"
        ip saddr 192.168.100.0/24 tcp dport { 2379, 2380 } accept comment "K3s embedded etcd"
        ip saddr 192.168.100.0/24 tcp dport 5001 accept comment "K3s Spegel"
        tcp dport 30080 accept comment "Traefik HTTP NodePort"
        tcp dport 30443 accept comment "Traefik HTTPS NodePort"
        tcp dport 30000-32767 accept comment "Kubernetes NodePort TCP"
        udp dport 30000-32767 accept comment "Kubernetes NodePort UDP"
    }

    chain forward {
        type filter hook forward priority filter;
        policy accept;
    }

    chain output {
        type filter hook output priority filter;
        policy accept;
    }
}
EOF3

        sudo tee /etc/sysconfig/nftables.conf > /dev/null <<'EOF4'
include "/etc/nftables/nftables.conf"
EOF4

        sudo nft -c -f /etc/nftables/nftables.conf
        sudo nft -f /etc/nftables/nftables.conf
        sudo nft list ruleset
        sudo systemctl enable nftables
        sudo systemctl restart nftables
        print_success "nftables configurat"
    else
        print_info "nftables este deja configurat - se sare peste"
    fi
}

configure_nftables_backup() {
    if [ ! -f /usr/local/bin/nftables-backup.sh ]; then
        sudo tee /usr/local/bin/nftables-backup.sh > /dev/null << 'EOF5'
#!/bin/bash

BACKUP_DIR="/root/nftables-backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/nftables-backup-$(date +%Y%m%d-%H%M%S).conf"
/usr/sbin/nft list ruleset > "$BACKUP_FILE"
find "$BACKUP_DIR" -type f -name 'nftables-backup-*.conf' -mtime +7 -delete
echo "Backup saved to: $BACKUP_FILE"
EOF5

        sudo chmod +x /usr/local/bin/nftables-backup.sh
        sudo /usr/local/bin/nftables-backup.sh

        if ! sudo crontab -l 2>/dev/null | grep -q "nftables-backup.sh"; then
            (sudo crontab -l 2>/dev/null; echo '0 2 * * * /usr/local/bin/nftables-backup.sh >> /var/log/nftables-backup.log 2>&1') | sudo crontab -
            print_success "Backup nftables adăugat în crontab"
        fi
    else
        print_info "Backup nftables există deja - se sare peste"
    fi
}

create_tls_secrets() {
    echo "=== Creare secrete TLS ==="
    if [ -f /mnt/hdd/cert/wildcard.crt ] && [ -f /mnt/hdd/cert/wildcard.key ]; then
        kubectl create secret tls wildcard-tls \
            --cert=/mnt/hdd/cert/wildcard.crt \
            --key=/mnt/hdd/cert/wildcard.key \
            -n kube-system 2>/dev/null || print_info "Secretul TLS există deja în kube-system"
            
        kubectl create secret tls wildcard-tls \
            --cert=/mnt/hdd/cert/wildcard.crt \
            --key=/mnt/hdd/cert/wildcard.key \
            -n traefik 2>/dev/null || print_info "Secretul TLS există deja în traefik"
    else
        print_error "Certificatele nu au fost găsite în /mnt/hdd/cert/"
    fi
}

final_verification() {
    echo ""
    print_header "VERIFICARE FINALĂ"
    kubectl get pods -A
    echo ""
    kubectl get svc -A
    echo ""
    kubectl get ingressroute -A

    sudo tee -a /etc/hosts << EOF12
${NODE_IP} traefik.aalto.md
${NODE_IP} adguard.aalto.md
${NODE_IP} vault.aalto.md
${NODE_IP} minio.aalto.md
${NODE_IP} minio-console.aalto.md
${NODE_IP} dashboard.aalto.md
EOF12

    echo ""
    print_header "INSTALARE COMPLETĂ!"
    echo ""
    echo "📁 Toate fișierele YAML sunt în: /mnt/hdd/k8s/"
    echo ""
    echo "🔑 CREDENȚIALE:"
    echo "   Fișierul cu toate parolele este în: /root/k8s-credentials.txt"
    echo ""
    echo "🌐 URL-uri de acces:"
    echo "   ✅ Traefik Dashboard: https://traefik.aalto.md/dashboard/"
    echo "   ✅ Headlamp Dashboard: https://dashboard.aalto.md"
    echo "   ✅ AdGuard: https://adguard.aalto.md"
    echo "   ✅ Vaultwarden: https://vault.aalto.md"
    echo "   ✅ MinIO API: https://minio.aalto.md"
    echo "   ✅ MinIO Console: https://minio-console.aalto.md"
    echo ""
    echo "📋 Pentru a vedea toate credențialele:"
    echo "   cat /root/k8s-credentials.txt"
    echo ""
    echo "⚠️  NU UITAȚI:"
    echo "   1. Puneți certificatele în /mnt/hdd/cert/"
    echo "   2. Parola Traefik: ${TRAEFIK_PASSWORD}"
    echo "========================================="
}

# ============================================
# STATUS CLUSTER
# ============================================
show_status() {
    print_header "STATUS CLUSTER"
    echo "=== Noduri ==="
    kubectl get nodes -o wide 2>/dev/null || echo "❌ Clusterul nu rulează"
    echo ""
    echo "=== Pod-uri ==="
    kubectl get pods -A 2>/dev/null || echo "❌ Clusterul nu rulează"
    echo ""
    echo "=== Servicii ==="
    kubectl get svc -A 2>/dev/null || echo "❌ Clusterul nu rulează"
    echo ""
}

show_credentials() {
    if [ -f /root/k8s-credentials.txt ]; then
        print_header "CREDENȚIALE"
        cat /root/k8s-credentials.txt
    else
        print_error "Fișierul /root/k8s-credentials.txt nu există."
    fi
    echo ""
}

# ============================================
# MENIU PRINCIPAL
# ============================================
show_menu() {
    clear
    print_header "K3S CLUSTER MANAGER"
    echo ""
    echo "  0. 🚪 Ieșire"
    echo "  1. 🗑️  Ștergere completă (curăță tot)"
    echo "  2. 📦 Instalare completă (K3s + toate serviciile)"
    echo "  3. ⚙️  Instalare doar K3s (Kubernetes + Helm + Headlamp)"
    echo "  4. 🔧 Instalare doar Traefik Dashboard"
    echo "  5. 🛡️  Instalare doar AdGuard"
    echo "  6. 🔐 Instalare doar Vaultwarden"
    echo "  7. 💾 Instalare doar MinIO"
    echo "  8. 📊 Status cluster"
    echo "  9. 🔑 Afișează credențiale"
    echo ""
    echo -n "Alege o opțiune [0-9]: "
}

while true; do
    show_menu
    read -r choice
    case $choice in
        0)
            print_info "La revedere!"
            exit 0
            ;;
        1)
            uninstall_full
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        2)
            install_full
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        3)
            install_k3s_only
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        4)
            install_traefik_only
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        5)
            install_adguard_only
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        6)
            install_vaultwarden_only
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        7)
            install_minio_only
            echo ""
            read -p "Apasă Enter pentru a continua..."
            ;;
        8)
            show_status
            read -p "Apasă Enter pentru a continua..."
            ;;
        9)
            show_credentials
            read -p "Apasă Enter pentru a continua..."
            ;;
        *)
            print_error "Opțiune invalidă. Alege 0-9."
            sleep 2
            ;;
    esac
done


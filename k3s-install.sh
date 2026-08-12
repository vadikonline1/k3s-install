#!/bin/bash

# ============================================
# K3s + Traefik + AdGuard + Vaultwarden + MinIO + Headlamp
# Smart Installation Script - works for fresh installs and updates
# ============================================

set -e

echo "=== START INSTALARE K3S CLUSTER ==="
echo "Data: $(date)"
echo "Host: $(hostname -f)"
echo ""

# 0. Detectare IP automat
echo "=== Detectare IP automat ==="
NODE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(hostname -I | awk '{print $1}')
fi
echo "✅ IP detectat: $NODE_IP"

# 1. Instalare pachete necesare
dnf install -y tar git openssl curl mc nano

# 2. Creare structură directoare
mkdir -p /mnt/hdd/k8s/{traefik,adguard,vaultwarden,minio,headlamp}
mkdir -p /mnt/hdd/cert
cd /mnt/hdd/k8s

# 3. Generare sau reutilizare parole
echo "=== Gestionare credențiale ==="
if [ -f /root/k8s-credentials.txt ]; then
    echo "ℹ️ Fișierul cu credențiale există. Se reutilizează parolele existente..."
    TRAEFIK_PASSWORD=$(grep -A1 "TRAEFIK DASHBOARD" /root/k8s-credentials.txt | grep "Password:" | awk '{print $2}' | head -1)
    VAULTWARDEN_ADMIN_TOKEN=$(grep -A1 "VAULTWARDEN" /root/k8s-credentials.txt | grep "Admin Token:" | awk '{print $3}' | head -1)
    MINIO_PASSWORD=$(grep -A1 "MINIO" /root/k8s-credentials.txt | grep "Root Password:" | awk '{print $3}' | head -1)
    HEADLAMP_TOKEN=$(grep -A1 "HEADLAMP" /root/k8s-credentials.txt | grep "Token:" | awk '{print $2}' | head -1)
    
    # Dacă lipsește vreo parolă, generează una nouă
    [ -z "$TRAEFIK_PASSWORD" ] && TRAEFIK_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
    [ -z "$VAULTWARDEN_ADMIN_TOKEN" ] && VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    [ -z "$MINIO_PASSWORD" ] && MINIO_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
    [ -z "$HEADLAMP_TOKEN" ] && HEADLAMP_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
else
    echo "ℹ️ Se generează parole noi..."
    TRAEFIK_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
    VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    MINIO_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!?%=' | head -c 32)
    HEADLAMP_TOKEN=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
fi

# 4. Salvare/suprascriere parole în /root/
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
echo "✅ Credențialele au fost salvate în /root/k8s-credentials.txt"

# 5. Configurare nftables (doar dacă nu există)
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
    echo "✅ nftables configurat"
else
    echo "ℹ️ nftables este deja configurat - se sare peste"
fi

# 6. Backup nftables (dacă nu există deja)
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
        echo "✅ Backup nftables adăugat în crontab"
    fi
else
    echo "ℹ️ Backup nftables există deja - se sare peste"
fi

# 7. Configurare K3s (doar dacă nu există sau conține IP greșit)
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

# 8. Instalare K3s (dacă nu este instalat)
if ! command -v k3s &> /dev/null; then
    echo "=== Instalare K3s ==="
    curl -sfL https://get.k3s.io | sh -
    echo "✅ K3s instalat"
    echo "=== Așteptăm pornirea K3s (30 secunde) ==="
    sleep 30
else
    echo "ℹ️ K3s este deja instalat - se sare peste instalare"
    # Repornim K3s pentru a aplica eventualele configurări noi
    sudo systemctl restart k3s
    sleep 15
fi

# 9. Verificare și setare PATH pentru kubectl
echo "=== Verificare kubectl ==="
export PATH=$PATH:/usr/local/bin
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl nu a fost găsit. Verificați instalarea K3s."
    exit 1
fi
echo "✅ kubectl găsit: $(which kubectl)"

# 10. Corectare kubeconfig
echo "=== Corectare kubeconfig ==="
sudo sed -i "s/127.0.0.1/${NODE_IP}/g" /etc/rancher/k3s/k3s.yaml 2>/dev/null || true
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true
sudo chown $(id -u):$(id -g) ~/.kube/config 2>/dev/null || true
chmod 600 ~/.kube/config 2>/dev/null || true
export KUBECONFIG=~/.kube/config
echo "✅ kubectl configurat"

# 11. Verificare K3s
echo "=== Verificare K3s ==="
sudo systemctl status k3s --no-pager || true
kubectl get nodes -o wide --insecure-skip-tls-verify 2>/dev/null || echo "⏳ K3s încă nu este complet pornit..."

# 12. Instalare Helm (dacă nu există)
if ! command -v helm &> /dev/null; then
    echo "=== Instalare Helm ==="
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    echo "✅ Helm instalat"
else
    echo "ℹ️ Helm este deja instalat: $(helm version --short)"
fi

# 13. Adăugare repository-uri
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ 2>/dev/null || true
helm repo update

# 14. Creare fișier configurare Traefik (suprascrie mereu)
cat > /mnt/hdd/k8s/traefik/traefik-values.yaml << EOF7
ports:
  web:
    port: 80
    nodePort: 30080
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    port: 443
    nodePort: 30443

api:
  dashboard: true
  insecure: false

ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(\`traefik.aalto.md\`)
    entryPoints:
      - websecure
    middlewares:
      - name: dashboard-auth

extraObjects:
  - apiVersion: v1
    kind: Secret
    metadata:
      name: dashboard-auth-secret
    type: kubernetes.io/basic-auth
    stringData:
      username: admin
      password: "${TRAEFIK_PASSWORD}"
  - apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: dashboard-auth
    spec:
      basicAuth:
        secret: dashboard-auth-secret

providers:
  kubernetesCRD:
    enabled: true
  kubernetesIngress:
    enabled: true

tlsStore:
  default:
    defaultCertificate:
      secretName: wildcard-tls

log:
  level: INFO
accessLog:
  enabled: true

service:
  type: NodePort
  nodePorts:
    web: 30080
    websecure: 30443
EOF7

# 15. Instalare/Upgrade Traefik (smart)
echo "=== Instalare/Upgrade Traefik ==="
kubectl create namespace traefik 2>/dev/null || true
if helm list -n traefik | grep -q traefik; then
    echo "ℹ️ Traefik există deja - se face upgrade..."
    helm upgrade traefik traefik/traefik \
      -f /mnt/hdd/k8s/traefik/traefik-values.yaml \
      -n traefik \
      --wait
else
    echo "ℹ️ Se instalează Traefik..."
    helm install traefik traefik/traefik \
      -f /mnt/hdd/k8s/traefik/traefik-values.yaml \
      -n traefik \
      --wait
fi
echo "✅ Traefik instalat/upgradat"

# 16. Aplicare toate resursele (idempotent)
echo "=== Aplicare resurse (idempotent) ==="

# AdGuard
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

# Vaultwarden
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

# MinIO
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

# Headlamp
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

if helm list -n kube-system | grep -q my-headlamp; then
    echo "ℹ️ Headlamp există deja"
else
    helm install my-headlamp headlamp/headlamp --namespace kube-system 2>/dev/null || true
fi
kubectl apply -f /mnt/hdd/k8s/headlamp/headlamp-ingress.yaml

# 17. Creare secrete TLS (dacă există certificatele)
echo "=== Creare secrete TLS ==="
if [ -f /mnt/hdd/cert/wildcard.crt ] && [ -f /mnt/hdd/cert/wildcard.key ]; then
    kubectl create secret tls wildcard-tls \
      --cert=/mnt/hdd/cert/wildcard.crt \
      --key=/mnt/hdd/cert/wildcard.key \
      -n kube-system 2>/dev/null || echo "ℹ️ Secretul TLS există deja în kube-system"
    
    kubectl create secret tls wildcard-tls \
      --cert=/mnt/hdd/cert/wildcard.crt \
      --key=/mnt/hdd/cert/wildcard.key \
      -n traefik 2>/dev/null || echo "ℹ️ Secretul TLS există deja în traefik"
else
    echo "⚠️ Certificatele nu au fost găsite în /mnt/hdd/cert/"
fi

# 18. Verificare finală
echo ""
echo "=== Verificare finală ==="
kubectl get pods -A
echo ""
kubectl get svc -A
echo ""
kubectl get ingressroute -A

# 19. Adăugare în /etc/hosts
sudo tee -a /etc/hosts << EOF12
${NODE_IP} traefik.aalto.md
${NODE_IP} adguard.aalto.md
${NODE_IP} vault.aalto.md
${NODE_IP} minio.aalto.md
${NODE_IP} minio-console.aalto.md
${NODE_IP} dashboard.aalto.md
EOF12

# 20. Afișare rezumat
echo ""
echo "========================================="
echo "     INSTALARE COMPLETĂ!                "
echo "========================================="
echo ""
echo "📁 Toate fișierele YAML sunt în: /mnt/hdd/k8s/"
echo ""
echo "🔑 CREDENȚIALE:"
echo "   Fișierul cu toate parolele este în: /root/k8s-credentials.txt"
echo ""
echo "🌐 URL-uri de acces:"
echo "   ✅ Traefik Dashboard: https://traefik.aalto.md"
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
echo "   2. Dacă modificați certificatele, rulați:"
echo "      kubectl create secret tls wildcard-tls --cert=/mnt/hdd/cert/wildcard.crt --key=/mnt/hdd/cert/wildcard.key -n traefik --dry-run=client -o yaml | kubectl apply -f -"
echo "      kubectl create secret tls wildcard-tls --cert=/mnt/hdd/cert/wildcard.crt --key=/mnt/hdd/cert/wildcard.key -n kube-system --dry-run=client -o yaml | kubectl apply -f -"
echo "========================================="

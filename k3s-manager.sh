#!/bin/bash

# ============================================
# K3s Cluster Manager
# Instalare/Gestiune K3s + Traefik + AdGuard + Vaultwarden + MinIO + Headlamp
# ============================================

# Setează PATH-ul corect pentru root
export PATH=$PATH:/usr/local/bin

# Verifică dacă kubectl există
if ! command -v kubectl &> /dev/null; then
    echo "⚠️ kubectl nu a fost găsit. Verificați instalarea K3s."
    echo "   Încerc să setez PATH manual..."
    export PATH=$PATH:/usr/local/bin
    if ! command -v kubectl &> /dev/null; then
        echo "❌ kubectl încă nu a fost găsit. Rulați: export PATH=\$PATH:/usr/local/bin"
        exit 1
    fi
fi

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
# FUNCȚII DE BAZĂ
# ============================================

ensure_directories() {
    mkdir -p /mnt/hdd/k8s/{traefik,adguard,vaultwarden,minio,headlamp}
    mkdir -p /mnt/hdd/cert
    mkdir -p /var/lib/rancher/k3s/server/manifests/
}

# ============================================
# FUNCȚII DE INSTALARE COMPONENTE
# ============================================

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

    ensure_directories
    configure_k3s
    install_k3s
    configure_kubectl
    install_helm

    print_success "K3s + Helm instalat cu succes!"
    echo ""
    echo "📋 Pentru a verifica:"
    echo "   kubectl get nodes"
    echo "   kubectl get pods -A"
}

# [RESTUL FUNCȚIILOR rămân la fel, doar asigură-te că toate comenzile kubectl sunt executate fără sudo,
#  deoarece scriptul rulează ca root și PATH-ul este setat corect]

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
    echo "  3. ⚙️  Instalare doar K3s (Kubernetes + Helm)"
    echo "  4. 🖥️  Instalare doar Headlamp (Dashboard UI)"
    echo "  5. 🔧 Instalare doar Traefik Dashboard"
    echo "  6. 🛡️  Instalare doar AdGuard"
    echo "  7. 🔐 Instalare doar Vaultwarden"
    echo "  8. 💾 Instalare doar MinIO"
    echo "  9. 📊 Status cluster"
    echo " 10. 🔑 Afișează credențiale"
    echo ""
    echo -n "Alege o opțiune [0-10]: "
}

# ============================================
# FUNCȚIA DE ȘTERGERE
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

    [ -f /usr/local/bin/k3s-uninstall.sh ] && sudo /usr/local/bin/k3s-uninstall.sh || true

    sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /mnt/hdd/k8s /mnt/hdd/cert /root/k8s-credentials.txt /root/headlamp-token.txt
    sudo rm -f /etc/nftables/nftables.conf /etc/sysconfig/nftables.conf
    sudo rm -f /usr/local/bin/nftables-backup.sh
    sudo rm -rf /var/lib/rancher/k3s/server/manifests/traefik-dashboard-config.yaml

    sudo systemctl reset-failed k3s.service 2>/dev/null || true

    sudo crontab -l 2>/dev/null | grep -v "nftables-backup.sh" | sudo crontab - 2>/dev/null || true

    print_success "Cluster șters complet. Serverul este curat."
}

# [RESTUL FUNCȚIILOR AUXILIARE rămân la fel, doar asigură-te că toate comenzile sunt corecte]

# ============================================
# BUCLĂ PRINCIPALĂ
# ============================================
while true; do
    show_menu
    read -r choice
    case $choice in
        0) print_info "La revedere!"; exit 0 ;;
        1) uninstall_full; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        2) install_full; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        3) install_k3s_only; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        4) install_headlamp_only; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        5) install_traefik_only; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        6) install_adguard_only; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        7) install_vaultwarden_only; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        8) install_minio_only; echo ""; read -p "Apasă Enter pentru a continua..." ;;
        9) show_status; read -p "Apasă Enter pentru a continua..." ;;
        10) show_credentials; read -p "Apasă Enter pentru a continua..." ;;
        *) print_error "Opțiune invalidă. Alege 0-10."; sleep 2 ;;
    esac
done

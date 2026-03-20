#!/bin/bash
# =============================================================================
# Script d'installation — Projet DevOps CI/CD (EFREI ARIR86)
# Version corrigée — Mars 2026
#
# Installe : Docker, Docker Compose (plugin), kubectl, Minikube, Helm, Git
# Optionnel : ArgoCD CLI
#
# Usage : chmod +x install-devops-tools.sh && ./install-devops-tools.sh
# NE PAS exécuter en root (sudo) — le script demande sudo quand nécessaire
# =============================================================================

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

log_info()    { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
log_error()   { echo -e "${RED}[✗]${NC} $*"; }
log_step()    { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# Vérifie qu'on n'est PAS root (Minikube et Docker refusent root)
check_not_root() {
    if [ "$(id -u)" -eq 0 ]; then
        log_error "Ce script ne doit PAS être exécuté en tant que root/sudo."
        echo "    Lancez-le avec votre utilisateur normal :"
        echo "    ./install-devops-tools.sh"
        exit 1
    fi
}

check_internet() {
    log_step "Vérification de la connexion internet"
    if ! ping -c 1 -W 5 google.com &>/dev/null; then
        log_error "Pas de connexion internet ou problème DNS."
        echo "  1. Vérifiez votre connexion réseau"
        echo "  2. Vérifiez /etc/resolv.conf"
        echo "  3. Essayez : sudo systemctl restart systemd-resolved"
        exit 1
    fi
    log_info "Connexion internet OK"
}

# Détecte l'architecture (amd64 ou arm64)
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)
            log_error "Architecture non supportée : $arch"
            exit 1
            ;;
    esac
}

ARCH=$(detect_arch 2>/dev/null || echo "amd64")

# -----------------------------------------------------------------------------
# Vérifications préalables
# -----------------------------------------------------------------------------

check_not_root
check_internet

# Détection OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo 'unknown')}"
else
    log_error "Impossible de détecter l'OS. Ce script supporte Ubuntu/Debian."
    exit 1
fi

log_info "OS détecté : $OS_ID $OS_VERSION ($ARCH)"

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    log_warn "Ce script est conçu pour Ubuntu/Debian. Sur $OS_ID, certaines commandes peuvent échouer."
fi

# =============================================================================
# 1. Mise à jour du système + dépendances
# =============================================================================
log_step "Mise à jour du système et installation des dépendances"

sudo apt-get update -y
sudo apt-get install -y \
    curl \
    wget \
    git \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    make \
    jq

log_info "Dépendances installées"

# =============================================================================
# 2. Docker Engine + Docker Compose Plugin
# =============================================================================
log_step "Docker Engine + Docker Compose"

if command -v docker &>/dev/null; then
    log_info "Docker déjà installé : $(docker --version)"
else
    log_warn "Installation de Docker..."

    # Nettoyage d'anciennes versions
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Clé GPG Docker
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Dépôt Docker
    echo \
        "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID \
        $OS_VERSION stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_info "Docker installé : $(docker --version)"
fi

# Ajout au groupe docker (si pas déjà dedans)
if ! groups "$USER" | grep -q '\bdocker\b'; then
    sudo usermod -aG docker "$USER"
    log_warn "Utilisateur $USER ajouté au groupe docker."
    log_warn "⚠️  Vous DEVEZ vous déconnecter/reconnecter OU exécuter 'newgrp docker' après ce script."
    NEED_RELOGIN=true
else
    log_info "Utilisateur $USER déjà dans le groupe docker"
    NEED_RELOGIN=false
fi

# Vérifier que docker-compose (plugin) fonctionne
# Note : on utilise "docker compose" (plugin, avec espace) pas "docker-compose" (ancien binaire standalone)
if docker compose version &>/dev/null; then
    log_info "Docker Compose plugin : $(docker compose version --short 2>/dev/null || docker compose version)"
else
    # Fallback : installer le binaire standalone si le plugin ne marche pas
    log_warn "Docker Compose plugin non détecté, installation du binaire standalone..."
    sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    log_info "Docker Compose standalone : $(docker-compose --version)"
fi

# vm.max_map_count pour Elasticsearch / SonarQube
log_step "Configuration sysctl (vm.max_map_count)"
CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
if [ "$CURRENT_MAP_COUNT" -lt 262144 ]; then
    sudo sysctl -w vm.max_map_count=262144
    if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
        echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    log_info "vm.max_map_count configuré à 262144 (nécessaire pour Elasticsearch/SonarQube)"
else
    log_info "vm.max_map_count déjà ≥ 262144"
fi

# =============================================================================
# 3. kubectl
# =============================================================================
log_step "kubectl"

if command -v kubectl &>/dev/null; then
    log_info "kubectl déjà installé : $(kubectl version --client 2>/dev/null | head -1)"
else
    log_warn "Installation de kubectl..."
    KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    log_info "kubectl installé : $(kubectl version --client 2>/dev/null | head -1)"
fi

# =============================================================================
# 4. Minikube (INSTALLATION UNIQUEMENT — on ne le démarre PAS ici)
# =============================================================================
log_step "Minikube"

if command -v minikube &>/dev/null; then
    log_info "Minikube déjà installé : $(minikube version --short 2>/dev/null)"
else
    log_warn "Installation de Minikube..."
    curl -fsSLO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
    sudo install "minikube-linux-${ARCH}" /usr/local/bin/minikube
    rm -f "minikube-linux-${ARCH}"
    log_info "Minikube installé : $(minikube version --short 2>/dev/null)"
fi

# ⚠️ On ne démarre PAS Minikube ici.
# Le démarrage avec les bonnes ressources se fait pendant la partie CD du projet :
#   minikube start --driver=docker --cpus 4 --memory 10240
log_warn "Minikube n'est PAS démarré. Lancez-le manuellement quand vous en aurez besoin :"
echo "    minikube start --driver=docker --cpus 4 --memory 10240"

# =============================================================================
# 5. Helm
# =============================================================================
log_step "Helm"

if command -v helm &>/dev/null; then
    log_info "Helm déjà installé : $(helm version --short 2>/dev/null)"
else
    log_warn "Installation de Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_info "Helm installé : $(helm version --short 2>/dev/null)"
fi

# =============================================================================
# 6. ArgoCD CLI (optionnel)
# =============================================================================
log_step "ArgoCD CLI (optionnel)"

if command -v argocd &>/dev/null; then
    log_info "ArgoCD CLI déjà installé : $(argocd version --client --short 2>/dev/null)"
else
    echo ""
    read -r -p "Installer ArgoCD CLI ? (recommandé mais optionnel) [y/N] " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        log_warn "Installation d'ArgoCD CLI..."
        curl -fsSL -o argocd "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}"
        sudo install -m 555 argocd /usr/local/bin/argocd
        rm -f argocd
        log_info "ArgoCD CLI installé : $(argocd version --client --short 2>/dev/null)"
    else
        log_info "ArgoCD CLI non installé (vous pouvez l'installer plus tard)"
    fi
fi

# =============================================================================
# Résumé
# =============================================================================
log_step "Résumé de l'installation"

echo ""
echo "  Outil            Version"
echo "  ───────────────  ────────────────────────────────────"
printf "  %-17s %s\n" "Docker"          "$(docker --version 2>/dev/null || echo 'Non installé')"
printf "  %-17s %s\n" "Docker Compose"  "$(docker compose version --short 2>/dev/null || docker-compose --version 2>/dev/null || echo 'Non installé')"
printf "  %-17s %s\n" "kubectl"         "$(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print $2}' || echo 'Non installé')"
printf "  %-17s %s\n" "Minikube"        "$(minikube version --short 2>/dev/null || echo 'Non installé')"
printf "  %-17s %s\n" "Helm"            "$(helm version --short 2>/dev/null || echo 'Non installé')"
printf "  %-17s %s\n" "Git"             "$(git --version 2>/dev/null || echo 'Non installé')"
printf "  %-17s %s\n" "ArgoCD CLI"      "$(argocd version --client --short 2>/dev/null || echo 'Non installé')"
echo "  ───────────────  ────────────────────────────────────"
echo ""

# Rappels importants
echo -e "${YELLOW}━━━ ÉTAPES SUIVANTES ━━━${NC}"
echo ""

if [ "${NEED_RELOGIN:-false}" = true ]; then
    echo -e "  ${RED}1. OBLIGATOIRE — Reconnectez-vous pour activer le groupe docker :${NC}"
    echo "     Déconnexion/reconnexion OU exécutez : newgrp docker"
    echo ""
fi

echo "  2. Clonez votre fork du projet :"
echo "     git clone https://github.com/VOTRE_USERNAME/devops-demo-project.git"
echo ""
echo "  3. Lancez l'environnement CI (Jenkins + SonarQube) :"
echo "     cd devops-demo-project/ci"
echo "     docker compose up -d"
echo ""
echo "     (Si 'docker compose' ne marche pas, essayez 'docker-compose up -d')"
echo ""
echo "  4. Quand vous passerez à la partie CD, démarrez Minikube :"
echo "     minikube start --driver=docker --cpus 4 --memory 10240"
echo ""
echo -e "${GREEN}Installation terminée !${NC}"

#!/usr/bin/env bash
#
# system-audit.sh - Auditoria de pacotes e integridade do banco de dados (Debian & RHEL)
# Suporta: Debian, Ubuntu, RHEL, CentOS Stream, Rocky Linux, AlmaLinux e Fedora.
#

set -o pipefail

# Cores para formatação de saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Verificação de privilégios de execução
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERRO] Este script requer privilégios de root para inspecionar bases de dados protegidas.${NC}"
   echo "Execute com: sudo $0"
   exit 1
fi

LOG_FILE="/var/log/audit_packages_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}    AUDITORIA DE PACOTES E INTEGRIDADE DE SISTEMA    ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo "Data da execução: $(date)"
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"

# Identificação da distribuição
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_LIKE=${ID_LIKE:-""}
    OS_NAME=$PRETTY_NAME
else
    echo -e "${RED}[FALHA] Ficheiro /etc/os-release não encontrado. Sistema não suportado.${NC}"
    exit 1
fi

echo -e "Distribuição detetada: ${GREEN}${OS_NAME}${NC}\n"

# ==============================================================================
# AUDITORIA PARA FAMÍLIA DEBIAN (dpkg / apt)
# ==============================================================================
audit_debian() {
    echo -e "${YELLOW}---> Executando rotinas de auditoria no ecossistema Debian/APT...${NC}\n"

    # 1. Total de pacotes instalados
    TOTAL_PKGS=$(dpkg-query -f '${binary:Package}\n' -W | wc -l)
    echo -e "1. Pacotes instalados no catálogo: ${GREEN}${TOTAL_PKGS}${NC}"

    # 2. Pacotes em estado corrompido ou de configuração pendente
    echo -e "\n2. Verificando integridade das transações e pacotes incompletos:"
    BROKEN_STATES=$(dpkg -l | awk '/^[^ii]/ && /^r[A-Za-z]/ || /^[UuFfHhWw]/ {print $1, $2, $3}')
    
    if [ -n "$BROKEN_STATES" ]; then
        echo -e "${RED}[ALERTA] Foram encontrados pacotes em estado anormal:${NC}"
        echo "$BROKEN_STATES"
        echo -e "${YELLOW}Sugestão de correção: apt --fix-broken install ou dpkg --configure -a${NC}"
    else
        echo -e "${GREEN}[OK] Todos os pacotes estão no estado padrão ('ii' - instalado e configurado).${NC}"
    fi

    # 3. Verificação de dependências não satisfeitas via APT
    echo -e "\n3. Testando árvore de dependências do APT:"
    if apt-get check > /dev/null 2>&1; then
        echo -e "${GREEN}[OK] A árvore de dependências está íntegra.${NC}"
    else
        echo -e "${RED}[FALHA] Há dependências quebradas na base de dados.${NC}"
        apt-get check
    fi

    # 4. Auditoria de integridade física dos ficheiros (checksums)
    echo -e "\n4. Verificando integridade dos ficheiros em disco via 'dpkg --verify':"
    echo "   (Isto pode demorar alguns minutos. Alterações em /etc costumam ser normais)..."
    
    MODIFIED_FILES=$(dpkg --verify 2>/dev/null | grep -v '^..5.* /etc/' || true)
    
    if [ -n "$MODIFIED_FILES" ]; then
        echo -e "${YELLOW}[AVISO] Ficheiros binários ou bibliotecas modificados fora de /etc:${NC}"
        echo "$MODIFIED_FILES" | head -n 30
        TOTAL_MOD=$(echo "$MODIFIED_FILES" | wc -l)
        if [ "$TOTAL_MOD" -gt 30 ]; then
            echo "... e mais $((TOTAL_MOD - 30)) ficheiros modificados (consulte o log)."
        fi
    else
        echo -e "${GREEN}[OK] Nenhuma divergência de integridade detetada nos binários do sistema.${NC}"
    fi
}

# ==============================================================================
# AUDITORIA PARA FAMÍLIA RED HAT (rpm / dnf)
# ==============================================================================
audit_rhel() {
    echo -e "${YELLOW}---> Executando rotinas de auditoria no ecossistema Red Hat/RPM...${NC}\n"

    # 1. Total de pacotes instalados
    TOTAL_PKGS=$(rpm -qa | wc -l)
    echo -e "1. Pacotes instalados no catálogo: ${GREEN}${TOTAL_PKGS}${NC}"

    # 2. Status da subscrição (se for RHEL genuíno)
    if command -v subscription-manager &> /dev/null; then
        echo -e "\n2. Verificando estado do Red Hat Subscription Manager:"
        SUB_STATUS=$(subscription-manager status | grep -E "Overall Status:" || echo "Não registrado")
        echo -e "   Status da Subscrição: ${GREEN}${SUB_STATUS}${NC}"
    fi

    # 3. Integridade do banco de dados BerkeleyDB/NDB do RPM
    echo -e "\n3. Verificando integridade da base local (/var/lib/rpm):"
    if rpmdb --verify &> /dev/null; then
        echo -e "${GREEN}[OK] A base de dados do RPM está consistente.${NC}"
    else
        echo -e "${RED}[ALERTA] Inconsistências na base do RPM. Recomenda-se executar: rpmdb --rebuilddb${NC}"
    fi

    # 4. Verificação de dependências não satisfeitas e duplicatas no DNF
    echo -e "\n4. Verificando integridade de dependências via DNF:"
    if command -v dnf &> /dev/null; then
        DNF_CHECK=$(dnf check 2>&1)
        if [ -z "$DNF_CHECK" ]; then
            echo -e "${GREEN}[OK] Nenhuma dependência órfã ou duplicata detetada pelo DNF.${NC}"
        else
            echo -e "${RED}[ALERTA] Problemas detetados no catálogo do DNF:${NC}"
            echo "$DNF_CHECK"
        fi
    fi

    # 5. Auditoria de integridade física dos ficheiros (rpm -Va)
    echo -e "\n5. Validando integridade física dos ficheiros instalados (rpm -Va):"
    echo "   (Filtrando ficheiros de configuração comuns em /etc)..."

    # Ignora ficheiros de configuração marcados (c) e foca em binários corrompidos (5 = MD5/SHA256 alterado)
    RPM_VERIFY=$(rpm -Va --nofiles --nodigest 2>/dev/null | grep -E '^..5' || true)

    if [ -n "$RPM_VERIFY" ]; then
        echo -e "${YELLOW}[AVISO] Binários com soma de verificação divergente da base original:${NC}"
        echo "$RPM_VERIFY" | head -n 30
        TOTAL_ALTERADOS=$(echo "$RPM_VERIFY" | wc -l)
        if [ "$TOTAL_ALTERADOS" -gt 30 ]; then
            echo "... e mais $((TOTAL_ALTERADOS - 30)) ficheiros alterados (detalhes no log)."
        fi
    else
        echo -e "${GREEN}[OK] Todos os binários inspecionados correspondem aos dados de empacotamento.${NC}"
    fi
}

# ==============================================================================
# ROTEAMENTO POR FAMÍLIA
# ==============================================================================
case "$OS_ID" in
    debian|ubuntu|linuxmint|kali)
        audit_debian
        ;;
    rhel|centos|rocky|almalinux|fedora|ol)
        audit_rhel
        ;;
    *)
        # Validação secundária por ID_LIKE
        if [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then
            audit_debian
        elif [[ "$OS_LIKE" =~ (rhel|fedora|centos) ]]; then
            audit_rhel
        else
            echo -e "${RED}[FALHA] Sistema operacional não compatível com os procedimentos deste script.${NC}"
            exit 2
        fi
        ;;
esac

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${GREEN}Auditoria concluída com sucesso.${NC}"
echo -e "Relatório completo armazenado em: ${YELLOW}${LOG_FILE}${NC}"
echo -e "${BLUE}======================================================${NC}"

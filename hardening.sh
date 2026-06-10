#!/usr/bin/env bash
###############################################################################
# hardening.sh — fecha a VM da stack de telemetria (rodar APOS o instalar.sh)
#
# Aplica:
#  - InfluxDB :8181 -> liberado SO para os IPs do SaaS, via chain DOCKER-USER
#    (filtrando pela interface publica, p/ nao bloquear o Telegraf local).
#  - Explorer :8888 -> preso em 127.0.0.1 (acesso so por tunel SSH).
#  - UFW -> SSH e Huawei :57400 (essas o UFW filtra; 8181/8888 nao, pois Docker
#    fura o UFW em portas publicadas por container bridge).
#
# Uso (exemplos):
#   sudo bash hardening.sh
#   sudo HUAWEI_IPS="203.0.113.10 203.0.113.11" SSH_SRC=198.51.100.5 bash hardening.sh
#
# Variaveis (env):
#   NOCAI_IPS   hosts do SaaS que consultam a :8181  (default: NOC.ai + Kuanticks)
#   HUAWEI_IPS  IPs dos equipamentos Huawei p/ liberar a :57400 (default: vazio)
#   SSH_SRC     IP/CIDR que pode SSH (default: vazio = libera 22 de qualquer lugar)
#   IFACE       interface publica (default: auto-detect)
#   WORKDIR     dir da stack (default: ~/telemetria) — usado p/ prender o 8888
#   SKIP_UFW=1          nao mexe no UFW
#   SKIP_EXPLORER=1     nao prende o 8888 em localhost
###############################################################################
set -euo pipefail

NOCAI_IPS="${NOCAI_IPS:-201.182.96.180 201.182.96.178}"
HUAWEI_IPS="${HUAWEI_IPS:-}"
SSH_SRC="${SSH_SRC:-}"
WORKDIR="${WORKDIR:-$HOME/telemetria}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[aviso] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[erro] %s\033[0m\n' "$*" >&2; exit 1; }

# ===== sudo / root =====
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Rode como root ou instale o sudo."
  SUDO="sudo"
else
  SUDO=""
fi

# ===== interface publica =====
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)}"
[ -n "${IFACE:-}" ] || die "Nao consegui detectar a interface publica. Defina IFACE=eth0 (veja: ip -br link)."
say "Interface publica: $IFACE"

# ===== 1. InfluxDB :8181 — allowlist via DOCKER-USER =====
command -v iptables >/dev/null 2>&1 || die "iptables nao encontrado."
$SUDO iptables -L DOCKER-USER -n >/dev/null 2>&1 || die "Chain DOCKER-USER inexistente. O Docker esta rodando? (a stack precisa estar de pe)"

ipt_ensure() {  # idempotente: insere a regra se ainda nao existir
  if $SUDO iptables -C DOCKER-USER "$@" 2>/dev/null; then
    echo "   (ja existe) iptables ... $*"
  else
    $SUDO iptables -I DOCKER-USER "$@"
    echo "   + iptables -I DOCKER-USER $*"
  fi
}

say "InfluxDB :8181 — liberando so o SaaS ($NOCAI_IPS) na interface $IFACE"
# DROP primeiro (com -I os ACCEPTs inseridos depois ficam ACIMA do DROP)
ipt_ensure -i "$IFACE" -p tcp --dport 8181 -j DROP
for ip in $NOCAI_IPS; do
  ipt_ensure -i "$IFACE" -p tcp --dport 8181 -s "$ip" -j ACCEPT
done

say "Persistindo regras do iptables"
if ! command -v netfilter-persistent >/dev/null 2>&1; then
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 \
    || warn "Nao instalei iptables-persistent — as regras se perdem no reboot. Instale manualmente."
fi
command -v netfilter-persistent >/dev/null 2>&1 && $SUDO netfilter-persistent save || true

# ===== 2. Explorer :8888 -> localhost =====
if [ "${SKIP_EXPLORER:-0}" != "1" ]; then
  COMPOSE="$WORKDIR/docker-compose.yml"
  if [ -f "$COMPOSE" ]; then
    if grep -q '127.0.0.1:8888:8080' "$COMPOSE"; then
      say "Explorer :8888 ja esta preso em localhost — ok"
    elif grep -qE '8888:8080' "$COMPOSE"; then
      say "Prendendo Explorer :8888 em 127.0.0.1 ($COMPOSE)"
      $SUDO sed -i -E 's#- *"[^"]*8888:8080"#- "127.0.0.1:8888:8080"#' "$COMPOSE"
      ( cd "$WORKDIR" && docker compose up -d ) || warn "Edite e rode 'docker compose up -d' manualmente."
    else
      warn "Nao achei o mapeamento 8888:8080 em $COMPOSE — pule ou ajuste manualmente."
    fi
  else
    warn "$COMPOSE nao encontrado — defina WORKDIR ou prenda o 8888 manualmente."
  fi
fi

# ===== 3. UFW — SSH e Huawei :57400 =====
if [ "${SKIP_UFW:-0}" != "1" ]; then
  if command -v ufw >/dev/null 2>&1; then
    say "Configurando UFW (SSH + Huawei :57400)"
    # SSH SEMPRE primeiro, p/ nao se trancar
    if [ -n "$SSH_SRC" ]; then
      $SUDO ufw allow from "$SSH_SRC" to any port 22 proto tcp
    else
      warn "SSH_SRC vazio -> liberando a porta 22 de QUALQUER origem (defina SSH_SRC p/ restringir)."
      $SUDO ufw allow 22/tcp
    fi
    if [ -n "$HUAWEI_IPS" ]; then
      for ip in $HUAWEI_IPS; do
        $SUDO ufw allow from "$ip" to any port 57400 proto tcp
      done
    else
      warn "HUAWEI_IPS vazio -> a :57400 ficara BLOQUEADA. Rode de novo com HUAWEI_IPS=... quando tiver equipamentos."
    fi
    $SUDO ufw default deny incoming
    $SUDO ufw --force enable
  else
    warn "ufw nao instalado — pulei (instale com: apt install ufw)."
  fi
fi

# ===== resumo =====
say "Hardening aplicado. Conferir:"
cat <<MSG
   sudo iptables -L DOCKER-USER -n --line-numbers     # ACCEPTs (SaaS) acima do DROP, na $IFACE
   sudo ufw status verbose
   # de FORA da VM: 8888 e 8181 (de IP nao-autorizado) devem dar timeout;
   # do NOC.ai/Kuanticks a 8181 deve responder.

 Lembretes:
  - Explorer agora so por tunel:  ssh -L 8888:127.0.0.1:8888 usuario@<IP_DA_VM>
  - Token ainda trafega em HTTP (a URL no Kuanticks e http://). Para TLS, ponha
    um proxy HTTPS na frente do :8181 e cadastre a URL como https://.
MSG

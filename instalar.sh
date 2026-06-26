#!/usr/bin/env bash
###############################################################################
# instalar.sh — Bootstrap da stack de Telemetria (InfluxDB 3 + Explorer + Telegraf)
#
# O que faz (idempotente — pode rodar de novo sem quebrar):
#   1. Verifica Docker e Docker Compose
#   2. Cria .env (a partir do .env.example) e gera o SESSION_SECRET
#   3. Cria diretórios de dados e sobe o InfluxDB 3 Core
#   4. Gera o token admin e cria o database (só na 1ª vez)
#   5. Sobe Explorer + Telegraf (Huawei e gNMI)
#   6. Imprime os dados de acesso e o endpoint para o Kuantics
#
# Uso:  ./instalar.sh
###############################################################################
set -euo pipefail

cd "$(dirname "$0")"

# Cores (degrade silencioso se o terminal não suportar)
B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; N="\033[0m"
info() { printf "${B}==>${N} %s\n" "$1"; }
ok()   { printf "${G}  ✓${N} %s\n" "$1"; }
warn() { printf "${Y}  !${N} %s\n" "$1"; }
die()  { printf "${R}ERRO:${N} %s\n" "$1" >&2; exit 1; }

INFLUX_DB="telemetria"

# --- 1. Pré-requisitos -------------------------------------------------------
info "Verificando pré-requisitos"
command -v docker >/dev/null 2>&1 || die "Docker não encontrado. Instale o Docker antes de continuar."
docker compose version >/dev/null 2>&1 || die "'docker compose' (plugin v2) não encontrado. Atualize o Docker."
docker info >/dev/null 2>&1 || die "O daemon do Docker não está respondendo (você tem permissão? tente com sudo ou adicione seu usuário ao grupo docker)."
ok "Docker e Docker Compose OK"

# --- 2. .env e SESSION_SECRET ------------------------------------------------
info "Preparando o .env"
if [ ! -f .env ]; then
  cp .env.example .env
  ok "Criado .env a partir do .env.example"
fi
# Garante um SESSION_SECRET aleatório se ainda estiver com o placeholder
if grep -q "^SESSION_SECRET=trocar-me" .env 2>/dev/null || ! grep -q "^SESSION_SECRET=" .env; then
  SECRET="$(openssl rand -hex 32)"
  if grep -q "^SESSION_SECRET=" .env; then
    sed -i.bak "s|^SESSION_SECRET=.*|SESSION_SECRET=${SECRET}|" .env && rm -f .env.bak
  else
    printf "\nSESSION_SECRET=%s\n" "$SECRET" >> .env
  fi
  ok "SESSION_SECRET gerado"
fi

# --- 3. Diretórios e InfluxDB ------------------------------------------------
info "Criando diretórios de dados"
mkdir -p data plugins explorer/db explorer/config secrets
ok "Diretórios prontos"

info "Subindo o InfluxDB 3 Core"
docker compose up -d influxdb3-core

info "Aguardando o InfluxDB ficar pronto (porta 8181)"
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:8181/health" >/dev/null 2>&1; then
    ok "InfluxDB respondendo"; break
  fi
  [ "$i" = "60" ] && die "InfluxDB não respondeu em 60s. Veja: docker logs influxdb3-core"
  sleep 1
done

# --- 4. Token admin + database (só na 1ª vez) --------------------------------
CURRENT_TOKEN="$(grep '^INFLUX_TOKEN=' .env | cut -d= -f2- || true)"
if [ -z "$CURRENT_TOKEN" ] || [ "$CURRENT_TOKEN" = "trocar-me" ]; then
  info "Gerando token admin do InfluxDB"
  TOKEN_JSON="$(docker exec influxdb3-core influxdb3 create token --admin --format json 2>/dev/null || true)"
  TOKEN="$(printf '%s' "$TOKEN_JSON" | grep -o 'apiv3_[A-Za-z0-9_-]*' | head -1 || true)"
  [ -n "$TOKEN" ] || die "Não consegui gerar o token admin. Saída: $TOKEN_JSON"
  printf '%s\n' "$TOKEN" > secrets/admin-token
  chmod 600 secrets/admin-token
  sed -i.bak "s|^INFLUX_TOKEN=.*|INFLUX_TOKEN=${TOKEN}|" .env && rm -f .env.bak
  ok "Token admin gerado e gravado em .env e secrets/admin-token"
else
  TOKEN="$CURRENT_TOKEN"
  ok "Token admin já existente no .env (mantido)"
fi

info "Garantindo o database '${INFLUX_DB}'"
if docker exec influxdb3-core influxdb3 create database "${INFLUX_DB}" --token "${TOKEN}" >/dev/null 2>&1; then
  ok "Database '${INFLUX_DB}' criado"
else
  warn "Database '${INFLUX_DB}' já existe (ok)"
fi

# --- 5. Sobe o restante da stack --------------------------------------------
info "Subindo Explorer e Telegraf"
docker compose up -d
ok "Stack no ar"

# --- 6. Resumo ---------------------------------------------------------------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-<IP_DA_VM>}"
echo
printf "${G}${B}========================================================${N}\n"
printf "${G}${B} Telemetria instalada com sucesso${N}\n"
printf "${G}${B}========================================================${N}\n"
echo
echo "  Explorer (UI):     http://${IP}:8888"
echo "  InfluxDB (API):    http://${IP}:8181"
echo "  Database:          ${INFLUX_DB}"
echo "  Token admin:       (em ./secrets/admin-token e no .env)"
echo
echo "  Coleta Huawei (passiva): aponte o telemetry dos equipamentos para"
echo "                           ${IP}:57400 (dial-out gRPC)."
echo
echo "  Coleta gNMI (manual): cadastre equipamentos copiando modelos de"
echo "                        exemplos/ para telegraf.d/ e rode:"
echo "                        docker compose restart telegraf-gnmi"
echo
printf "${B}  >> Para cadastrar no Kuantics:${N}\n"
echo "     URL/Host:  http://${IP}:8181"
echo "     Database:  ${INFLUX_DB}"
echo "     Token:     conteúdo de ./secrets/admin-token"
echo
echo "  Status:  docker compose ps"
echo "  Logs:    docker logs -f telegraf-gnmi   |   docker logs -f influxdb3-core"
echo

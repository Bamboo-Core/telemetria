#!/usr/bin/env bash
###############################################################################
# instalar.sh — Stack de Telemetria (InfluxDB 3 + Explorer + Telegraf)
#
# Instala e configura a stack numa VM nova, usando SOMENTE a imagem publicada
# (nao precisa clonar o repositorio). Cria os arquivos, extrai o telegraf.conf
# de dentro da imagem, faz o bootstrap do token do InfluxDB e sobe tudo.
#
# Uso:
#   bash instalar.sh
#   WORKDIR=/opt/telemetria bash instalar.sh   # diretorio alternativo
#
# Idempotente: re-executar nao sobrescreve .env, telegraf.conf nem o token.
###############################################################################
set -euo pipefail

# ===== parametros =====
IMAGE="${IMAGE:-ghcr.io/bamboo-core/telemetria:latest}"
WORKDIR="${WORKDIR:-$HOME/telemetria}"
INFLUX_DB_NAME="${INFLUX_DB_NAME:-telemetria}"
# Hosts do SaaS que consultam a :8181 (NOC.ai puxa os dados; Kuanticks testa a
# conexao ao cadastrar). O Postgres (poc01 / .108) NAO entra aqui.
NOCAI_IPS="${NOCAI_IPS:-201.182.96.180 201.182.96.178}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[aviso] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[erro] %s\033[0m\n' "$*" >&2; exit 1; }

# ===== 0. checagens =====
say "Checando pre-requisitos"
command -v docker >/dev/null 2>&1 || die "Docker nao encontrado. Instale com: curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || die "Plugin 'docker compose' (v2) nao encontrado."
docker info >/dev/null 2>&1 || die "Sem acesso ao Docker. Rode com sudo, ou adicione seu usuario ao grupo docker (usermod -aG docker \$USER)."
command -v openssl >/dev/null 2>&1 || die "openssl nao encontrado (necessario para gerar o SESSION_SECRET)."
if ! grep -qo avx /proc/cpuinfo 2>/dev/null; then
  warn "CPU sem flag AVX: o InfluxDB 3 Core pode abortar com SIGILL (exit 132)."
  warn "Recomendado usar VM com CPU moderna/host-passthrough."
fi

# ===== 1. diretorio e arquivos =====
say "Preparando diretorio: $WORKDIR"
mkdir -p "$WORKDIR/secrets" "$WORKDIR/explorer/config"
cd "$WORKDIR"

# --- docker-compose.yml ---
if [ -f docker-compose.yml ]; then
  warn "docker-compose.yml ja existe — mantendo o atual."
else
  say "Criando docker-compose.yml"
  cat > docker-compose.yml <<'YAML'
services:
  influxdb3-core:
    image: influxdb:3-core
    container_name: ${INFLUX_NAME:-influxdb3-core}
    user: "1000:1000"
    ports:
      - "${INFLUX_PORT:-8181}:8181"
    command:
      - influxdb3
      - serve
      - --node-id=node0
      - --object-store=file
      - --data-dir=/var/lib/influxdb3/data
      - --plugin-dir=/var/lib/influxdb3/plugins
      - --admin-token-file=/etc/influxdb3/admin-token
    volumes:
      - influxdb_data:/var/lib/influxdb3/data
      - influxdb_plugins:/var/lib/influxdb3/plugins
      - ./secrets/admin-token:/etc/influxdb3/admin-token:ro
    restart: unless-stopped
    networks: [telemetria]

  influxdb3-explorer:
    image: influxdata/influxdb3-ui:1.8.0
    container_name: ${EXPLORER_NAME:-influxdb3-explorer}
    command: ["--mode=admin"]
    ports:
      - "${EXPLORER_PORT:-8888}:8080"
    volumes:
      - explorer_db:/db:rw
      - ./explorer/config:/app-root/config:ro
    environment:
      - SESSION_SECRET_KEY=${SESSION_SECRET:?defina SESSION_SECRET no .env}
    restart: unless-stopped
    depends_on: [influxdb3-core]
    networks: [telemetria]

  telegraf:
    image: ghcr.io/bamboo-core/telemetria:latest
    container_name: ${TELEGRAF_NAME:-telegraf}
    network_mode: host
    environment:
      - INFLUX_TOKEN=${INFLUX_TOKEN:?defina INFLUX_TOKEN no .env}
      - INFLUX_DB=${INFLUX_DB:-telemetria}
    volumes:
      - ./telegraf.conf:/etc/telegraf/telegraf.conf:ro
    restart: unless-stopped

volumes:
  influxdb_data:
  influxdb_plugins:
  explorer_db:

networks:
  telemetria:
    driver: bridge
YAML
fi

# --- .env ---
if [ -f .env ]; then
  warn ".env ja existe — mantendo o atual (nao sobrescrevo segredos)."
else
  say "Criando .env (gerando SESSION_SECRET)"
  cat > .env <<ENV
INFLUX_TOKEN=bootstrap
INFLUX_DB=${INFLUX_DB_NAME}
SESSION_SECRET=$(openssl rand -hex 32)
INFLUX_PORT=8181
EXPLORER_PORT=8888
ENV
fi

# --- telegraf.conf (extrai da imagem) ---
if [ -f telegraf.conf ]; then
  warn "telegraf.conf ja existe — mantendo o seu (preserva suas edicoes)."
else
  say "Extraindo telegraf.conf de dentro da imagem"
  docker run --rm "$IMAGE" cat /etc/telegraf/telegraf.conf > telegraf.conf
fi

# --- admin-token (precisa existir como ARQUIVO antes do up) ---
[ -e secrets/admin-token ] || : > secrets/admin-token
[ -d secrets/admin-token ] && die "secrets/admin-token e um diretorio (criado por um 'up' anterior sem o arquivo). Remova-o: rmdir secrets/admin-token"

# ===== 2. bootstrap do token do InfluxDB 3 =====
if grep -q 'apiv3_' secrets/admin-token 2>/dev/null; then
  TOKEN=$(grep -o 'apiv3_[A-Za-z0-9]*' secrets/admin-token | head -1)
  say "Token do InfluxDB ja existe — pulando bootstrap."
  # garante que o .env esta sincronizado com o token do arquivo
  sed -i "s|^INFLUX_TOKEN=.*|INFLUX_TOKEN=$TOKEN|" .env
else
  say "Bootstrap do token do InfluxDB 3"
  # placeholder pra o compose nao recusar (telegraf usa INFLUX_TOKEN:?)
  if grep -q '^INFLUX_TOKEN=' .env; then
    sed -i "s|^INFLUX_TOKEN=.*|INFLUX_TOKEN=bootstrap|" .env
  else
    echo "INFLUX_TOKEN=bootstrap" >> .env
  fi
  docker compose up -d influxdb3-core
  say "Aguardando o InfluxDB iniciar..."
  for i in $(seq 1 15); do
    docker exec influxdb3-core influxdb3 create token --admin --format json >/tmp/_inflxtok 2>/dev/null && break
    sleep 2
  done
  if grep -q 'apiv3_' /tmp/_inflxtok 2>/dev/null; then
    cp /tmp/_inflxtok secrets/admin-token
  else
    die "Falha ao gerar o token admin. Veja: docker logs influxdb3-core"
  fi
  rm -f /tmp/_inflxtok
  TOKEN=$(grep -o 'apiv3_[A-Za-z0-9]*' secrets/admin-token | head -1)
  [ -n "$TOKEN" ] || die "Token gerado mas nao consegui extrair o apiv3_."
  sed -i "s|^INFLUX_TOKEN=.*|INFLUX_TOKEN=$TOKEN|" .env
  say "Token gerado e salvo em secrets/admin-token + .env"
fi

# ===== 3. subir a stack completa =====
say "Subindo a stack completa"
docker compose up -d
sleep 3
docker compose ps

# ===== final =====
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
# interface publica (pra filtrar SO o trafego externo na 8181 — senao o proprio
# Telegraf local seria bloqueado ao escrever no InfluxDB)
IFACE_PUB=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
IFACE_PUB="${IFACE_PUB:-<IFACE_PUBLICA>}"
# monta as regras de allowlist da :8181 a partir de NOCAI_IPS
HARDEN_8181=""
for _ip in $NOCAI_IPS; do
  HARDEN_8181="${HARDEN_8181}      sudo iptables -I DOCKER-USER -i ${IFACE_PUB} -p tcp --dport 8181 -s ${_ip} -j ACCEPT
"
done
cat <<MSG

============================================================
 STACK NO AR  (diretorio: $WORKDIR)
============================================================
 Explorer (UI) : http://${IP:-<IP_DA_VM>}:8888
 InfluxDB      : porta 8181  | database: ${INFLUX_DB_NAME}
 Token admin   : secrets/admin-token  (tambem no .env como INFLUX_TOKEN)

 Metricas de host (cpu/mem/disk/system) devem aparecer em poucos minutos
 — provam o pipeline Telegraf -> InfluxDB, mesmo sem equipamento.

 PROXIMOS PASSOS
 ---------------
 1) Huawei (MDT): configurar dial-out gRPC NO EQUIPAMENTO -> ${IP:-<IP_DA_VM>}:57400
    (nada a editar no Telegraf).

 2) Juniper (gNMI): editar o arquivo de coleta e recriar o Telegraf:
       nano $WORKDIR/telegraf.conf       # descomentar [[inputs.gnmi]] e preencher IP/usuario/senha
       docker compose up -d --force-recreate telegraf
       docker logs telegraf | tail
    (sintaxe ja correta p/ Telegraf 1.23.4: enable_tls; subscriptions explicitas;
     1 bloco [[inputs.gnmi]] por equipamento com credenciais distintas.)

 3) IP PUBLICO -> HARDENING OBRIGATORIO:

    a) InfluxDB :8181 — liberar SO o SaaS (NOC.ai puxa dados, Kuanticks testa).
       O UFW NAO filtra porta publicada por container; use a chain DOCKER-USER.
       Filtra-se pela interface publica (${IFACE_PUB}) p/ NAO bloquear o Telegraf local:
      sudo iptables -I DOCKER-USER -i ${IFACE_PUB} -p tcp --dport 8181 -j DROP
${HARDEN_8181}      sudo apt install -y iptables-persistent && sudo netfilter-persistent save
       (IPs em NOCAI_IPS no topo do script; interface detectada automaticamente.)

    b) Explorer :8888 (UI admin, o SaaS nao usa) — prenda em localhost no
       docker-compose.yml:  "127.0.0.1:8888:8080"  e acesse por tunel:
         ssh -L 8888:127.0.0.1:8888 usuario@${IP:-<IP_DA_VM>}

    c) Huawei :57400 (Telegraf em network_mode host -> UFW funciona) e SSH:
         sudo ufw default deny incoming
         sudo ufw allow from <IP_ADMIN/VPN> to any port 22 proto tcp
         sudo ufw allow from <IP_EQUIPAMENTO_HUAWEI> to any port 57400 proto tcp
         sudo ufw enable

    d) Juniper :32767 — nada a abrir (e saida da VM).

    OBS: a URL cadastrada e http:// -> o token trafega em texto puro. O
    allowlist acima protege o "quem"; para criptografar, use proxy HTTPS na
    frente do :8181 e cadastre a URL do tenant como https:// no Kuanticks.

 OPERACAO
 --------
   docker compose ps                 # status
   docker logs -f telegraf           # logs do coletor
   docker compose pull telegraf && docker compose up -d telegraf   # atualizar imagem
   docker compose down               # parar (dados ficam nos volumes)
============================================================
MSG

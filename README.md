# Stack de Telemetria — InfluxDB 3 + Explorer + Telegraf (Huawei MDT)

Coleta de telemetria de rede: Telegraf (host + Huawei gRPC MDT + Juniper gNMI) → InfluxDB 3 Core → Explorer (UI). InfluxDB **local em cada cliente**.

> **Instalação no cliente = SOMENTE a imagem.** Este repositório é para
> **build/manutenção** da imagem do Telegraf. **NÃO clone este repositório na VM
> do cliente.** Na VM você precisa apenas de: a imagem publicada
> (`ghcr.io/bamboo-core/telemetria`) + as imagens oficiais do InfluxDB/Explorer,
> orquestradas por um `docker-compose.yml` e um `.env`. A config do Telegraf é
> **extraída de dentro da imagem** e editada no host (passo 1).

## Pré-requisitos

- Docker + Docker Compose na VM do cliente.
- **Disco:** o InfluxDB acumula séries temporais ao longo do tempo — provisione espaço e monitore o volume `influxdb_data`.
- Rede: equipamentos Huawei alcançam a VM na porta `57400/tcp` (dial-out MDT); Juniper alcançável pela VM na porta gNMI (ex.: `32767`).

## 1. Configuração (na VM do cliente — **sem clonar o repo**)

    # diretorio de trabalho com APENAS os arquivos necessarios
    mkdir -p telemetria/secrets telemetria/explorer/config telemetria/explorer/db
    cd telemetria

    # baixar SO o docker-compose.yml e o .env.example (nao clonar o repositorio).
    # repo privado: precisa de acesso/token, ou copie esses 2 arquivos do pacote de deploy.
    curl -fsSLO https://raw.githubusercontent.com/Bamboo-Core/telemetria/main/docker-compose.yml
    curl -fsSL  https://raw.githubusercontent.com/Bamboo-Core/telemetria/main/.env.example -o .env
    echo "SESSION_SECRET=$(openssl rand -hex 32)" >> .env

    # extrair o template de config do Telegraf de DENTRO da imagem (editavel; o
    # compose monta este arquivo). Faca o login no GHCR antes, se a imagem for privada.
    docker run --rm ghcr.io/bamboo-core/telemetria:latest \
      cat /etc/telegraf/telegraf.conf > telegraf.conf

## 2. Bootstrap do token do InfluxDB 3

O InfluxDB 3 Core usa um token admin. O arquivo `secrets/admin-token` é
**JSON** (formato gerado por `influxdb3 create token --admin --format json`),
igual ao usado na VM de referência:
`{"token":"apiv3_...","name":"admin","description":"..."}`.

> ⚠️ **Interpolação:** o `.env` já vem com `INFLUX_TOKEN=` vazio, mas o compose
> exige um valor (o serviço `telegraf` usa `${INFLUX_TOKEN:?}`). Para o passo de
> bootstrap, defina um placeholder primeiro, senão `docker compose` recusa:
>
>     sed -i "s/^INFLUX_TOKEN=.*/INFLUX_TOKEN=bootstrap/" .env

Sequência:

    # 1. placeholder (acima) + arquivo de token inicial
    : > secrets/admin-token
    # 2. sobe SO o InfluxDB para gerar o token
    docker compose up -d influxdb3-core
    # 3. gera o admin token em JSON e salva no arquivo que o InfluxDB consome
    docker exec influxdb3-core influxdb3 create token --admin --format json \
      | tee secrets/admin-token
    # 4. extrai o token (apiv3_...) para o .env (usado pelo Telegraf)
    TOKEN=$(grep -o 'apiv3_[A-Za-z0-9]*' secrets/admin-token | head -1)
    sed -i "s/^INFLUX_TOKEN=.*/INFLUX_TOKEN=$TOKEN/" .env
    # 5. reinicia o InfluxDB lendo o token via --admin-token-file e sobe o resto
    docker compose up -d

> **Nota:** o InfluxDB 3 Core exige CPU com instruções modernas (AVX). Em VMs
> com CPU emulada antiga (ex.: "QEMU Virtual CPU 2.5+") o binário aborta com
> `SIGILL` (exit 132) — use uma VM com CPU host-passthrough/moderna.

## 3. Subir a stack

    docker compose up -d
    docker compose ps
    docker logs telegraf | tail

Acesse o Explorer em `http://<IP_DA_VM>:8888`.

## 4. Configurar coletas

O `docker-compose.yml` monta o `telegraf.conf` que você **extraiu da imagem no
passo 1**. Edite esse arquivo no host e recrie o Telegraf.

- **Host metrics:** já ativas, sem ação.
- **Huawei (MDT):** configurar a telemetria **no equipamento** (dial-out gRPC apontando para `<IP_DA_VM>:57400`). Nada a editar no Telegraf.
- **Juniper (gNMI):**

      # 1. descomentar o bloco [[inputs.gnmi]] e preencher IP/usuario/senha
      nano telegraf.conf

      # 2. aplicar (recria so o Telegraf, relendo o conf editado)
      docker compose up -d --force-recreate telegraf
      docker logs telegraf | tail

> **Sintaxe do gNMI (Telegraf 1.23.4):** a imagem roda o binário Telegraf
> **1.23.4** (build com o plugin Huawei). O plugin gNMI nesta versão usa
> `enable_tls` (não `tls_enable`) e exige blocos `[[inputs.gnmi.subscription]]`
> explícitos — **não** existe `path_guessing_strategy`. O template já vem nesse
> formato; basta descomentar e preencher. Para credenciais **distintas** por
> equipamento, adicione **um bloco `[[inputs.gnmi]]` por equipamento**.

## 5. Verificar dados

    docker exec -it $(docker compose ps -q influxdb3-core) influxdb3 query --database "$INFLUX_DB" --token "$INFLUX_TOKEN" "SHOW TABLES"

As medidas de host (`cpu`, `mem`, `disk`, `system`) devem aparecer nos primeiros minutos — provam o pipeline Telegraf→InfluxDB.

## 6. Hardening — **obrigatório em VM com IP público**

A stack expõe portas que **não podem ficar abertas para a internet**:

| Porta | Serviço | Sentido | Ação |
|---|---|---|---|
| `8888` | Explorer (UI do banco) | entrada | **nunca** expor; VPN/túnel SSH ou bind em localhost |
| `8181` | InfluxDB 3 | entrada | restringir a VPN/IP confiável |
| `57400` | Huawei dial-out (Telegraf, `network_mode: host`) | entrada | liberar **só** para os IPs dos equipamentos |
| gNMI (ex. `32767`) | Juniper | **saída** (VM → device) | não precisa abrir entrada |

> ⚠️ **Docker fura o UFW/iptables:** portas publicadas por containers em rede
> bridge (8181 e 8888) **passam por cima do UFW** por padrão. Não confie só no
> UFW para elas — a forma robusta é **não publicar na interface pública**.

**Recomendado (IP público):** bind do InfluxDB e do Explorer em `127.0.0.1` e
acesso via túnel SSH. No `docker-compose.yml`, troque os mapeamentos de porta:

    # influxdb3-core
    ports: ["127.0.0.1:8181:8181"]
    # influxdb3-explorer
    ports: ["127.0.0.1:8888:8080"]

Acesso à UI a partir da sua máquina:

    ssh -L 8888:127.0.0.1:8888 usuario@<IP_DA_VM>   # abre http://localhost:8888

**Firewall do host** (vale para o `57400` em `network_mode: host` e para o SSH):

    ufw default deny incoming
    ufw allow from <IP_ADMIN/VPN> to any port 22 proto tcp
    ufw allow from <IP_EQUIPAMENTO_HUAWEI> to any port 57400 proto tcp
    ufw enable

## Imagem

A imagem custom do Telegraf é publicada em `ghcr.io/bamboo-core/telemetria` pelo workflow `.github/workflows/publicar-imagem.yml` (push na `main` / tag `v*`). **Este repositório é para build da imagem — não é para ser clonado na VM do cliente** (ver nota no topo e passo 1).

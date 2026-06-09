# Stack de Telemetria — InfluxDB 3 + Explorer + Telegraf (Huawei MDT)

Coleta de telemetria de rede: Telegraf (host + Huawei gRPC MDT + Juniper gNMI) → InfluxDB 3 Core → Explorer (UI). InfluxDB **local em cada cliente**.

## Pré-requisitos

- Docker + Docker Compose na VM do cliente.
- **Disco:** o InfluxDB acumula séries temporais ao longo do tempo — provisione espaço e monitore o volume `influxdb_data`.
- Rede: equipamentos Huawei alcançam a VM na porta `57400/tcp` (dial-out MDT); Juniper alcançável pela VM na porta gNMI (ex.: `32767`).

## 1. Configuração

    git clone git@github.com:Bamboo-Core/telemetria.git && cd telemetria
    cp .env.example .env
    echo "SESSION_SECRET=$(openssl rand -hex 32)" >> .env
    mkdir -p secrets explorer/config explorer/db

## 2. Bootstrap do token do InfluxDB 3

O InfluxDB 3 Core usa um token admin. Gere uma vez e use em todo lugar:

    :> secrets/admin-token
    docker compose up -d influxdb3-core
    docker exec -it $(docker compose ps -q influxdb3-core) influxdb3 create token --admin

Copie o token gerado (formato `apiv3_...`) e grave no arquivo e no .env:

    printf '%s' '<TOKEN_apiv3_AQUI>' > secrets/admin-token
    sed -i "s/^INFLUX_TOKEN=.*/INFLUX_TOKEN=<TOKEN_apiv3_AQUI>/" .env
    docker compose up -d

> A VM de referência usa exatamente `--admin-token-file` apontando para um arquivo com o token.

## 3. Subir a stack

    docker compose up -d
    docker compose ps
    docker logs telegraf | tail

Acesse o Explorer em `http://<IP_DA_VM>:8888`.

## 4. Configurar coletas

- **Host metrics:** já ativas, sem ação.
- **Huawei (MDT):** configurar a telemetria **no equipamento** (dial-out gRPC apontando para `<IP_DA_VM>:57400`). Nada a editar no Telegraf.
- **Juniper (gNMI):** editar `telegraf/telegraf.conf`, descomentar o bloco `inputs.gnmi`, preencher IP/usuário/senha, e `docker compose restart telegraf`.

## 5. Verificar dados

    docker exec -it $(docker compose ps -q influxdb3-core) influxdb3 query --database "$INFLUX_DB" --token "$INFLUX_TOKEN" "SHOW TABLES"

As medidas de host (`cpu`, `mem`, `disk`, `system`) devem aparecer nos primeiros minutos — provam o pipeline Telegraf→InfluxDB.

## Imagem

A imagem custom do Telegraf é publicada em `ghcr.io/bamboo-core/telemetria` pelo workflow `.github/workflows/publicar-imagem.yml` (push na `main` / tag `v*`).

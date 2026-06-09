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

A config (`telegraf.conf`) já vem **embutida na imagem** (host + Huawei MDT +
Juniper comentado). Não precisa de arquivo local para o caso padrão.

- **Host metrics:** já ativas, sem ação.
- **Huawei (MDT):** configurar a telemetria **no equipamento** (dial-out gRPC apontando para `<IP_DA_VM>:57400`). Nada a editar no Telegraf.
- **Juniper (gNMI):** como a config é embutida, para adicionar Juniper você
  **monta um `telegraf.conf` próprio por cima**. Extraia o default da imagem,
  edite o bloco `inputs.gnmi` (descomentar + IP/usuário/senha), e rode o
  Telegraf com `-v $PWD/telegraf.conf:/etc/telegraf/telegraf.conf:ro`:

      docker run --rm ghcr.io/bamboo-core/telemetria:latest \
        cat /etc/telegraf/telegraf.conf > telegraf.conf
      # editar telegraf.conf (bloco inputs.gnmi) e recriar o container telegraf
      # com a flag -v acima (ou docker compose com o volume ja mapeado).

## 5. Verificar dados

    docker exec -it $(docker compose ps -q influxdb3-core) influxdb3 query --database "$INFLUX_DB" --token "$INFLUX_TOKEN" "SHOW TABLES"

As medidas de host (`cpu`, `mem`, `disk`, `system`) devem aparecer nos primeiros minutos — provam o pipeline Telegraf→InfluxDB.

## Imagem

A imagem custom do Telegraf é publicada em `ghcr.io/bamboo-core/telemetria` pelo workflow `.github/workflows/publicar-imagem.yml` (push na `main` / tag `v*`).

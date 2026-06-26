# Design — Pacote de Telemetria do Cliente (tudo em Docker)

**Data:** 2026-06-26
**Contexto:** o passo a passo público (`Bamboo-Core/telemetria`) não corresponde
à stack que de fato funciona na VM base (`172.16.33.7`). Ele manda baixar uma
imagem inexistente no GHCR e usa um compose unificado que não existe — por isso
a instalação na VM do cliente falhou. Este pacote reproduz, de forma limpa e
reproduzível, o que comprovadamente funciona.

## Objetivo

Entregar um pacote que o cliente instala em 1 comando, contendo InfluxDB 3 Core,
Explorer e Telegraf (Huawei + gNMI), do qual o Kuantics puxa telemetria.

## Decisões

- **Tudo em Docker Compose** (em vez de Telegraf systemd nativo) → portável.
- **Imagem Huawei publicada no GHCR** (build feito por nós 1x; cliente só baixa).
- **Paridade com a VM base**, removendo credenciais reais e deixando templates.
- **Token bootstrap via CLI** (`influxdb3 create token --admin`), persistido no
  catálogo (volume de dados) — evita o footgun de montar JSON como
  `--admin-token-file`.

## Arquitetura

Quatro serviços em um `docker-compose.yml`:

| Serviço | Imagem | Porta | Papel |
|---|---|---|---|
| influxdb3-core | `influxdb:3-core` | 8181 | Banco de séries temporais |
| influxdb3-explorer | `influxdata/influxdb3-ui:1.8.0` | 8888 | UI web |
| telegraf-huawei | `ghcr.io/bamboo-core/telegraf-huawei` | 57400 (host) | Coleta passiva Huawei MDT |
| telegraf-gnmi | `telegraf:1.32` | — | Coleta ativa gNMI + métricas locais |
| gnmic-nokia (perfil `nokia`) | `ghcr.io/openconfig/gnmic` | host | Nokia dial-out (opcional) |

### Duas frentes de coleta
- **Huawei (passiva):** equipamentos empurram para `:57400`. Imagem custom com o
  plugin gRPC Huawei (compilado do fonte). Sem cadastro por-equipamento.
- **gNMI (ativa/manual):** a VM conecta em cada device. Cada equipamento é um
  bloco `[[inputs.gnmi]]` em `telegraf.d/`, copiado de `exemplos/`.

## Fluxo do instalar.sh
1. Verifica Docker/Compose.
2. Cria `.env` e gera `SESSION_SECRET`.
3. Sobe `influxdb3-core`, espera `/health`.
4. Gera token admin (1ª vez), grava em `.env` e `secrets/admin-token`.
5. Cria database `telemetria`.
6. Sobe o restante e imprime acesso + dados do Kuantics.

Idempotente: se o token já existe no `.env`, não recria.

## Tratamento de credenciais
- `telegraf-gnmi.conf` mantém toda a engenharia (aliases, subscriptions,
  processors de colisão tag/field do IOx) **sem IP/senha reais**.
- Devices reais viram `exemplos/*.exemplo`; credenciais via `${VARS}` no `.env`.
- `.gitignore` bloqueia `.env`, `secrets/`, `data/`.

## Conexão Kuantics
- `http://IP_DA_VM:8181`, database `telemetria`, token de `secrets/admin-token`.

## Fora de escopo
- Build/publicação automática da imagem no GHCR (entregue como `build/publicar.sh`
  para execução manual interna).
- Hardening de rede (firewall) — pode ser adicionado depois.

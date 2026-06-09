# Stack de Telemetria Containerizada — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Empacotar a stack de telemetria (InfluxDB 3 + Explorer + Telegraf custom com plugin Huawei MDT) num deploy reproduzível e publicável no GHCR, com InfluxDB local por cliente.

**Architecture:** Um `docker-compose` com três serviços — `influxdb3-core` e `influxdb3-explorer` (imagens oficiais) e `telegraf` (imagem custom publicada em `ghcr.io/bamboo-core/telemetria`, com o plugin Huawei compilado do fonte). O `telegraf.conf` é montado/editável na VM do cliente (Juniper manual; Huawei configurado no equipamento; host metrics prontos). Token do InfluxDB via `.env` (sem hardcode).

**Tech Stack:** Docker, Docker Compose, InfluxDB 3 Core, Telegraf 1.23.4 (build custom Go), GitHub Actions, GHCR.

**Spec de referência:** `docs/specs/2026-06-09-stack-telemetria-container-design.md`

---

## Ambiente de execução (ler antes de começar)

- **Repositório (entregável):** `/Users/suporte/Projetos/telemetria-deploy` (git init, branch `main`, `.gitignore` já criado).
- **VM de referência (fonte dos artefatos provados):** `telegraf-rfs` = `172.16.33.7`, usuário `telegraf`, chave SSH já instalada. Docker roda **sem sudo** (usuário no grupo docker). Acesso: `ssh telegraf@172.16.33.7 '<cmd>'`. **NÃO derrubar/alterar** os containers em produção lá (`influxdb3-core`, `telegraf-huawei`, `isp-probe`).
- **VM de smoke test:** `192.145.216.144` (usuário `nocia`, chave instalada; docker via `sudo` — helper `/tmp/sshsudo.exp '<cmd>'`). Usar portas alternativas pra não colidir.
- **Org GitHub:** `Bamboo-Core`. Push via SSH (`git@github.com:Bamboo-Core/telemetria.git`). Imagem alvo: `ghcr.io/bamboo-core/telemetria`.
- **Arquivos-fonte na VM** (`~telegraf/huawei-telegraf/`): `Dockerfile`, `generate_paths.go`, `telegraf.conf`, e `/etc/telegraf/telegraf.d/fix_fields.conf`.

---

## Estrutura de arquivos (repo `telemetria-deploy/`)

| Arquivo | Responsabilidade |
|---|---|
| `Dockerfile` | Build multi-stage do Telegraf 1.23.4 + plugin Huawei (copiado da VM) |
| `generate_paths.go` | Script Go usado no build do plugin Huawei (copiado da VM) |
| `telegraf/telegraf.conf` | Config consolidada: host + Huawei MDT + output + Juniper (comentado) |
| `telegraf/telegraf.d/fix_fields.conf` | Processadores starlark do Juniper (copiado da VM) |
| `docker-compose.yml` | Sobe influxdb3-core + explorer + telegraf, parametrizado por `.env` |
| `.env.example` | Parâmetros por cliente (token, db, portas, session secret) |
| `.github/workflows/publicar-imagem.yml` | Build + push da imagem telegraf no GHCR |
| `README.md` | Runbook de deploy, bootstrap do token, config Juniper/Huawei, disco |

---

## Fase 1 — Trazer os artefatos provados da VM

### Task 1: Copiar Dockerfile, generate_paths.go e fix_fields.conf

**Files:**
- Create: `Dockerfile`, `generate_paths.go`, `telegraf/telegraf.d/fix_fields.conf` (copiados da VM)

- [ ] **Step 1: Criar a pasta telegraf/telegraf.d e proteger segredos no .gitignore**

```bash
mkdir -p /Users/suporte/Projetos/telemetria-deploy/telegraf/telegraf.d
cd /Users/suporte/Projetos/telemetria-deploy
# garante que segredos/dados NUNCA sejam commitados
printf 'node_modules/\n.env\n*.log\nsecrets/\nexplorer/db/\nexplorer/config/\ninfluxdb_data/\n' > .gitignore
git add .gitignore && git commit -m "chore: gitignore cobre secrets/ e dados locais"
```

- [ ] **Step 2: Copiar os 3 artefatos da VM via scp**

```bash
cd /Users/suporte/Projetos/telemetria-deploy
scp telegraf@172.16.33.7:'~/huawei-telegraf/Dockerfile' ./Dockerfile
scp telegraf@172.16.33.7:'~/huawei-telegraf/generate_paths.go' ./generate_paths.go
scp telegraf@172.16.33.7:'/etc/telegraf/telegraf.d/fix_fields.conf' ./telegraf/telegraf.d/fix_fields.conf
```

- [ ] **Step 3: Conferir que chegaram e não estão vazios**

```bash
wc -l Dockerfile generate_paths.go telegraf/telegraf.d/fix_fields.conf
```
Expected: `Dockerfile` ~90 linhas, `generate_paths.go` ~46 linhas, `fix_fields.conf` > 5 linhas.

- [ ] **Step 4: Ajustar o Dockerfile — a etapa final COPIA `./telegraf.conf`, mas no repo a config fica montada (não embutida)**

O Dockerfile original termina com `COPY ./telegraf.conf /etc/telegraf/telegraf.conf`. Como vamos **montar** a config por volume, remover essa linha pra a imagem não embutir uma config fixa. Editar o `Dockerfile`: localizar o bloco final e remover **apenas** a linha do COPY da config:

```dockerfile
FROM telegraf:1.23.4
COPY --from=git-telegraf-huawei /opt/telegraf/telegraf /usr/bin/telegraf
CMD ["telegraf"]
```
(ou seja, manter o `COPY --from=...` do binário e o `CMD`; remover o `COPY ./telegraf.conf ...`)

- [ ] **Step 5: Commit**

```bash
git add Dockerfile generate_paths.go telegraf/telegraf.d/fix_fields.conf
git commit -m "feat: artefatos de build do telegraf huawei (copiados da VM de referencia)"
```

---

## Fase 2 — Config consolidada do Telegraf

### Task 2: `telegraf/telegraf.conf` (host + Huawei MDT + output + Juniper comentado)

**Files:**
- Create: `telegraf/telegraf.conf`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```toml
###############################################################################
# Telegraf — stack de telemetria (host + Huawei MDT + Juniper gNMI)
# Config MONTADA e editavel na VM do cliente. Editar para adicionar Juniper.
###############################################################################
[agent]
  interval = "10s"
  flush_interval = "10s"
  metric_batch_size = 5000
  metric_buffer_limit = 50000
  hostname = "telegraf"
  omit_hostname = false
  debug = false

###############################################################################
# OUTPUT — InfluxDB 3 Core (token e bucket via .env)
###############################################################################
[[outputs.influxdb_v2]]
  urls = ["http://localhost:8181"]
  token = "${INFLUX_TOKEN}"
  organization = ""
  bucket = "${INFLUX_DB}"

###############################################################################
# INPUTS — métricas do host (sempre ativos; provam o pipeline sem equipamento)
###############################################################################
[[inputs.cpu]]
  percpu = false
  totalcpu = true
[[inputs.mem]]
[[inputs.disk]]
  mount_points = ["/"]
[[inputs.system]]

###############################################################################
# INPUT — Huawei gRPC MDT dial-out (porta 57400). Equipamento empurra os dados;
# nada a configurar aqui alem do listener. Configurar telemetry no equipamento.
###############################################################################
[[inputs.huawei_telemetry_dialout]]
  service_address = ":57400"
  data_format = "json"
  transport = "grpc"

###############################################################################
# INPUT — Juniper gNMI dial-in. PREENCHER MANUALMENTE: descomentar e ajustar
# IP/usuario/senha (variaveis JUNIPER_USER/JUNIPER_PASS no .env ou inline).
###############################################################################
#[[inputs.gnmi]]
#  addresses = ["IP_DO_JUNIPER:32767"]
#  username = "${JUNIPER_USER}"
#  password = "${JUNIPER_PASS}"
#  encoding = "proto"
#  redial = "10s"
#  tls_enable = true
#  insecure_skip_verify = true
#  path_guessing_strategy = "subscription"
#  [inputs.gnmi.aliases]
#    juniper_if_counters  = "/interfaces/interface/state/counters"
#    juniper_if_state     = "/interfaces/interface/state"
#    juniper_components   = "/components/component/state"
#    juniper_bgp_neighbor = "/network-instances/network-instance/protocols/protocol/bgp/neighbors/neighbor/state"
#    juniper_lacp         = "/lacp/interfaces/interface/state"
#    juniper_lc_firewall  = "/junos/firewall"
#    juniper_lc_fabric    = "/junos/fabric-statistics"
#    juniper_lc_optics    = "/interfaces/interface/optics"
#    juniper_lc_cpu_memory  = "/components/component[name=FPC0:CPU0]/properties"
#    juniper_lc_npu_memory  = "/components/component[name=FPC0:NPU0]/properties"

###############################################################################
# PROCESSORS — Huawei: converte node_id_str em tag host
###############################################################################
[[processors.converter]]
  [processors.converter.fields]
    tag = ["node_id_str"]

[[processors.rename]]
  order = 1
  [[processors.rename.replace]]
    tag = "node_id_str"
    dest = "host"
```

- [ ] **Step 2: Commit**

```bash
git add telegraf/telegraf.conf
git commit -m "feat: telegraf.conf consolidado (host + huawei MDT + juniper comentado)"
```

---

## Fase 3 — Compose e parâmetros

### Task 3: `docker-compose.yml`

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```yaml
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
    networks:
      - telemetria

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
    depends_on:
      - influxdb3-core
    networks:
      - telemetria

  telegraf:
    image: ghcr.io/bamboo-core/telemetria:latest
    container_name: ${TELEGRAF_NAME:-telegraf}
    network_mode: host
    environment:
      - INFLUX_TOKEN=${INFLUX_TOKEN:?defina INFLUX_TOKEN no .env}
      - INFLUX_DB=${INFLUX_DB:-telemetria}
    volumes:
      - ./telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro
      - ./telegraf/telegraf.d:/etc/telegraf/telegraf.d:ro
    restart: unless-stopped

volumes:
  influxdb_data:
  influxdb_plugins:
  explorer_db:

networks:
  telemetria:
    driver: bridge
```

> Nota: `telegraf` usa `network_mode: host` (escuta 57400 no IP da VM e alcança o InfluxDB em `localhost:8181`). Por isso não declara `networks`.

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker-compose da stack (influxdb3 + explorer + telegraf)"
```

---

### Task 4: `.env.example`

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```env
# Token admin do InfluxDB 3 — gerar no bootstrap (ver README) e colar aqui.
# Usado pelo InfluxDB (admin-token) E pelo output do Telegraf.
INFLUX_TOKEN=

# Banco/bucket de destino
INFLUX_DB=telemetria

# Segredo de sessao do Explorer (gerar: openssl rand -hex 32)
SESSION_SECRET=

# Portas (defaults)
INFLUX_PORT=8181
EXPLORER_PORT=8888

# (Opcional) nomes dos containers, se precisar evitar colisao no host
# INFLUX_NAME=influxdb3-core
# EXPLORER_NAME=influxdb3-explorer
# TELEGRAF_NAME=telegraf

# (Opcional) credenciais Juniper, se for referenciar no telegraf.conf
# JUNIPER_USER=
# JUNIPER_PASS=
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "docs: .env.example com parametros por cliente"
```

---

## Fase 4 — Publicação no GHCR

### Task 5: Workflow GitHub Actions

**Files:**
- Create: `.github/workflows/publicar-imagem.yml`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```yaml
name: publicar-imagem

# Builda e publica a imagem custom do Telegraf no GHCR a cada push na main,
# tag v*, ou manualmente. Usa o GITHUB_TOKEN do proprio repo.

on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:

jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Login no GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Metadata (tags e labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=ref,event=tag
            type=sha,format=short

      - name: Build e push
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          build-args: |
            CACHE_BUST=${{ github.sha }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

> `github.repository` = `Bamboo-Core/telemetria`; a metadata-action normaliza para minúsculas → `ghcr.io/bamboo-core/telemetria`. O `CACHE_BUST` é exigido pelo Dockerfile (ARG) para refazer a patch dos protos.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/publicar-imagem.yml
git commit -m "ci: publica imagem telegraf custom no GHCR via GitHub Actions"
```

---

## Fase 5 — README (runbook)

### Task 6: `README.md`

**Files:**
- Create: `README.md`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

````markdown
# Stack de Telemetria — InfluxDB 3 + Explorer + Telegraf (Huawei MDT)

Coleta de telemetria de rede: Telegraf (host + Huawei gRPC MDT + Juniper gNMI)
→ InfluxDB 3 Core → Explorer (UI). InfluxDB **local em cada cliente**.

## Pré-requisitos

- Docker + Docker Compose na VM do cliente.
- **Disco:** o InfluxDB acumula séries temporais ao longo do tempo — provisione
  espaço e monitore o volume `influxdb_data`.
- Rede: equipamentos Huawei alcançam a VM na porta `57400/tcp` (dial-out MDT);
  Juniper alcançável pela VM na porta gNMI (ex.: `32767`).

## 1. Configuração

```bash
git clone git@github.com:Bamboo-Core/telemetria.git && cd telemetria
cp .env.example .env
# gerar o segredo do Explorer:
echo "SESSION_SECRET=$(openssl rand -hex 32)" >> .env   # ou editar manualmente
mkdir -p secrets explorer/config explorer/db
```

## 2. Bootstrap do token do InfluxDB 3

O InfluxDB 3 Core usa um token admin. Gere uma vez e use em todo lugar:

```bash
# sobe so o InfluxDB temporariamente sem token para criar o admin token
docker compose run --rm --no-deps --entrypoint influxdb3 influxdb3-core \
  create token --admin 2>/dev/null || true
```

Se o comando acima não retornar o token (depende da versão), o método garantido:

```bash
# 1. cria um arquivo de token vazio para o primeiro start
:> secrets/admin-token
docker compose up -d influxdb3-core
# 2. gera o admin token dentro do container
docker exec -it $(docker compose ps -q influxdb3-core) \
  influxdb3 create token --admin
```

Copie o token gerado (formato `apiv3_...`) e:

```bash
# grava no arquivo que o InfluxDB consome e no .env (Telegraf)
printf '%s' '<TOKEN_apiv3_AQUI>' > secrets/admin-token
sed -i "s/^INFLUX_TOKEN=.*/INFLUX_TOKEN=<TOKEN_apiv3_AQUI>/" .env
docker compose up -d   # sobe a stack inteira ja com o token
```

> Referência: a VM `telegraf-rfs` usa exatamente `--admin-token-file` apontando
> para um arquivo com o token. Replicamos esse mecanismo aqui.

## 3. Subir a stack

```bash
docker compose up -d
docker compose ps
docker logs telegraf | tail        # deve conectar no InfluxDB sem erro de write
```

Acesse o Explorer em `http://<IP_DA_VM>:8888`.

## 4. Configurar coletas

- **Host metrics:** já ativas, sem ação.
- **Huawei (MDT):** configurar a telemetria **no equipamento** (dial-out gRPC
  apontando para `<IP_DA_VM>:57400`). Nada a editar no Telegraf.
- **Juniper (gNMI):** editar `telegraf/telegraf.conf`, descomentar o bloco
  `inputs.gnmi`, preencher IP/usuário/senha, e `docker compose restart telegraf`.

## 5. Verificar dados

```bash
# lista tabelas/medidas no banco
docker exec -it $(docker compose ps -q influxdb3-core) influxdb3 query \
  --database "$INFLUX_DB" --token "$INFLUX_TOKEN" "SHOW TABLES"
```
As medidas de host (`cpu`, `mem`, `disk`, `system`) devem aparecer já nos
primeiros minutos — provam o pipeline Telegraf→InfluxDB.

## Imagem

A imagem custom do Telegraf é publicada em `ghcr.io/bamboo-core/telemetria`
pelo workflow `.github/workflows/publicar-imagem.yml` (push na `main` / tag `v*`).
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README com runbook, bootstrap de token e config de coletas"
```

---

## Fase 6 — Publicar e validar (smoke test do pipeline)

> O build da imagem (compila Telegraf do fonte) é pesado e roda no **CI**. O smoke test puxa a imagem publicada e valida o **núcleo do pipeline** (host metrics → InfluxDB → Explorer). MDT/Juniper exigem equipamento real → validados no cliente.

### Task 7: Push do repo + disparar publicação

**Files:** nenhum

- [ ] **Step 1: Criar o repo `Bamboo-Core/telemetria` no GitHub** (web ou gh). Vazio, sem README.

- [ ] **Step 2: Adicionar remote e push**

```bash
cd /Users/suporte/Projetos/telemetria-deploy
git remote add origin git@github.com:Bamboo-Core/telemetria.git 2>/dev/null || \
  git remote set-url origin git@github.com:Bamboo-Core/telemetria.git
git push -u origin main
```

- [ ] **Step 3: Acompanhar o Actions até ficar verde**

```
https://github.com/Bamboo-Core/telemetria/actions
```
Expected: run "publicar-imagem" verde; imagem `ghcr.io/bamboo-core/telemetria:latest` publicada. (O build compila Telegraf do fonte — pode levar vários minutos.)

- [ ] **Step 4: Tornar o pacote PÚBLICO no GHCR**
`https://github.com/orgs/Bamboo-Core/packages` → pacote **telemetria** → Package settings → Change visibility → **Public**.

---

### Task 8: Smoke test na VM de staging (192.145.216.144)

> Usa portas alternativas (`18181`/`18888`) e nomes próprios pra não colidir. Valida que a imagem publicada sobe e o pipeline host→influx funciona.

**Files:** nenhum (operação de validação)

- [ ] **Step 1: Copiar o pacote pra VM de staging**

```bash
cd /Users/suporte/Projetos/telemetria-deploy
ssh nocia@192.145.216.144 'mkdir -p ~/telemetria-test/telegraf/telegraf.d ~/telemetria-test/secrets ~/telemetria-test/explorer/config ~/telemetria-test/explorer/db'
scp docker-compose.yml .env.example nocia@192.145.216.144:~/telemetria-test/
scp telegraf/telegraf.conf nocia@192.145.216.144:~/telemetria-test/telegraf/
scp telegraf/telegraf.d/fix_fields.conf nocia@192.145.216.144:~/telemetria-test/telegraf/telegraf.d/
```

- [ ] **Step 2: Criar `.env` de teste (portas alternativas, secret de teste)**

```bash
ssh nocia@192.145.216.144 'cat > ~/telemetria-test/.env <<EOF
INFLUX_TOKEN=
INFLUX_DB=telemetria
SESSION_SECRET=$(openssl rand -hex 32)
INFLUX_PORT=18181
EXPLORER_PORT=18888
INFLUX_NAME=influx-smoke
EXPLORER_NAME=explorer-smoke
TELEGRAF_NAME=telegraf-smoke
EOF'
```

- [ ] **Step 3: Bootstrap do token (gerar admin token e gravar em .env + secrets/admin-token)**

```bash
/tmp/sshsudo.exp 'cd /home/nocia/telemetria-test && : > secrets/admin-token && docker compose up -d influx-smoke'
sleep 5
/tmp/sshsudo.exp 'cd /home/nocia/telemetria-test && docker exec influx-smoke influxdb3 create token --admin 2>&1 | tail -3'
```
Expected: imprime um token `apiv3_...`. Copiar esse token para o próximo passo.

- [ ] **Step 4: Gravar o token e subir a stack completa**

```bash
/tmp/sshsudo.exp 'cd /home/nocia/telemetria-test && printf "%s" "<TOKEN_apiv3>" > secrets/admin-token && sed -i "s/^INFLUX_TOKEN=.*/INFLUX_TOKEN=<TOKEN_apiv3>/" .env && docker compose up -d'
sleep 8
/tmp/sshsudo.exp 'cd /home/nocia/telemetria-test && docker compose ps --format "{{.Name}} {{.Status}}"'
```
Expected: `influx-smoke`, `explorer-smoke`, `telegraf-smoke` todos `Up`.

- [ ] **Step 5: Confirmar que o Telegraf escreve host metrics no InfluxDB**

```bash
/tmp/sshsudo.exp 'cd /home/nocia/telemetria-test && sleep 20 && docker exec influx-smoke influxdb3 query --database telemetria --token "<TOKEN_apiv3>" "SHOW TABLES"'
```
Expected: aparecem medidas de host (`cpu`, `mem`, `disk`, `system`) — prova o pipeline Telegraf→InfluxDB.

- [ ] **Step 6: Confirmar Explorer no ar**

```bash
ssh nocia@192.145.216.144 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:18888'
```
Expected: `200` (ou `3xx` de redirect de login) — UI servindo.

- [ ] **Step 7: Teardown**

```bash
/tmp/sshsudo.exp 'cd /home/nocia/telemetria-test && docker compose down -v'
ssh nocia@192.145.216.144 'rm -rf ~/telemetria-test'
```
Expected: containers/volumes de teste removidos.

---

## Critérios de sucesso (do spec)

- [ ] `docker compose up -d` sobe os três serviços (imagem custom puxada do GHCR) — Task 8.4.
- [ ] InfluxDB 3 inicializa com token do `.env` (sem hardcode) e banco `telemetria` — Task 8.3-8.4.
- [ ] Telegraf escreve **host metrics** no `telemetria` (visível via query) — Task 8.5.
- [ ] Explorer acessível na porta configurada — Task 8.6.
- [ ] `telegraf.conf` montado/editável; bloco Juniper comentado/pronto — Task 2 / Task 3.
- [ ] Listener MDT (57400) presente — Task 2.
- [ ] Imagem `ghcr.io/bamboo-core/telemetria` publicada e pública — Task 7.
- [ ] Pacote sobe noutra VM só mudando `.env` — Task 8 (na staging).

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Build Go do Telegraf falhar no CI (deps antigas Buster/proto) | Dockerfile é o **provado na VM**; `CACHE_BUST` força repatch; logs do Actions guiam ajuste |
| Mecanismo do admin token do InfluxDB 3 divergir | Bootstrap explícito (Task 8.3) via `influxdb3 create token --admin`, replicando o `--admin-token-file` da VM |
| `network_mode: host` + InfluxDB bridge não se enxergarem | Telegraf alcança InfluxDB via `localhost:8181` (porta publicada) — validado na Task 8.5 |
| Disco enchendo (InfluxDB stateful) | Volume nomeado `influxdb_data` + alerta no README |
| Colisão de portas/nomes na VM de smoke test | Portas `18181/18888` e nomes `*-smoke` (Task 8.2) |

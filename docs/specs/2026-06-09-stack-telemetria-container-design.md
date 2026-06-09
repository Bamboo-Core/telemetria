# Design — Stack de telemetria containerizada (Opção A)

**Data:** 2026-06-09
**Autor:** phoffmann@nocai.io (com Claude Code)
**Status:** Aprovado para planejamento

---

## 1. Contexto

A VM `telegraf-rfs` (`172.16.33.7`) roda uma stack de telemetria de rede que **não**
corresponde ao repo `monitoring-stack` (que usa InfluxDB 2.7 + auto-discovery SNMP). O que
realmente roda é:

```
[Equipamentos] → [Telegraf / gnmic] → [InfluxDB 3 Core] → [Explorer]
```

| Componente | Como roda hoje | Porta | Função |
|---|---|---|---|
| InfluxDB 3 Core | Docker (`influxdb:3-core`) | 8181 | banco de séries temporais |
| InfluxDB Explorer | Docker (`influxdata/influxdb3-ui:1.8.0`) | 8888 | UI web |
| Telegraf | **systemd nativo** (ativo) | 57400/57600 | host metrics + Juniper gNMI dial-in |
| `telegraf-huawei` | Docker (build custom, Telegraf 1.23.4) | 57400 | MDT Cisco/Huawei |
| gnmic | **systemd nativo** (inativo) | 57700 | Nokia (desligado) |

**Problemas do estado atual:** dois Telegraf (systemd + container) com configs separadas,
gnmic morto, e o **token do InfluxDB hardcoded** em múltiplos lugares (`gnmic.yaml`, docs).

## 2. Objetivo e escopo

Empacotar a **stack inteira** num deploy reproduzível e **publicável no GHCR** (modelo
bastion/probe), com **InfluxDB local em cada cliente**, consolidando a bagunça atual num
pacote limpo — **sem mudar o jeito de configurar** os equipamentos.

**Decisões tomadas:**

| Decisão | Escolha |
|---|---|
| Abordagem | **A — Consolidar + publicar** (um compose limpo, um único Telegraf) |
| InfluxDB | **Local em cada cliente** (dados ficam na infra do cliente) |
| gnmic (Nokia) | **Fora do pacote** (não há Nokia em uso) |
| Imagem custom | `ghcr.io/bamboo-core/telemetria` (o Telegraf custom) |
| Config do Telegraf | **Montada e editável** na VM do cliente (não embutida na imagem) |

**Diretrizes do cliente sobre configuração:**
- **Juniper** (gNMI dial-in) → configurado **manualmente** no `telegraf.conf` após instalar.
- **Huawei/Cisco** (MDT dial-out) → configurado **no próprio equipamento** (aponta para
  `IP_DA_VM:57600/57400`); no Telegraf basta o listener já pronto.
- **Host metrics** → já prontos no config, sem ação.

**Fora de escopo:** modernizar o Telegraf (manter o build custom 1.23.4 que funciona para
MDT Huawei); auto-discovery SNMP do `monitoring-stack`; Grafana; gnmic/Nokia.

## 3. Arquitetura do pacote

Um `docker-compose` com três serviços:

| Serviço | Imagem | Porta | Estado |
|---|---|---|---|
| `influxdb3-core` | `influxdb:3-core` (oficial) | 8181 | stateful (volume) |
| `influxdb3-explorer` | `influxdata/influxdb3-ui` (oficial) | 8888 | config em volume |
| `telegraf` | **`ghcr.io/bamboo-core/telemetria`** (custom) | 57400 (host, MDT Huawei) | config montada/editável |

```
Equipamentos:
  Huawei       --(MDT dial-out)--> :57400          ┐
  Juniper      --(gNMI dial-in, manual)---------->  ├─ telegraf (net=host)
  host da VM   --(cpu/mem/disk/system)----------->  ┘
                                                     │ outputs.influxdb_v2 → localhost:8181
                                                     ▼
                                        influxdb3-core (8181) ──→ explorer (8888)
```

## 4. Configuração e segredos

Tudo parametrizado por `.env` (elimina o token hardcoded):

| Var | Default | Função |
|---|---|---|
| `INFLUX_TOKEN` | (obrigatória) | token admin — consumido pelo InfluxDB (`--admin-token-file`) **e** pelo output do Telegraf |
| `INFLUX_DB` | `telemetria` | banco/bucket |
| `SESSION_SECRET` | (obrigatória) | segredo de sessão do Explorer |
| `INFLUX_PORT` | `8181` | porta da API do InfluxDB |
| `EXPLORER_PORT` | `8888` | porta da UI |
| `MDT_PORT_HUAWEI` | `57400` | listener MDT Huawei (`huawei_telemetry_dialout`) |

- **Token: fonte única.** O `INFLUX_TOKEN` do `.env` é escrito no arquivo consumido pelo
  `influxdb3-core` (`--admin-token-file`) e reusado no `outputs.influxdb_v2` do Telegraf.
  Nada de token hardcoded.

### Config do Telegraf (ponto-chave)

- `telegraf.conf` (+ `telegraf.d/`) é **montado de um diretório na VM** (bind volume),
  **não** embutido na imagem → o operador edita à mão pós-deploy.
- Vem **pronto**: inputs de host (cpu/mem/disk/system), `outputs.influxdb_v2`, e os
  **listeners MDT** Cisco/Huawei.
- Vem **comentado** (exemplo a preencher): bloco `inputs.gnmi` para Juniper — o operador
  descomenta e preenche IP/usuário/senha dos Juniper.

## 5. Persistência

- `influxdb_data` em **volume nomeado** → sobrevive a restart/upgrade.
- Config/db do Explorer em volume.
- ⚠️ Stateful e crescente: o README alerta sobre **espaço em disco** na VM do cliente
  (séries temporais acumulam).

## 6. Rede

- `telegraf` em **`network_mode: host`** (como hoje): precisa escutar as portas MDT no IP da
  VM (equipamentos fazem dial-out para lá) e alcança o InfluxDB em `localhost:8181`.
- `influxdb3-core` + `explorer` em rede bridge, com portas publicadas (`8181`, `8888`).

## 7. Imagem custom (artefato publicável)

- Mantém o build atual: **Telegraf 1.23.4 compilado do fonte** (necessário para o MDT
  Huawei, que o Telegraf oficial não cobre garantidamente).
- Publicada no **GHCR** como `ghcr.io/bamboo-core/telemetria` via **GitHub Actions**
  (a cada push na `main` e tag `v*`), igual ao bastion/probe.
- `influxdb3-core`, `explorer` usam **imagens oficiais** (sem build).
- O repo `Bamboo-Core/telemetria` contém o compose, `.env.example`, `telegraf.conf` base,
  Dockerfile do Telegraf e docs.

## 8. Deploy no cliente (runbook)

1. `cp .env.example .env` → gerar `INFLUX_TOKEN` e `SESSION_SECRET` fortes.
2. `docker compose up -d` (puxa `telemetria` do GHCR + influx/explorer oficiais).
3. Editar `telegraf.conf` → descomentar/preencher os alvos **Juniper** (manual).
4. Configurar **Huawei/Cisco** no equipamento (dial-out → `IP_DA_VM:57600/57400`).
5. Validar: Explorer em `:8888`; métricas de **host** já no banco `telemetria`.

## 9. Validação (smoke test)

- O **núcleo do pipeline** é testável sem equipamento: subir a stack, confirmar
  `influxdb3-core` no ar, `telegraf` escrevendo **host metrics** no banco `telemetria`,
  e o Explorer acessível. Isso prova `Telegraf → InfluxDB → Explorer`.
- **MDT (Huawei/Cisco) e Juniper gNMI** dependem de equipamento real empurrando dados →
  validados **no cliente**, não no smoke test.

## 10. Critérios de sucesso

- [ ] `docker compose up -d` sobe os três serviços (imagem custom puxada do GHCR).
- [ ] InfluxDB 3 inicializa com o token do `.env` (sem hardcode) e o banco `telemetria`.
- [ ] Telegraf escreve **host metrics** no `telemetria` (visível no Explorer / via query).
- [ ] Explorer acessível na porta configurada.
- [ ] `telegraf.conf` é editável na VM (bind volume) e o bloco Juniper está comentado/pronto.
- [ ] Listeners MDT (57400/57600) escutando no host.
- [ ] Imagem `ghcr.io/bamboo-core/telemetria` publicada e puxável.
- [ ] Pacote sobe noutra VM só alterando o `.env`.

## 11. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| MDT Huawei não funcionar fora do build custom | Manter o build 1.23.4 do fonte (não modernizar) |
| Token exposto (hoje hardcoded) | Fonte única via `.env`, fora do git (`.gitignore`) |
| Disco enchendo (InfluxDB stateful) | Alerta no README + volume nomeado dedicado |
| Build Go do Telegraf demorado/instável | Buildar no CI (GitHub Actions) e publicar imagem pronta; cliente só puxa |
| Mesclar as 2 configs de Telegraf (systemd + huawei) | Consolidar num `telegraf.conf` único, validar host-metrics no smoke test |
| Portas MDT precisam de net=host | `network_mode: host` no serviço telegraf (como já é hoje) |

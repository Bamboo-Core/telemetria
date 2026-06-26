# Stack de Telemetria — InfluxDB 3 + Explorer + Telegraf (Huawei + gNMI)

Pacote pronto para instalar na VM do cliente. Coleta telemetria de equipamentos
de rede e armazena no InfluxDB 3 Core, de onde o **Kuantics** puxa os dados.

```
[Equipamentos] → [Telegraf na VM] → [InfluxDB 3 Core] → [Explorer / Kuantics]
```

Há **duas frentes de coleta**, independentes:

| Frente | Como funciona | Equipamentos | Onde configurar |
|---|---|---|---|
| **Huawei (passiva)** | O equipamento **empurra** os dados para a VM (dial-out gRPC) | Huawei VRP | Nada por-equipamento na VM; aponte o `telemetry` do Huawei para `IP_DA_VM:57400` |
| **gNMI (ativa/manual)** | A VM **conecta** em cada equipamento (dial-in) | Juniper, Arista, Cisco, Nokia | Cadastre cada equipamento copiando um modelo de `exemplos/` para `telegraf.d/` |

---

## Pré-requisitos

- Linux (testado em Ubuntu 24.04) com **Docker** e **Docker Compose v2**
- Portas livres na VM: `8181` (InfluxDB), `8888` (Explorer), `57400` (Huawei dial-out)
- Acesso de saída para `ghcr.io` (baixar a imagem do Telegraf-Huawei)

Verifique:
```bash
docker --version
docker compose version
```

---

## Instalação (1 comando)

```bash
git clone https://github.com/Bamboo-Core/telemetria telemetria
cd telemetria
./instalar.sh
```

O `instalar.sh` é idempotente e faz tudo: cria o `.env`, gera o token admin e o
`SESSION_SECRET`, cria o database `telemetria` e sobe todos os serviços. Ao final
ele imprime as URLs de acesso e os dados para cadastrar no Kuantics.

> A imagem do Telegraf-Huawei (`ghcr.io/bamboo-core/telemetria:latest`) já está
> **publicada e pública** no GHCR — o cliente só baixa, não compila nada. A pasta
> `build/` só serve se um dia for preciso **atualizar** essa imagem.

Ao final, o `instalar.sh` imprime na tela um quadro **"CADASTRE ESTES DADOS NO
KUANTICS"** com o Host, o Database e o **token** já preenchidos.

---

## Como o Telegraf se conecta ao InfluxDB (automático)

**Você não precisa fazer nada manual para ligar o Telegraf ao banco** — o
`instalar.sh` já faz essa amarração:

1. Gera o token admin do InfluxDB e grava em `.env` (`INFLUX_TOKEN`).
2. O `docker-compose.yml` injeta esse token + a URL + o database nos dois
   coletores via variáveis de ambiente:
   - `telegraf-huawei` → `INFLUX_URL=http://127.0.0.1:8181` (rede do host)
   - `telegraf-gnmi`   → `INFLUX_URL=http://influxdb3-core:8181` (rede interna)
3. Cada `telegraf-*.conf` tem um bloco `[[outputs.influxdb_v2]]` que usa essas
   variáveis. Ou seja: subiu a stack, o Telegraf já está escrevendo no banco.

**Conferir que os dados estão chegando** (deve listar tabelas como `cpu`, `mem`):
```bash
docker exec influxdb3-core influxdb3 query \
  --database telemetria \
  --token "$(cat secrets/admin-token)" \
  "SHOW TABLES"
```
Se aparecerem tabelas, o vínculo Telegraf → InfluxDB está funcionando.

---

## Cadastrar equipamentos gNMI (Juniper / Arista / Cisco)

1. Preencha as credenciais no `.env` (`JUNIPER_USER`, `ARISTA_USER`, ...).
2. Copie o modelo do fabricante para `telegraf.d/`, um arquivo por equipamento:
   ```bash
   cp exemplos/arista.conf.exemplo telegraf.d/arista-sw01.conf
   # edite o IP em telegraf.d/arista-sw01.conf
   ```
3. Recarregue o coletor:
   ```bash
   docker compose restart telegraf-gnmi
   ```

Equipamentos do mesmo fabricante com a mesma credencial podem ser listados juntos
em `addresses = ["ip1:porta", "ip2:porta"]` dentro de um único arquivo.

### Nokia (opcional, via gnmic)
```bash
cp exemplos/nokia-gnmic.yaml.exemplo gnmic.yaml   # edite targets/credenciais/token
docker compose --profile nokia up -d
```

---

## Conectar no Kuantics

No cadastro da fonte de telemetria do Kuantics, use:

| Campo | Valor |
|---|---|
| Host / URL | `http://IP_DA_VM:8181` |
| Database / bucket | `telemetria` |
| Token | conteúdo de `./secrets/admin-token` (também no `.env`) |

---

## Operação

```bash
docker compose ps                      # status dos serviços
docker logs -f telegraf-gnmi           # logs do coletor gNMI
docker logs -f telegraf-huawei         # logs do coletor Huawei
docker logs -f influxdb3-core          # logs do banco

# Consultar dados gravados:
docker exec influxdb3-core influxdb3 query \
  --database telemetria \
  --token "$(cat secrets/admin-token)" \
  "SHOW TABLES"
```

---

## Solução de problemas

| Sintoma | Causa provável / ação |
|---|---|
| `denied` / `manifest unknown` ao baixar telegraf-huawei | A imagem no GHCR não está pública ou falta `docker login ghcr.io`. |
| `bind: address already in use` | Porta 8181/8888/57400 ocupada. Veja `sudo ss -tlnp`. |
| Equipamento gNMI não conecta (`i/o timeout`) | Conectividade/credencial. Teste `telnet IP porta` da VM e revise usuário/senha. |
| `invalid column type for column 'X', expected tag, got field` | Colisão tag/field no InfluxDB 3 (IOx): o campo `X` precisa virar tag (use `processors.converter`) **ou** a tabela já fixou o tipo antigo — nesse caso recrie a tabela. Os processors já tratam `id`/`index`/`name`/`neighbor_address` conhecidos. |
| Sem dados no Explorer | Confira `docker logs telegraf-*` por erros de write e se o database `telemetria` existe. |

---

## Estrutura

```
telemetria/
├── docker-compose.yml        # 4 serviços (+ gnmic opcional)
├── instalar.sh               # bootstrap 1-comando
├── .env.example              # modelo de variáveis (vira .env)
├── telegraf-huawei.conf      # config da coleta Huawei (passiva)
├── telegraf-gnmi.conf        # base da coleta gNMI + processors (sem credenciais)
├── telegraf.d/               # arquivos de equipamentos (mesclados ao gnmi)
│   └── fix_fields.conf
├── exemplos/                 # modelos por fabricante (copiar p/ telegraf.d/)
│   ├── juniper.conf.exemplo
│   ├── arista.conf.exemplo
│   ├── cisco.conf.exemplo
│   └── nokia-gnmic.yaml.exemplo
└── build/                    # OPCIONAL — só para rebuildar/atualizar a imagem Huawei
    ├── Dockerfile
    ├── generate_paths.go
    ├── telegraf.conf
    └── publicar.sh
```

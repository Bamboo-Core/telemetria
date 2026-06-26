# Imagem custom do Telegraf com o plugin gRPC da Huawei compilado do fonte.
# Build/push: ver publicar.sh.  (Resultado: ghcr.io/bamboo-core/telegraf-huawei)
FROM golang:1.17.1-buster as git-telegraf-huawei

# Proxy (opcional) — passado via build args
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY=localhost,127.0.0.1
ENV http_proxy="${HTTP_PROXY}"
ENV https_proxy="${HTTPS_PROXY}"
ENV no_proxy="${NO_PROXY}"

# Buster foi para o arquivo morto do Debian
RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i 's|security.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
    sed -i '/stretch-updates/d' /etc/apt/sources.list

RUN apt-get update && apt-get install -y \
    curl unzip make git gcc g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Go
RUN curl -O https://dl.google.com/go/go1.17.1.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.17.1.linux-amd64.tar.gz && \
    rm go1.17.1.linux-amd64.tar.gz

# protoc
RUN curl -L -o protoc-3.11.4-linux-x86_64.zip https://github.com/protocolbuffers/protobuf/releases/download/v3.11.4/protoc-3.11.4-linux-x86_64.zip && \
    unzip protoc-3.11.4-linux-x86_64.zip -d /usr/local && \
    rm protoc-3.11.4-linux-x86_64.zip

ENV GOROOT=/usr/local/go
ENV GOPATH=/usr/local/goWorkplace
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin
RUN go version

RUN go install github.com/golang/protobuf/protoc-gen-go@v1.5.0

# Telegraf + plugin Huawei + protos
RUN git clone --branch release-1.23 https://github.com/influxdata/telegraf.git /opt/telegraf
RUN git clone https://github.com/HuaweiDatacomm/telegraf-huawei-plugin.git /opt/telegraf-huawei-plugin

WORKDIR /opt/telegraf-huawei-plugin
ENV TELEGRAFROOT=/opt/telegraf
RUN chmod +x install.sh && ./install.sh

RUN git clone https://github.com/HuaweiDatacomm/proto.git /opt/proto

# Quais .proto da Huawei compilar (sem .proto no fim). Ajuste conforme a necessidade.
ARG PROTO_FILES="huawei-debug huawei-ifm"
ARG CACHE_BUST

RUN for file in $PROTO_FILES; do \
        cp /opt/proto/network-router/8.22.0/$file.proto /opt/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto && \
        cd /opt/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto && \
        sed -i "/^package \S*;/a option go_package=\"/$file\";" $file.proto && \
        protoc --go_out=plugins=grpc:. $file.proto && \
        echo "Added go_package to $file.proto" ; \
    done

RUN ls -l /opt/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto

ARG CACHE_BUST

# Patch dos imports do HuaweiTelemetry.go
RUN ImportPaths="// Patched by docker"; \
    for file in $PROTO_FILES; do \
        ImportPaths="$ImportPaths\n\"github.com/influxdata/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto/$file\"" ; \
    done && \
    sed -i "s#//\"github.com/influxdata/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto/huawei_debug\"#$ImportPaths#" /opt/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto/HuaweiTelemetry.go

ENV PROTO_FILES=$PROTO_FILES

# Gera as entradas de pathTypeMap e injeta no HuaweiTelemetry.go
COPY generate_paths.go .
RUN go build -o generate_paths generate_paths.go
RUN ./generate_paths > generated_paths.txt
RUN cat generated_paths.txt
RUN sed -i "\/\/PathKey/r generated_paths.txt" /opt/telegraf/plugins/parsers/huawei_grpc_gpb/telemetry_proto/HuaweiTelemetry.go

WORKDIR /opt/telegraf
RUN make

# --- Imagem final ------------------------------------------------------------
FROM telegraf:1.23.4
# telegraf.conf é só um placeholder; em runtime ele é sobrescrito pelo
# bind-mount de ./telegraf-huawei.conf (ver docker-compose.yml).
COPY ./telegraf.conf /etc/telegraf/telegraf.conf
COPY --from=git-telegraf-huawei /opt/telegraf/telegraf /usr/bin/telegraf
CMD ["telegraf"]

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

LABEL "com.github.actions.icon"="upload-cloud"
LABEL "com.github.actions.color"="yellow"
LABEL "com.github.actions.name"="Deploy Frappe"
LABEL "com.github.actions.description"="Deploy Frappe code to a server"
LABEL "org.opencontainers.image.source"="https://github.com/Xieyt/action-deploy-frappe"


RUN apt update && \
    apt install --no-install-recommends -y \
        bash \
        git \
        build-essential \
        python3-dev \
        wget \
        vim \
        curl \
        openssh-client \
        jq \
        rsync \
        zip \
        unzip \
        wkhtmltopdf \
        gnupg \
        python3-pip \
        python3-venv \
        software-properties-common && \
        pip3 install shyaml frappe-bench && \
        rm -rf /var/lib/apt/lists/*

SHELL ["bash","-c"]

# adduser frappe
RUN useradd -s /bin/bash -m -p frappe frappe

## yarn install
RUN echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
RUN apt update
RUN apt install -y yarn


# nvm
RUN mkdir -p /opt/nvm
ENV NVM_DIR="/opt/nvm"
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
RUN source /opt/nvm/nvm.sh && nvm install --lts=gallium && nvm use --lts=gallium && n=$(which node);n=${n%/bin/node}; chmod -R 755 $n/bin/*; cp -r $n/{bin,lib,share} /usr/local


COPY hosts.yml /
COPY *.sh /
RUN chmod +x /*.sh

ENTRYPOINT ["/entrypoint.sh"]

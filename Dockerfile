FROM node:gallium-alpine as node
FROM alpine:latest

LABEL "com.github.actions.icon"="upload-cloud"
LABEL "com.github.actions.color"="yellow"
LABEL "com.github.actions.name"="Deploy Frappe"
LABEL "com.github.actions.description"="Deploy Frappe code to a server"
LABEL "org.opencontainers.image.source"="https://github.com/rtcamp/action-deploy-frappe"

RUN apk update && \
    apk --no-cache add \
        build-base \
        bash \
        git \
        curl \
        gnupg \
        py3-pip \
        openssh-client \
        jq \
        rsync \
        zip \
        unzip \
        py3-virtualenv \
        python3-dev \
        linux-headers \
        yarn \
        busybox-suid

RUN pip3 install shyaml frappe-bench
RUN pip3 install --upgrade pip psutil


# users
RUN addgroup -g 1000 frappe
RUN adduser -D -h /home/frappe -G frappe -s /bin/bash -u 1000 frappe

# node 16
COPY --from=node /usr/lib /usr/lib
COPY --from=node /usr/local/share /usr/local/share
COPY --from=node /usr/local/lib /usr/local/lib
COPY --from=node /usr/local/include /usr/local/include
COPY --from=node /usr/local/bin /usr/local/bin

# cron
RUN touch /var/spool/cron/crontabs/frappe && chown -R frappe: /var/spool/cron/crontabs/frappe

COPY hosts.yml /
COPY *.sh /
RUN chmod +x /*.sh

ENTRYPOINT ["/entrypoint.sh"]

FROM ubuntu:20.04
ARG DEBIAN_FRONTEND=noninteractive

## Essential for install SO Packages
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    gpg \
    lsb-release && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

## SO Packages
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    apt-transport-https \
    bc \
    build-essential \
    cron \
    docker-ce \
    docker-ce-cli \
    gettext-base \
    git \
    gnupg \
    iputils-ping \
    jq \
    software-properties-common \
    sudo \
    unzip \
    zip
COPY --from=docker/buildx-bin:latest /buildx /usr/libexec/docker/cli-plugins/docker-buildx

## Install dependecies in parallel mode :D
WORKDIR /tmp/dependencies
ADD ./dependencies /tmp/dependencies
RUN cp -p apt apt-get
RUN APT=$(command -v apt) \
    PATH=.:$PATH \
    ./install-dependencies.sh && rm -rf /tmp/dependencies

## Things that will be change more
ARG ACTIONS_RUNNER_USER=actions-runner
ARG ACTIONS_RUNNER_HOME=/home/${ACTIONS_RUNNER_USER}
ARG ACTIONS_RUNNER_WORKDIR=/runner
ARG ACTIONS_RUNNER_VERSION=2.303.0
ARG ACTIONS_RUNNER_FILE=actions-runner-linux-x64-${ACTIONS_RUNNER_VERSION}.tar.gz
WORKDIR $ACTIONS_RUNNER_WORKDIR
RUN curl -o ${ACTIONS_RUNNER_FILE} -L https://github.com/actions/runner/releases/download/v${ACTIONS_RUNNER_VERSION}/${ACTIONS_RUNNER_FILE}
RUN tar xzf ./${ACTIONS_RUNNER_FILE} && rm ./${ACTIONS_RUNNER_FILE}
RUN ./bin/installdependencies.sh
ADD entrypoint.sh .
RUN useradd -m ${ACTIONS_RUNNER_USER} \
    && usermod -aG sudo ${ACTIONS_RUNNER_USER} \
    && echo "%sudo ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && chown -R ${ACTIONS_RUNNER_USER}: ${ACTIONS_RUNNER_WORKDIR}
USER ${ACTIONS_RUNNER_USER}

ENTRYPOINT ["/runner/entrypoint.sh"]

# syntax=docker/dockerfile:1.7

# ==============================================================================
# 1.全局声明：在最开头写 ARG，让它们能被用于所有 FROM 阶段的镜像名称中（可接收来自 docker-compose.yml 的 args）
# 永远不要在生产或团队协作的 Dockerfile 里用 latest，显式锁定版本号才是专业做法
# ==============================================================================
ARG UV_VERSION=0.13.1
ARG NODE_VERSION=26.8.2
ARG PYTHON_VERSION=3.11.14
ARG PI_VERSION=1.1.0

ARG DOCKER_USERNAME=ubuntu
ARG DOCKER_UID=1000
ARG DOCKER_GID=1000


# ==============================================================================
# 2. 镜像拉取
# 独立拉取指定版本的 uv 镜像阶段（绕过 --from 不支持变量的限制）
# 独立拉取指定版本的 Node.js 镜像阶段（绕过 --from 不支持变量的限制）
#   只复制运行时文件，不保证所有动态库依赖都齐全
#   后续有 ldd 验证
# 基于官方 PyTorch 镜像，内置 CUDA 13.0 + cuDNN 9
#   镜像自带 ubuntu 用户（UID/GID 1000:1000）
# ==============================================================================
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin
FROM node:${NODE_VERSION}-bookworm-slim AS node-bin
FROM pytorch/pytorch:2.14.1-cuda13.0-cudnn9-devel


# ==============================================================================
# 3.重新声明：用于后续环境变量或脚本使用（可接收来自 docker-compose.yml 的 args）
# ==============================================================================
ARG DOCKER_USERNAME=ubuntu
ARG DOCKER_UID=1000
ARG DOCKER_GID=1000
ARG PYTHON_VERSION=3.11.14
ARG PI_VERSION=1.1.0


# ==============================================================================
# 4. 系统级工具安装:编译工具、包管理器等
# id=apt-cache-v1：APT 包缓存，避免每次构建都重新下载软件包；
# id=apt-lists-v1：APT 包索引缓存，避免每次构建都重新下载索引文件；
# `Acquire::Retries=5`：在网络不稳定时重试 apt-get update 和 apt-get install，避免构建失败
# `DEBIAN_FRONTEND=noninteractive`：避免在构建过程中出现交互式提示，不会自动持久化到最终镜像的环境变量中
# rm -rf /var/lib/apt/lists/*：/var/lib/apt/lists 已经是 BuildKit 缓存挂载目录；挂载内容本身不会提交到镜像层，删除它反而会损失缓存效果
# ==============================================================================
RUN --mount=type=cache,id=apt-cache-v1,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-v1,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get -o Acquire::Retries=5 update; \
    DEBIAN_FRONTEND=noninteractive \
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    git-lfs \
    build-essential \
    ninja-build \
    cmake \
    pkg-config \
    libgl1 \
    libglib2.0-0 \
    libstdc++6 \
    libatomic1 \
    tini
# && rm -rf /var/lib/apt/lists/*

# 从上一个名为 node-bin 的 stage 中安全地复制 node 二进制文件
COPY --from=node-bin /usr/local/ /usr/local/
# 校验 Node.js 与 npm 版本
#   node:26.8.2-bookworm-slim：基础镜像更小，但缺少某些可选系统工具或共享库，Node.js 本身的功能等级与完整版一致
#   复制 Node.js 运行时后通过 node --version、npm --version 和 pi --version 验证，若确实遇到缺失共享库，再补充所需库
#   `ldd "$(command -v node)"`：当前项目Node.js安装使用跨镜像复制，如果 ldd 显示 not found：
#           就需要补齐缺失的共享库，或者改用在 PyTorch 基础镜像中安装 Node.js 的方案。
RUN node --version \
    && npm --version \
    && ldd "$(command -v node)" \
    && ! ldd "$(command -v node)" | grep -q "not found"

# 从上一个名为 uv-bin 的 stage 中安全地复制 uv 二进制文件
COPY --from=uv-bin /uv /uvx /usr/local/bin/


# ==============================================================================
# 5. 创建非 root 用户并对齐 UID/GID
# 创建非 root 用户：复用镜像中已有的名为 ubuntu 用户
# 对齐 UID/GID：避免挂载目录时产生权限问题
# ==============================================================================
RUN set -eux; \
    mkdir -p \
    /workspace \
    "/home/${DOCKER_USERNAME}/.cache/uv" \
    "/home/${DOCKER_USERNAME}/.cache/torch" \
    "/home/${DOCKER_USERNAME}/.cache/huggingface" \
    "/home/${DOCKER_USERNAME}/.pi" \
    "/home/${DOCKER_USERNAME}/.npm" \
    "/home/${DOCKER_USERNAME}/.npm-global"; \
    chown -R "${DOCKER_UID}:${DOCKER_GID}" \
    /workspace \
    "/home/${DOCKER_USERNAME}"


# ==============================================================================
# 6. 【环境变量注入】
# `UV_PROJECT_ENVIRONMENT`：将 uv 虚拟环境路径指定到 /workspace/.venv
# `UV_DEFAULT_INDEX`：指定 uv 安装依赖的 PyPI 镜像源，避免走代理，消耗流量
# UV_PYTHON_DOWNLOADS、UV_PYTHON：automatic 表示自动下载并安装指定版本的 Python
# UV_CACHE_DIR：uv 缓存目录，设置到当前用户家目录中
# NPM_CONFIG_PREFIX：npm 的全局包安装目录，设置到当前用户家目录中
# PATH：务必使用追加模式，将 uv 虚拟环境和 npm 全局包目录加入 PATH，确保后续命令可直接调用
# ==============================================================================
ENV HOME="/home/${DOCKER_USERNAME}" \
    UV_DEFAULT_INDEX=https://mirrors.aliyun.com/pypi/simple/ \
    UV_PROJECT_ENVIRONMENT="/workspace/.venv" \
    UV_CACHE_DIR=/home/${DOCKER_USERNAME}/.cache/uv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON=${PYTHON_VERSION} \
    UV_PYTHON_DOWNLOADS=automatic \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_PREFIX=/home/${DOCKER_USERNAME}/.npm-global \
    NPM_CONFIG_CACHE=/home/${DOCKER_USERNAME}/.npm \
    HF_HOME=/home/${DOCKER_USERNAME}/.cache/huggingface \
    TORCHINDUCTOR_CACHE_DIR=/home/${DOCKER_USERNAME}/.cache/torch/inductor \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TMPDIR=/tmp \
    PATH="/workspace/.venv/bin:/home/${DOCKER_USERNAME}/.npm-global/bin:${PATH}"


# ==============================================================================
# 7. 声明并固定工作目录
# Docker 会保留当前阶段的工作目录。只要没有切换到其他目录，一次声明就够了
# 建议放在复制项目文件之前
# 后续安装依赖、安装 Pi 和容器启动时都会沿用该目录，无需重复声明
# ==============================================================================
WORKDIR /workspace


# ==============================================================================
# 8. 显式切换为非 root 用户运行
# 从 root 阶段切换到应用开发阶段的明确边界。除了必须以 root 执行的系统级操作，其余工作尽量全部放在这个边界之后
# ==============================================================================
USER ${DOCKER_USERNAME}


# ==============================================================================
# 9. 安装锁定的 Python 依赖
# ==============================================================================
# 复制依赖清单与锁文件
COPY --chown=${DOCKER_USERNAME}:${DOCKER_USERNAME} pyproject.toml uv.lock ./
# 【核心缓存层】利用 BuildKit 缓存和 uv sync 将 AI 重型依赖安全安装到 /opt/venv 中
# 1）保持BuildKit 缓存挂载位置与 UV_CACHE_DIR 一致；
#       RUN --mount 的 target 是 Dockerfile 挂载参数，不会把 UV_CACHE_DIR 当作环境变量解析
# 2）保持缓存目录的 UID/GID 与非 root 用户一致，避免 uv sync 失败；
# 3）`--no-install-project`：在尚未复制项目源码时，跳过项目自身安装，只安装锁文件中的依赖，容器启动并挂载项目源码后，在`uv sync --frozen`
RUN --mount=type=cache,id=shared-uv-cache-v1,target=/home/${DOCKER_USERNAME}/.cache/uv,uid=${DOCKER_UID},gid=${DOCKER_GID} \
    uv sync --frozen --no-install-project


# ==============================================================================
# 10. 安装 Pi Coding Agent
# `pi --version`：成功返回版本号，说明 “pi安装 + 环境变量配置 + 二进制执行” 全链路都是通的
# node:26.8.2-bookworm-slim：基础镜像更小，但缺少某些可选系统工具或共享库，Node.js 本身的功能等级与完整版一致
# 复制 Node.js 运行时后通过 node --version、npm --version 和 pi --version 验证，若确实遇到缺失共享库，再补充所需库
# `ldd "$(command -v node)"`：当前项目Node.js安装使用跨镜像复制，如果 ldd 显示 not found，就需要补齐缺失的共享库，或者改用在 PyTorch 基础镜像中安装 Node.js 的方案。
# ==============================================================================
RUN --mount=type=cache,id=shared-npm-cache-v1,target=/home/${DOCKER_USERNAME}/.npm,uid=${DOCKER_UID},gid=${DOCKER_GID} \
    set -eux; \
    npm install --global "@earendil-works/pi-coding-agent@${PI_VERSION}"; \
    npm install -g @agegr/pi-web@latest; \
    pi --version; \
    pi-web version



# ==============================================================================
# 11. 让容器保持运行，等待 docker-compose.yml
# ==============================================================================
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]


# ============================================================
# 使用说明：构建成功，启动容器并检查
# ============================================================
# docker compose exec qwen-image-dev bash -lc '
# set -eu
# id
# echo "HOME=$HOME"
# node --version
# npm --version
# uv --version
# python --version
# uv run python -c "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"CUDA unavailable\")"
# pi --version
# '
# ============================================================

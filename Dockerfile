# ==============================================================================
# 1. 阶段前声明全局参数（可接收来自 docker-compose.yml 的 args）
# ==============================================================================
ARG PYTHON_VERSION=3.11
ARG UV_VERSION=latest
ARG USER_UID=1000
ARG USER_GID=1000
ARG DOCKER_USERNAME=stte_docker

# ==============================================================================
# 2. 独立拉取指定版本的 uv 镜像阶段（绕过 --from 不支持变量的限制）
# ==============================================================================
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin

# ==============================================================================
# 3. 基础镜像：PyTorch 2.5.1 + CUDA 12.4 (deve l包含完整编译链，完美向下兼容你的 CUDA 13.3 驱动)
# ==============================================================================
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-devel

# 从上一个名为 uv-bin 的 stage 中安全地复制 uv 二进制文件
COPY --from=uv-bin /uv /bin/uv

WORKDIR /workspace

# ==============================================================================
# 4. 创建非 root 用户（stte_docker）并对齐 UID/GID
# ==============================================================================
# FROM 之后必须重新声明 ARG，否则获取不到外部传参
ARG USER_UID=1000
ARG USER_GID=1000
ARG DOCKER_USERNAME=stte_docker

RUN groupadd -g ${USER_GID} ${DOCKER_USERNAME} && \
    useradd -l -u ${USER_UID} -g ${DOCKER_USERNAME} -m -s /bin/bash ${DOCKER_USERNAME} && \
    mkdir -p /workspace /home/${DOCKER_USERNAME}/.cache/uv && \
    chown -R ${DOCKER_USERNAME}:${DOCKER_USERNAME} /workspace /home/${DOCKER_USERNAME}/.cache/uv

# ==============================================================================
# 5. 【核心隔离】将 uv 虚拟环境路径指定到 /opt/venv，彻底防挂载覆盖
# 将 /opt/venv/bin 写入 PATH
# 将 UV_CACHE_DIR 指向非 root 用户的专属家目录
# ==============================================================================
ENV UV_PROJECT_ENVIRONMENT="/opt/venv" \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_CACHE_DIR=/home/${DOCKER_USERNAME}/.cache/uv \
    PATH="/opt/venv/bin:$PATH"

# ==============================================================================
# 6. 安装训练 Diffusion 大模型必备的系统级编译工具
# ==============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    ninja-build \
    cmake \
    libgl1-mesa-glx \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# 7. 复制依赖清单与锁文件（利用 Docker 层缓存机制）
# ==============================================================================
COPY --chown=${DOCKER_USERNAME}:${DOCKER_USERNAME} pyproject.toml uv.lock ./

# ==============================================================================
# 8. 【核心缓存层】利用 BuildKit 缓存和 uv sync 将 AI 重型依赖安全安装到 /opt/venv 中
# ==============================================================================
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project

# ==============================================================================
# 9. 显式切换为非 root 用户运行，确保后续所有进程安全合规
# ==============================================================================
USER ${DOCKER_USERNAME}

# ==============================================================================
# 10. 让容器保持运行，等待 docker-compose 或 pi 沙箱挂载代码并接入
# ==============================================================================
CMD ["tail", "-f", "/dev/null"]
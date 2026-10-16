# 选用 PyTorch 2.5.1 + CUDA 12.4 (deve l包含完整编译链，完美向下兼容本机的 CUDA 13.3 驱动)
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-devel

# 1. 极速安装官方 uv 工具
COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv

WORKDIR /workspace

# 2. 【核心隔离】将 uv 虚拟环境路径指定到 /opt/venv，彻底防止 pi-container-sandbox 挂载 /workspace 时覆盖环境
# 并将 /opt/venv/bin 写入 PATH
ENV UV_PROJECT_ENVIRONMENT="/opt/venv" \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PATH="/opt/venv/bin:$PATH"

# 3. 安装训练 Diffusion 大模型必备的系统级编译工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    ninja-build \
    cmake \
    libgl1-mesa-glx \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# 4. 优先复制依赖清单与锁文件（利用 Docker 层缓存机制）
COPY pyproject.toml uv.lock ./

# 5. 【核心缓存层】利用 BuildKit 缓存和 uv sync 将 AI 重型依赖安全安装到 /opt/venv 中
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project

# 6. Docker 技巧：让容器保持运行，但不执行任何实际业务逻辑，相当于一个“空转”的容器
CMD ["tail", "-f", "/dev/null"]
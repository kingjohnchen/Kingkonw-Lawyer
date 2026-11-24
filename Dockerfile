# LawLink 应用容器
# 多阶段构建：deps → builder → runner
# 2026-11 阿里云部署复核：Alpine 3.24 移除 openssl1.1-compat 且 Prisma musl engine
# 不稳定，三阶段统一改为 node:22-bookworm-slim + debian-openssl-3.0.x engine。
# 见 AGENTS.md §六 6.2。

FROM node:22-bookworm-slim AS deps
WORKDIR /app
# Prisma 在 npm ci / generate 时依赖 openssl 命令行探测 OpenSSL 版本；
# 探测失败会静默回退到 openssl-1.1.x 引擎，导致运行时加载失败。
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*
COPY package*.json ./
COPY prisma ./prisma
RUN npm ci

FROM node:22-bookworm-slim AS builder
WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx prisma generate
RUN npm run build

FROM node:22-bookworm-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# 自动备份链依赖 bash + pg_dump。postgres:16 服务端要求客户端主版本 >= 16，
# bookworm 自带 postgresql-client 15 不满足，故从 PGDG 源装 16。
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl gnupg libssl3 openssl \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg \
 && printf '%s\n' 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main' \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client-16 \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1001 nodejs \
 && useradd --system --uid 1001 --gid nodejs --no-create-home nextjs

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next-build ./.next-build
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./package.json
# next.config.mjs 必须进镜像：distDir 读 NEXT_DIST_DIR（构建产物在 .next-build
# 而非默认 .next），缺了它 next start 会报 "Could not find a production build"。
# 该文件还带 serverExternalPackages、serverActions 25MB 上传上限与安全响应头。
COPY --from=builder --chown=nextjs:nodejs /app/next.config.mjs ./next.config.mjs
COPY --from=builder --chown=nextjs:nodejs /app/prisma ./prisma
# 备份脚本必须进镜像：cron job 通过 process.cwd()/scripts/backup.sh 调用。
COPY --from=builder --chown=nextjs:nodejs /app/scripts ./scripts

# backups 目录预先建好并授权：命名卷首次挂载会继承镜像内目录属主，
# 运行用户 nextjs 才能写入（BACKUP_DIR 默认 /app/backups）。
RUN mkdir -p /app/storage /app/backups && chown -R nextjs:nodejs /app/storage /app/backups

USER nextjs
EXPOSE 3000
CMD ["npm", "run", "start"]

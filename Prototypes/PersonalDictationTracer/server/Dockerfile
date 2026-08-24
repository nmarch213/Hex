FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS runtime

ARG HEX_BUILD_REVISION=development
ENV NODE_ENV=production
ENV HEX_BUILD_REVISION=${HEX_BUILD_REVISION}
LABEL org.opencontainers.image.revision=${HEX_BUILD_REVISION}
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node storage-databases.json ./storage-databases.json
RUN mkdir -p /var/lib/hex-personal-dictation \
  && chown node:node /var/lib/hex-personal-dictation \
  && chmod 700 /var/lib/hex-personal-dictation
USER node

EXPOSE 8787
CMD ["node", "dist/main.js"]

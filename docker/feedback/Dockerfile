# MobiSSH feedback service (#997) — dedicated bug-report/telemetry ingestion.
# Build context is the REPO ROOT (see docker-compose.feedback.yml) because the
# service shares server/feedback-store.js with mobissh-prod's local fallback.
FROM node:20-slim

WORKDIR /app

# No npm dependencies — plain node:http. Copy only the shared source pieces.
COPY server/feedback-store.js ./server/feedback-store.js
# #1115: the shared fail-closed upload guard — required by server-feedback
# since the security batch; its absence crash-looped the first post-#1115
# rebuild (silent until deploy).
COPY server/feedback-guard.js ./server/feedback-guard.js
COPY server-feedback/index.js ./server-feedback/index.js
COPY server-feedback/package.json ./server-feedback/package.json

# Bake git hash so /healthz can report code currency without git installed
ARG GIT_HASH=unknown
RUN echo "$GIT_HASH" > /app/.git-hash

ENV PORT=8082 \
    NODE_ENV=production \
    UPLOADS_DIR=/app/test-results/uploads

EXPOSE 8082

CMD ["node", "server-feedback/index.js"]

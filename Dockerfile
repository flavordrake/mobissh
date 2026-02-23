FROM node:18-alpine

WORKDIR /app

# Install production dependencies (cached layer — only re-runs when package files change)
COPY server/package*.json ./server/
RUN cd server && npm ci --omit=dev

# Copy application sources
COPY server/ ./server/
COPY public/ ./public/

# PORT and BASE_PATH can be overridden at runtime via -e flags.
# BASE_PATH must start with / and have no trailing slash (e.g. /ssh-test).
ENV PORT=8081 \
    NODE_ENV=production

EXPOSE 8081

CMD ["node", "server/index.js"]

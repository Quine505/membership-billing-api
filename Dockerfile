FROM node:26-alpine AS base
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src

# docker build --target test .
FROM base AS test
COPY test ./test
RUN npm test

# The last stage is what `docker build -t app .` produces.
FROM base
EXPOSE 8080
CMD ["node", "src/server.ts"]

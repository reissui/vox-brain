FROM node:22-slim AS builder
WORKDIR /usr/src/app
COPY package.json .
COPY package-lock.json* .
RUN npm ci

FROM node:22-slim
WORKDIR /usr/src/app
COPY --from=builder /usr/src/app/ /usr/src/app/
COPY . .
ENV BRAIN_SITE_CONTENT_ROOT=/content
EXPOSE 4321
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]

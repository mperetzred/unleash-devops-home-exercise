FROM node:lts-alpine3.20

WORKDIR /app

COPY package*.json ./
RUN npm install && \
    npm install typescript -g

RUN mkdir -p src
COPY . ./src

EXPOSE 3000

RUN npm i -D tsx
CMD ["npx", "tsx" ,"./src/index.ts"]

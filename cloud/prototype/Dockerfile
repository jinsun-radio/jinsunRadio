# 語音 Agent server（常駐程序）——放 Render / Railway / Fly / 任何能跑長駐 Node 的主機。
# ⚠️ 不能放 Vercel/Lambda 等 serverless：20 秒升級計時器、/commands 長輪詢＋下行佇列、
#    進度播報 worker 的 Supabase Realtime 訂閱都需要「同一個常駐程序」。
FROM node:22-slim
WORKDIR /app

# 先裝依賴（optionalDependencies 含 @supabase/supabase-js 與 @anthropic-ai/bedrock-sdk）
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src
COPY public ./public

ENV NODE_ENV=production
# 主機會給 $PORT；server 讀 process.env.PORT（見 src/server.js）
EXPOSE 8787
CMD ["node", "src/server.js"]

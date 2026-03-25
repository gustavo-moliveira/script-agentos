#!/bin/bash
# =============================================================
# AgentOS — Setup Completo v2
# Troovi · WhatsApp AI Platform
# Execute: bash setup_agentos.sh
# Repo: https://github.com/gustavo-moliveira/troovi
# =============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${BLUE}${BOLD}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${CYAN}  $1${NC}"; }
err()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║   troovi · AgentOS · Setup Completo v2  ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ════════════════════════════════════════
# COLETA DE CONFIGURAÇÕES
# ════════════════════════════════════════
step "Configuração inicial"
read -p "$(echo -e "${BOLD}OpenAI API Key:${NC} ")" OPENAI_KEY
read -p "$(echo -e "${BOLD}Senha do banco (crie uma forte):${NC} ")" DB_PASS
read -p "$(echo -e "${BOLD}Domínio da API (ex: api.troovi.site):${NC} ")" API_DOMAIN
read -p "$(echo -e "${BOLD}Domínio do Admin (ex: admin.troovi.site):${NC} ")" ADMIN_DOMAIN

[[ -z "$OPENAI_KEY" ]]   && err "OpenAI Key não pode ser vazia"
[[ -z "$DB_PASS" ]]      && err "Senha do banco não pode ser vazia"
[[ -z "$API_DOMAIN" ]]   && err "Domínio da API não pode ser vazio"
[[ -z "$ADMIN_DOMAIN" ]] && err "Domínio do Admin não pode ser vazio"

SECRET_KEY=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 16)

ok "Configuração coletada"
info "API:        https://$API_DOMAIN"
info "Admin:      https://$ADMIN_DOMAIN"
info "Admin Token: $ADMIN_TOKEN  ← guarde este token!"

# ════════════════════════════════════════
# ESTRUTURA DE PASTAS
# ════════════════════════════════════════
step "Criando estrutura de pastas"
mkdir -p agentos/{backend/app/{models,routers,agent,services},frontend/src/{pages,components,hooks}}
ok "Pastas criadas"
cd agentos

# ════════════════════════════════════════
# .env
# ════════════════════════════════════════
cat > .env << ENVEOF
DATABASE_URL=postgresql+asyncpg://agentos:${DB_PASS}@postgres-agentos:5432/agentos
AGENTOS_DB_PASS=${DB_PASS}
REDIS_URL=redis://redis:6379/1
OPENAI_API_KEY=${OPENAI_KEY}
SECRET_KEY=${SECRET_KEY}
ADMIN_TOKEN=${ADMIN_TOKEN}
EVOLUTION_API_URL=https://evolution.troovi.site
EVOLUTION_API_KEY=5a44ee895c324f271a29a14438d5435a8fa262c69a456ff5
ENVIRONMENT=production
TIMEZONE=America/Sao_Paulo
BASE_URL=https://${API_DOMAIN}
ADMIN_DOMAIN=https://${ADMIN_DOMAIN}
DEBOUNCE_DELAY=3.0
ENVEOF
ok ".env criado"

# ════════════════════════════════════════
# .env.example (vai pro git)
# ════════════════════════════════════════
cat > .env.example << 'ENVEXEOF'
DATABASE_URL=postgresql+asyncpg://agentos:SENHA@postgres-agentos:5432/agentos
AGENTOS_DB_PASS=SENHA
REDIS_URL=redis://redis:6379/1
OPENAI_API_KEY=sk-...
SECRET_KEY=gere_com_openssl_rand_hex_32
ADMIN_TOKEN=gere_com_openssl_rand_hex_16
EVOLUTION_API_URL=https://evolution.troovi.site
EVOLUTION_API_KEY=sua_chave_aqui
ENVIRONMENT=production
TIMEZONE=America/Sao_Paulo
BASE_URL=https://api.troovi.site
ADMIN_DOMAIN=https://admin.troovi.site
DEBOUNCE_DELAY=3.0
ENVEXEOF
ok ".env.example criado"

# ════════════════════════════════════════
# requirements.txt
# ════════════════════════════════════════
cat > backend/requirements.txt << 'EOF'
fastapi==0.115.5
uvicorn[standard]==0.32.1
python-multipart==0.0.12
httpx==0.28.0
langgraph==0.2.59
langchain==0.3.14
langchain-openai==0.2.14
langchain-postgres==0.0.12
sqlalchemy[asyncio]==2.0.36
asyncpg==0.30.0
psycopg[binary]==3.2.3
alembic==1.14.0
pgvector==0.3.6
redis[asyncio]==5.2.1
google-api-python-client==2.155.0
google-auth==2.37.0
apscheduler==3.10.4
pydantic-settings==2.6.1
python-dotenv==1.0.1
pytz==2024.2
EOF
ok "requirements.txt criado"

# ════════════════════════════════════════
# Dockerfile backend
# ════════════════════════════════════════
cat > backend/Dockerfile << 'EOF'
FROM python:3.12-slim

WORKDIR /app

# Dependências do sistema
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev curl && \
    rm -rf /var/lib/apt/lists/*

# Instala dependências Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Health check interno
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
EOF
ok "Dockerfile criado"

# ════════════════════════════════════════
# init.sql
# ════════════════════════════════════════
cat > backend/init.sql << 'EOF'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

CREATE TABLE IF NOT EXISTS tenants (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug                 TEXT UNIQUE NOT NULL,
    nome                 TEXT NOT NULL,
    -- Evolution
    evolution_url        TEXT NOT NULL DEFAULT 'https://evolution.troovi.site',
    evolution_key        TEXT NOT NULL,
    evolution_instance   TEXT NOT NULL,
    -- LLM
    openai_key           TEXT,
    llm_model            TEXT DEFAULT 'gpt-4o-mini',
    -- Agente
    agent_name           TEXT DEFAULT 'Assistente',
    agent_prompt         TEXT,
    business_hours       JSONB DEFAULT '{"seg":["08:00","18:00"],"ter":["08:00","18:00"],"qua":["08:00","18:00"],"qui":["08:00","18:00"],"sex":["08:00","18:00"]}',
    -- Google Calendar via Service Account
    google_sa_json       TEXT,
    calendar_id          TEXT,
    -- Follow-up
    followup_1_msg       TEXT,
    followup_2_msg       TEXT,
    followup_1_hours     INTEGER DEFAULT 24,
    followup_2_hours     INTEGER DEFAULT 48,
    -- Status
    active               BOOLEAN DEFAULT true,
    paused               BOOLEAN DEFAULT false,
    plan                 TEXT DEFAULT 'starter',
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    updated_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS contacts (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id            UUID REFERENCES tenants(id) ON DELETE CASCADE,
    phone                TEXT NOT NULL,
    nome                 TEXT,
    email                TEXT,
    followup_1_sent      BOOLEAN DEFAULT false,
    followup_2_sent      BOOLEAN DEFAULT false,
    conversation_closed  BOOLEAN DEFAULT false,
    last_activity        TIMESTAMPTZ,
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tenant_id, phone)
);

CREATE TABLE IF NOT EXISTS messages (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID REFERENCES tenants(id) ON DELETE CASCADE,
    contact_id  UUID REFERENCES contacts(id),
    phone       TEXT NOT NULL,
    role        TEXT NOT NULL,
    content     TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS documents (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID REFERENCES tenants(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    embedding   vector(1536),
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_doc_emb    ON documents USING ivfflat (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_msg_tenant ON messages (tenant_id, phone, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_con_tenant ON contacts (tenant_id, phone);
CREATE INDEX IF NOT EXISTS idx_con_act    ON contacts (last_activity) WHERE NOT conversation_closed;
EOF
ok "Schema SQL criado"

# ════════════════════════════════════════
# config.py
# ════════════════════════════════════════
cat > backend/app/config.py << 'EOF'
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    DATABASE_URL: str
    AGENTOS_DB_PASS: str = ""
    REDIS_URL: str = "redis://redis:6379/1"
    OPENAI_API_KEY: str
    SECRET_KEY: str
    ADMIN_TOKEN: str = ""
    EVOLUTION_API_URL: str = "https://evolution.troovi.site"
    EVOLUTION_API_KEY: str = ""
    ENVIRONMENT: str = "production"
    TIMEZONE: str = "America/Sao_Paulo"
    BASE_URL: str = "https://api.troovi.site"
    ADMIN_DOMAIN: str = "https://admin.troovi.site"
    DEBOUNCE_DELAY: float = 3.0

    model_config = {"env_file": ".env"}

@lru_cache
def get_settings():
    return Settings()

settings = get_settings()
EOF

# ════════════════════════════════════════
# database.py
# ════════════════════════════════════════
cat > backend/app/database.py << 'EOF'
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from .config import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    echo=settings.ENVIRONMENT == "development",
)

AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False)

async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
EOF

# ════════════════════════════════════════
# main.py
# ════════════════════════════════════════
cat > backend/app/main.py << 'EOF'
from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from .config import settings
from .database import AsyncSessionLocal
from .routers import webhook, admin, tenants
import logging, asyncio

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("agentos")

app = FastAPI(
    title="AgentOS API",
    version="2.0.0",
    docs_url="/docs" if settings.ENVIRONMENT != "production" else None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.ADMIN_DOMAIN, "http://localhost:5173", "http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(webhook.router, prefix="/webhook", tags=["Webhook"])
app.include_router(admin.router,   prefix="/admin",   tags=["Admin"])
app.include_router(tenants.router, prefix="/tenants", tags=["Tenants"])

@app.get("/health")
async def health():
    return {"status": "ok", "version": "2.0.0", "env": settings.ENVIRONMENT}

@app.get("/")
async def root():
    return {"service": "AgentOS", "version": "2.0.0"}
EOF
ok "Backend main.py criado"

# ════════════════════════════════════════
# routers/__init__.py
# ════════════════════════════════════════
touch backend/app/routers/__init__.py
touch backend/app/models/__init__.py
touch backend/app/agent/__init__.py
touch backend/app/services/__init__.py
touch backend/app/__init__.py

# ════════════════════════════════════════
# webhook.py (router)
# ════════════════════════════════════════
cat > backend/app/routers/webhook.py << 'EOF'
from fastapi import APIRouter, Request, BackgroundTasks, HTTPException
from ..database import AsyncSessionLocal
from ..config import settings
import asyncio, logging, json

logger = logging.getLogger("agentos.webhook")
router = APIRouter()

# Debounce buffer: phone -> (task, messages[])
_debounce: dict[str, asyncio.TimerHandle] = {}
_buffers:  dict[str, list[str]] = {}

async def _process(tenant_slug: str, phone: str, messages: list[str]):
    """Processa mensagens acumuladas após debounce."""
    full_text = "\n".join(messages)
    logger.info(f"[{tenant_slug}] Processando {phone}: {full_text[:80]}...")
    # TODO: chamar o agente LangGraph
    # from ..agent.graph import run_agent
    # await run_agent(tenant_slug, phone, full_text)

@router.post("/{tenant_slug}")
async def receive_webhook(tenant_slug: str, request: Request, background_tasks: BackgroundTasks):
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Payload inválido")

    # Extrai mensagem da Evolution API
    event = body.get("event", "")
    if event != "messages.upsert":
        return {"ok": True}

    data = body.get("data", {})
    key  = data.get("key", {})

    if key.get("fromMe"):
        return {"ok": True}  # ignora mensagens enviadas pelo bot

    phone   = key.get("remoteJid", "").replace("@s.whatsapp.net", "")
    content = (data.get("message") or {}).get("conversation") or \
              ((data.get("message") or {}).get("extendedTextMessage") or {}).get("text", "")

    if not phone or not content:
        return {"ok": True}

    key_id = f"{tenant_slug}:{phone}"

    # Cancela timer anterior
    if key_id in _debounce:
        _debounce[key_id].cancel()

    # Acumula no buffer
    _buffers.setdefault(key_id, []).append(content)

    # Novo timer
    loop = asyncio.get_event_loop()
    msgs_snapshot = _buffers[key_id]

    def _fire():
        msgs = _buffers.pop(key_id, [])
        _debounce.pop(key_id, None)
        asyncio.ensure_future(_process(tenant_slug, phone, msgs))

    _debounce[key_id] = loop.call_later(settings.DEBOUNCE_DELAY, _fire)

    logger.info(f"[{tenant_slug}] Buffer +1 para {phone} (delay={settings.DEBOUNCE_DELAY}s)")
    return {"ok": True}
EOF

# ════════════════════════════════════════
# admin.py (router)
# ════════════════════════════════════════
cat > backend/app/routers/admin.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Header
from ..config import settings

router = APIRouter()

def verify_token(x_admin_token: str = Header(...)):
    if x_admin_token != settings.ADMIN_TOKEN:
        raise HTTPException(403, "Token inválido")

@router.get("/stats", dependencies=[Depends(verify_token)])
async def stats():
    """Stats gerais do sistema."""
    return {"tenants": 0, "contacts": 0, "messages_today": 0}
EOF

# ════════════════════════════════════════
# tenants.py (router)
# ════════════════════════════════════════
cat > backend/app/routers/tenants.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from ..database import get_db
from ..config import settings
from pydantic import BaseModel
from typing import Optional
import uuid

router = APIRouter()

def verify_token(x_admin_token: str = Header(...)):
    if x_admin_token != settings.ADMIN_TOKEN:
        raise HTTPException(403, "Token inválido")

class TenantCreate(BaseModel):
    slug: str
    nome: str
    evolution_key: str
    evolution_instance: str
    evolution_url: Optional[str] = "https://evolution.troovi.site"
    llm_model: Optional[str] = "gpt-4o-mini"
    agent_name: Optional[str] = "Assistente"
    agent_prompt: Optional[str] = None

class TenantUpdate(BaseModel):
    nome: Optional[str] = None
    agent_name: Optional[str] = None
    agent_prompt: Optional[str] = None
    llm_model: Optional[str] = None
    evolution_key: Optional[str] = None
    evolution_instance: Optional[str] = None
    active: Optional[bool] = None
    paused: Optional[bool] = None

@router.get("/", dependencies=[Depends(verify_token)])
async def list_tenants(db: AsyncSession = Depends(get_db)):
    result = await db.execute(text("""
        SELECT t.id, t.slug, t.nome, t.active, t.paused, t.plan, t.created_at,
               t.agent_name, t.llm_model, t.evolution_instance,
               (SELECT COUNT(*) FROM contacts c WHERE c.tenant_id = t.id) as contacts,
               (SELECT COUNT(*) FROM messages m WHERE m.tenant_id = t.id) as messages
        FROM tenants t ORDER BY t.created_at DESC
    """))
    rows = result.mappings().all()
    return [dict(r) for r in rows]

@router.post("/", dependencies=[Depends(verify_token)])
async def create_tenant(body: TenantCreate, db: AsyncSession = Depends(get_db)):
    tenant_id = str(uuid.uuid4())
    await db.execute(text("""
        INSERT INTO tenants (id, slug, nome, evolution_key, evolution_instance, evolution_url,
                             llm_model, agent_name, agent_prompt)
        VALUES (:id, :slug, :nome, :evolution_key, :evolution_instance, :evolution_url,
                :llm_model, :agent_name, :agent_prompt)
    """), {
        "id": tenant_id, "slug": body.slug, "nome": body.nome,
        "evolution_key": body.evolution_key, "evolution_instance": body.evolution_instance,
        "evolution_url": body.evolution_url, "llm_model": body.llm_model,
        "agent_name": body.agent_name, "agent_prompt": body.agent_prompt,
    })
    await db.commit()
    webhook_url = f"{settings.BASE_URL}/webhook/{body.slug}"
    return {"id": tenant_id, "slug": body.slug, "webhook_url": webhook_url}

@router.get("/{tenant_id}", dependencies=[Depends(verify_token)])
async def get_tenant(tenant_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(text("SELECT * FROM tenants WHERE id = :id OR slug = :id"), {"id": tenant_id})
    row = result.mappings().first()
    if not row:
        raise HTTPException(404, "Tenant não encontrado")
    return dict(row)

@router.patch("/{tenant_id}", dependencies=[Depends(verify_token)])
async def update_tenant(tenant_id: str, body: TenantUpdate, db: AsyncSession = Depends(get_db)):
    updates = {k: v for k, v in body.model_dump().items() if v is not None}
    if not updates:
        raise HTTPException(400, "Nenhum campo para atualizar")
    set_clause = ", ".join(f"{k} = :{k}" for k in updates)
    updates["tenant_id"] = tenant_id
    await db.execute(
        text(f"UPDATE tenants SET {set_clause}, updated_at = NOW() WHERE id = :tenant_id OR slug = :tenant_id"),
        updates
    )
    await db.commit()
    return {"ok": True}

@router.delete("/{tenant_id}", dependencies=[Depends(verify_token)])
async def delete_tenant(tenant_id: str, db: AsyncSession = Depends(get_db)):
    await db.execute(text("DELETE FROM tenants WHERE id = :id OR slug = :id"), {"id": tenant_id})
    await db.commit()
    return {"ok": True}

@router.get("/{tenant_id}/contacts", dependencies=[Depends(verify_token)])
async def get_contacts(tenant_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(text("""
        SELECT c.*, 
               (SELECT content FROM messages m 
                WHERE m.tenant_id = c.tenant_id AND m.phone = c.phone 
                ORDER BY created_at DESC LIMIT 1) as last_message
        FROM contacts c 
        WHERE c.tenant_id = (SELECT id FROM tenants WHERE id = :id OR slug = :id)
        ORDER BY c.last_activity DESC NULLS LAST
    """), {"id": tenant_id})
    return [dict(r) for r in result.mappings().all()]

@router.get("/{tenant_id}/messages/{phone}", dependencies=[Depends(verify_token)])
async def get_messages(tenant_id: str, phone: str, limit: int = 100, db: AsyncSession = Depends(get_db)):
    result = await db.execute(text("""
        SELECT * FROM messages 
        WHERE tenant_id = (SELECT id FROM tenants WHERE id = :id OR slug = :id)
          AND phone = :phone
        ORDER BY created_at ASC LIMIT :limit
    """), {"id": tenant_id, "phone": phone, "limit": limit})
    return [dict(r) for r in result.mappings().all()]
EOF
ok "Routers criados"

# ════════════════════════════════════════
# FRONTEND — package.json + vite.config
# ════════════════════════════════════════
mkdir -p frontend/src/{pages,components,hooks}

cat > frontend/package.json << 'EOF'
{
  "name": "agentos-admin",
  "version": "2.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.4",
    "vite": "^6.0.3"
  }
}
EOF

cat > frontend/vite.config.js << 'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
})
EOF

cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>AgentOS Admin · troovi</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🤖</text></svg>">
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat > frontend/src/main.jsx << 'EOF'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
EOF

# ════════════════════════════════════════
# FRONTEND — App.jsx completo
# ════════════════════════════════════════
cat > frontend/src/App.jsx << 'APPEOF'
import React, { useState, useEffect, useCallback } from 'react'

const API    = import.meta.env.VITE_API_URL   || 'http://localhost:8000'
const TOKEN  = import.meta.env.VITE_ADMIN_TOKEN || ''

const api = (path, opts = {}) =>
  fetch(`${API}${path}`, {
    headers: { 'Content-Type': 'application/json', 'X-Admin-Token': TOKEN },
    ...opts,
  }).then(r => { if (!r.ok) throw new Error(r.statusText); return r.json() })

// ─── Estilos ───────────────────────────────────────────────────────────────
const css = `
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg: #f7f8fa;
    --panel: #ffffff;
    --border: #e5e7eb;
    --text: #111827;
    --text2: #374151;
    --muted: #6b7280;
    --muted2: #9ca3af;
    --blue: #2563eb;
    --blue-l: #dbeafe;
    --green: #16a34a;
    --green-l: #dcfce7;
    --red: #dc2626;
    --red-l: #fee2e2;
    --amber: #d97706;
    --amber-l: #fef3c7;
    --off: #f9fafb;
    --sh: 0 1px 3px rgba(0,0,0,.08);
    --sh2: 0 4px 16px rgba(0,0,0,.10);
    --radius: 10px;
    --mono: 'SF Mono', 'Fira Mono', monospace;
  }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: var(--bg); color: var(--text); }
  button { cursor: pointer; border: none; outline: none; font-family: inherit; }
  input, textarea, select { font-family: inherit; outline: none; }
`

// ─── Componentes utilitários ───────────────────────────────────────────────
const Badge = ({ color, children }) => {
  const colors = {
    green: { bg: 'var(--green-l)', color: 'var(--green)' },
    red:   { bg: 'var(--red-l)',   color: 'var(--red)'   },
    amber: { bg: 'var(--amber-l)', color: 'var(--amber)' },
    blue:  { bg: 'var(--blue-l)',  color: 'var(--blue)'  },
    gray:  { bg: 'var(--border)',  color: 'var(--muted)' },
  }
  const c = colors[color] || colors.gray
  return (
    <span style={{ background: c.bg, color: c.color, padding: '2px 8px', borderRadius: 100, fontSize: '.68rem', fontWeight: 700 }}>
      {children}
    </span>
  )
}

const Btn = ({ onClick, children, variant = 'primary', small, disabled }) => {
  const styles = {
    primary: { background: 'var(--blue)', color: '#fff' },
    danger:  { background: 'var(--red)',  color: '#fff' },
    ghost:   { background: 'transparent', color: 'var(--text)', border: '1px solid var(--border)' },
  }
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        ...styles[variant],
        padding: small ? '5px 12px' : '8px 16px',
        borderRadius: 8,
        fontSize: small ? '.78rem' : '.85rem',
        fontWeight: 600,
        opacity: disabled ? .5 : 1,
        transition: 'opacity .15s',
      }}
    >
      {children}
    </button>
  )
}

const Input = ({ label, value, onChange, placeholder, type = 'text', textarea }) => (
  <div style={{ marginBottom: 14 }}>
    {label && <label style={{ display: 'block', fontSize: '.78rem', fontWeight: 600, color: 'var(--text2)', marginBottom: 5 }}>{label}</label>}
    {textarea
      ? <textarea value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
          style={{ width: '100%', border: '1px solid var(--border)', borderRadius: 8, padding: '8px 12px', fontSize: '.85rem', minHeight: 100, resize: 'vertical', background: 'var(--off)' }} />
      : <input type={type} value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
          style={{ width: '100%', border: '1px solid var(--border)', borderRadius: 8, padding: '8px 12px', fontSize: '.85rem', background: 'var(--off)' }} />
    }
  </div>
)

// ─── Modal ─────────────────────────────────────────────────────────────────
const Modal = ({ title, onClose, children }) => (
  <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000, padding: 16 }}>
    <div style={{ background: '#fff', borderRadius: 14, width: '100%', maxWidth: 520, maxHeight: '90vh', overflow: 'auto', boxShadow: 'var(--sh2)' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '16px 20px', borderBottom: '1px solid var(--border)' }}>
        <h3 style={{ fontSize: '1rem', fontWeight: 700 }}>{title}</h3>
        <button onClick={onClose} style={{ background: 'none', fontSize: '1.3rem', color: 'var(--muted)', cursor: 'pointer' }}>×</button>
      </div>
      <div style={{ padding: 20 }}>{children}</div>
    </div>
  </div>
)

// ─── Sidebar ───────────────────────────────────────────────────────────────
const VIEWS = ['dashboard', 'clientes', 'conversas']

const Sidebar = ({ view, setView }) => (
  <aside style={{ width: 210, background: '#111827', display: 'flex', flexDirection: 'column', padding: '20px 0' }}>
    <div style={{ padding: '0 18px 20px', borderBottom: '1px solid rgba(255,255,255,.08)' }}>
      <div style={{ fontSize: '1.1rem', fontWeight: 800, color: '#fff', letterSpacing: '-.5px' }}>troovi</div>
      <div style={{ fontSize: '.68rem', color: 'rgba(255,255,255,.4)', marginTop: 2 }}>AgentOS Admin</div>
    </div>
    <nav style={{ flex: 1, padding: '12px 10px' }}>
      {VIEWS.map(v => (
        <div key={v} onClick={() => setView(v)} style={{
          padding: '9px 12px', borderRadius: 8, cursor: 'pointer', marginBottom: 2,
          background: view === v ? 'rgba(255,255,255,.1)' : 'transparent',
          color: view === v ? '#fff' : 'rgba(255,255,255,.5)',
          fontSize: '.83rem', fontWeight: view === v ? 600 : 400, textTransform: 'capitalize',
          transition: 'all .15s',
        }}>
          {v === 'dashboard' ? '📊 Dashboard' : v === 'clientes' ? '👥 Clientes' : '💬 Conversas'}
        </div>
      ))}
    </nav>
    <div style={{ padding: '12px 18px', borderTop: '1px solid rgba(255,255,255,.08)', fontSize: '.65rem', color: 'rgba(255,255,255,.25)' }}>
      v2.0.0 · {new Date().getFullYear()}
    </div>
  </aside>
)

// ─── Dashboard ─────────────────────────────────────────────────────────────
const Dashboard = ({ tenants }) => {
  const total    = tenants.length
  const active   = tenants.filter(t => t.active && !t.paused).length
  const paused   = tenants.filter(t => t.paused).length
  const contacts = tenants.reduce((a, t) => a + (Number(t.contacts) || 0), 0)

  const stat = (label, value, color) => (
    <div style={{ background: '#fff', borderRadius: 12, padding: '18px 20px', border: '1px solid var(--border)', boxShadow: 'var(--sh)' }}>
      <div style={{ fontSize: '.75rem', color: 'var(--muted)', fontWeight: 600, marginBottom: 6 }}>{label}</div>
      <div style={{ fontSize: '2rem', fontWeight: 800, color }}>{value}</div>
    </div>
  )

  return (
    <div>
      <h2 style={{ fontSize: '1.2rem', fontWeight: 700, marginBottom: 20 }}>Dashboard</h2>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 14, marginBottom: 28 }}>
        {stat('Total Clientes', total, 'var(--text)')}
        {stat('Ativos', active, 'var(--green)')}
        {stat('Pausados', paused, 'var(--amber)')}
        {stat('Contatos', contacts, 'var(--blue)')}
      </div>
      {tenants.length > 0 && (
        <>
          <h3 style={{ fontSize: '.9rem', fontWeight: 700, marginBottom: 12, color: 'var(--text2)' }}>Clientes recentes</h3>
          <div style={{ background: '#fff', borderRadius: 12, border: '1px solid var(--border)', overflow: 'hidden' }}>
            {tenants.slice(0, 5).map((t, i) => (
              <div key={t.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 18px', borderBottom: i < 4 ? '1px solid var(--border)' : 'none' }}>
                <div>
                  <div style={{ fontWeight: 600, fontSize: '.88rem' }}>{t.nome}</div>
                  <div style={{ fontSize: '.72rem', color: 'var(--muted)', fontFamily: 'var(--mono)' }}>{t.slug}</div>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: '.75rem', color: 'var(--muted)' }}>{t.contacts} contatos</span>
                  <Badge color={t.paused ? 'amber' : t.active ? 'green' : 'gray'}>
                    {t.paused ? 'Pausado' : t.active ? 'Ativo' : 'Inativo'}
                  </Badge>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}

// ─── Clientes ──────────────────────────────────────────────────────────────
const Clientes = ({ tenants, refresh }) => {
  const [showModal, setShowModal] = useState(false)
  const [editTenant, setEditTenant] = useState(null)
  const [webhookInfo, setWebhookInfo] = useState(null)
  const [form, setForm] = useState({ slug: '', nome: '', evolution_key: '', evolution_instance: '', evolution_url: 'https://evolution.troovi.site', llm_model: 'gpt-4o-mini', agent_name: 'Assistente', agent_prompt: '' })
  const [saving, setSaving] = useState(false)

  const f = k => v => setForm(prev => ({ ...prev, [k]: v }))

  const openNew = () => {
    setForm({ slug: '', nome: '', evolution_key: '', evolution_instance: '', evolution_url: 'https://evolution.troovi.site', llm_model: 'gpt-4o-mini', agent_name: 'Assistente', agent_prompt: '' })
    setEditTenant(null)
    setShowModal(true)
  }

  const openEdit = t => {
    setForm({ slug: t.slug, nome: t.nome, evolution_key: t.evolution_key || '', evolution_instance: t.evolution_instance || '', evolution_url: t.evolution_url || 'https://evolution.troovi.site', llm_model: t.llm_model || 'gpt-4o-mini', agent_name: t.agent_name || 'Assistente', agent_prompt: t.agent_prompt || '' })
    setEditTenant(t)
    setShowModal(true)
  }

  const save = async () => {
    setSaving(true)
    try {
      if (editTenant) {
        await api(`/tenants/${editTenant.id}`, { method: 'PATCH', body: JSON.stringify(form) })
      } else {
        const res = await api('/tenants/', { method: 'POST', body: JSON.stringify(form) })
        setWebhookInfo(res)
      }
      setShowModal(false)
      refresh()
    } catch (e) {
      alert('Erro: ' + e.message)
    } finally {
      setSaving(false)
    }
  }

  const toggleActive = async t => {
    await api(`/tenants/${t.id}`, { method: 'PATCH', body: JSON.stringify({ active: !t.active }) })
    refresh()
  }

  const togglePause = async t => {
    await api(`/tenants/${t.id}`, { method: 'PATCH', body: JSON.stringify({ paused: !t.paused }) })
    refresh()
  }

  const deleteTenant = async t => {
    if (!confirm(`Deletar ${t.nome}? Isso removerá todas as conversas.`)) return
    await api(`/tenants/${t.id}`, { method: 'DELETE' })
    refresh()
  }

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 }}>
        <h2 style={{ fontSize: '1.2rem', fontWeight: 700 }}>Clientes ({tenants.length})</h2>
        <Btn onClick={openNew}>+ Novo Cliente</Btn>
      </div>

      {tenants.length === 0 ? (
        <div style={{ textAlign: 'center', padding: 60, color: 'var(--muted)' }}>
          <div style={{ fontSize: '2rem', marginBottom: 12 }}>👥</div>
          <div style={{ fontWeight: 600 }}>Nenhum cliente ainda</div>
          <div style={{ fontSize: '.85rem', marginTop: 6 }}>Clique em "+ Novo Cliente" para começar</div>
        </div>
      ) : (
        <div style={{ display: 'grid', gap: 12 }}>
          {tenants.map(t => (
            <div key={t.id} style={{ background: '#fff', borderRadius: 12, border: '1px solid var(--border)', padding: '16px 20px', boxShadow: 'var(--sh)' }}>
              <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontWeight: 700, fontSize: '.95rem' }}>{t.nome}</span>
                    <Badge color={t.paused ? 'amber' : t.active ? 'green' : 'gray'}>
                      {t.paused ? 'Pausado' : t.active ? 'Ativo' : 'Inativo'}
                    </Badge>
                    <Badge color="blue">{t.llm_model || 'gpt-4o-mini'}</Badge>
                  </div>
                  <div style={{ fontSize: '.75rem', color: 'var(--muted)', fontFamily: 'var(--mono)', marginTop: 4 }}>
                    /{t.slug} · {t.contacts || 0} contatos · {t.messages || 0} msgs
                  </div>
                  <div style={{ fontSize: '.72rem', color: 'var(--muted2)', marginTop: 2 }}>
                    Instância: {t.evolution_instance} · Agente: {t.agent_name}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, flexShrink: 0, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                  <Btn small variant="ghost" onClick={() => openEdit(t)}>Editar</Btn>
                  <Btn small variant="ghost" onClick={() => togglePause(t)}>{t.paused ? 'Retomar' : 'Pausar'}</Btn>
                  <Btn small variant="ghost" onClick={() => setWebhookInfo({ slug: t.slug, webhook_url: `${API}/webhook/${t.slug}` })}>Webhook</Btn>
                  <Btn small variant="danger" onClick={() => deleteTenant(t)}>Excluir</Btn>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      {showModal && (
        <Modal title={editTenant ? `Editar ${editTenant.nome}` : 'Novo Cliente'} onClose={() => setShowModal(false)}>
          <Input label="Nome do cliente" value={form.nome} onChange={f('nome')} placeholder="Ex: Lorenna Estética" />
          {!editTenant && <Input label="Slug (único, sem espaços)" value={form.slug} onChange={f('slug')} placeholder="ex: lorenna" />}
          <Input label="Nome do agente" value={form.agent_name} onChange={f('agent_name')} placeholder="Ex: Maya" />
          <Input label="Evolution Instance" value={form.evolution_instance} onChange={f('evolution_instance')} placeholder="ex: lorenna-prod" />
          <Input label="Evolution API Key" value={form.evolution_key} onChange={f('evolution_key')} placeholder="sua chave" />
          <div style={{ marginBottom: 14 }}>
            <label style={{ display: 'block', fontSize: '.78rem', fontWeight: 600, color: 'var(--text2)', marginBottom: 5 }}>Modelo LLM</label>
            <select value={form.llm_model} onChange={e => f('llm_model')(e.target.value)}
              style={{ width: '100%', border: '1px solid var(--border)', borderRadius: 8, padding: '8px 12px', fontSize: '.85rem', background: 'var(--off)' }}>
              <option value="gpt-4o-mini">gpt-4o-mini (recomendado, mais barato)</option>
              <option value="gpt-4o">gpt-4o (mais capaz)</option>
              <option value="gpt-4-turbo">gpt-4-turbo</option>
            </select>
          </div>
          <Input label="Prompt do agente" value={form.agent_prompt} onChange={f('agent_prompt')} placeholder="Você é Maya, assistente da Lorenna Estética..." textarea />
          <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', marginTop: 8 }}>
            <Btn variant="ghost" onClick={() => setShowModal(false)}>Cancelar</Btn>
            <Btn onClick={save} disabled={saving}>{saving ? 'Salvando...' : editTenant ? 'Salvar' : 'Criar Cliente'}</Btn>
          </div>
        </Modal>
      )}

      {webhookInfo && (
        <Modal title="Webhook URL" onClose={() => setWebhookInfo(null)}>
          <p style={{ fontSize: '.85rem', color: 'var(--muted)', marginBottom: 12 }}>
            Cole esta URL na Evolution API para o cliente <strong>{webhookInfo.slug}</strong>:
          </p>
          <div style={{ background: 'var(--off)', border: '1px solid var(--border)', borderRadius: 8, padding: '10px 14px', fontFamily: 'var(--mono)', fontSize: '.8rem', wordBreak: 'break-all', marginBottom: 16 }}>
            {webhookInfo.webhook_url}
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            <Btn onClick={() => { navigator.clipboard.writeText(webhookInfo.webhook_url); alert('Copiado!') }}>Copiar URL</Btn>
            <Btn variant="ghost" onClick={() => setWebhookInfo(null)}>Fechar</Btn>
          </div>
        </Modal>
      )}
    </div>
  )
}

// ─── Conversas ─────────────────────────────────────────────────────────────
const Conversas = ({ tenants }) => {
  const [sel, setSel] = useState(null)
  const [conv, setConv] = useState(null)
  const [convs, setConvs] = useState([])
  const [msgs, setMsgs] = useState([])

  const loadContacts = useCallback(async t => {
    setSel(t); setConvs([]); setConv(null); setMsgs([])
    const data = await api(`/tenants/${t.id}/contacts`)
    setConvs(data)
  }, [])

  const loadMsgs = useCallback(async c => {
    setConv(c); setMsgs([])
    const data = await api(`/tenants/${sel.id}/messages/${c.phone}`)
    setMsgs(data)
  }, [sel])

  const col = { display: 'flex', flexDirection: 'column', background: '#fff', borderRadius: 12, border: '1px solid var(--border)', height: 600, overflow: 'hidden' }
  const colHead = { padding: '12px 16px', borderBottom: '1px solid var(--border)', fontWeight: 700, fontSize: '.85rem', background: '#fff', flexShrink: 0 }

  return (
    <div>
      <h2 style={{ fontSize: '1.2rem', fontWeight: 700, marginBottom: 20 }}>Conversas</h2>
      <div style={{ display: 'grid', gridTemplateColumns: '220px 260px 1fr', gap: 14 }}>
        {/* Clientes */}
        <div style={col}>
          <div style={colHead}>Clientes ({tenants.length})</div>
          <div style={{ overflowY: 'auto', flex: 1 }}>
            {tenants.map(t => (
              <div key={t.id} onClick={() => loadContacts(t)} style={{ padding: '10px 14px', borderBottom: '1px solid var(--border)', cursor: 'pointer', background: sel?.id === t.id ? 'var(--blue-l)' : 'transparent' }}>
                <div style={{ fontWeight: 600, fontSize: '.82rem' }}>{t.nome}</div>
                <div style={{ fontSize: '.68rem', color: 'var(--muted)', fontFamily: 'var(--mono)' }}>{t.slug}</div>
                <div style={{ fontSize: '.65rem', color: 'var(--muted2)', marginTop: 2 }}>{t.contacts} contatos</div>
              </div>
            ))}
          </div>
        </div>

        {/* Contatos */}
        <div style={col}>
          <div style={colHead}>Contatos {convs.length > 0 && `(${convs.length})`}</div>
          <div style={{ overflowY: 'auto', flex: 1 }}>
            {convs.map(c => (
              <div key={c.id} onClick={() => loadMsgs(c)} style={{ padding: '10px 14px', borderBottom: '1px solid var(--border)', cursor: 'pointer', background: conv?.id === c.id ? 'var(--blue-l)' : 'transparent' }}>
                <div style={{ fontSize: '.78rem', fontWeight: 700 }}>{c.nome || c.phone}</div>
                {c.nome && <div style={{ fontSize: '.65rem', color: 'var(--muted2)', fontFamily: 'var(--mono)' }}>{c.phone}</div>}
                <div style={{ fontSize: '.68rem', color: 'var(--muted2)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', marginTop: 2 }}>{c.last_message || 'Sem mensagens'}</div>
                {c.last_activity && <div style={{ fontSize: '.6rem', color: 'var(--muted2)', marginTop: 2 }}>{new Date(c.last_activity).toLocaleString('pt-BR')}</div>}
                <div style={{ display: 'flex', gap: 4, marginTop: 4, flexWrap: 'wrap' }}>
                  {c.conversation_closed && <Badge color="gray">Encerrada</Badge>}
                  {c.followup_1_sent && <Badge color="amber">FU1 ✓</Badge>}
                  {c.followup_2_sent && <Badge color="amber">FU2 ✓</Badge>}
                </div>
              </div>
            ))}
            {sel && convs.length === 0 && <div style={{ padding: 20, fontSize: '.8rem', color: 'var(--muted)', textAlign: 'center' }}>Sem contatos ainda</div>}
            {!sel && <div style={{ padding: 20, fontSize: '.8rem', color: 'var(--muted)', textAlign: 'center' }}>← Selecione um cliente</div>}
          </div>
        </div>

        {/* Mensagens */}
        <div style={{ ...col, background: 'var(--off)' }}>
          <div style={{ ...colHead, background: '#fff' }}>{conv ? (conv.nome || conv.phone) : 'Selecione uma conversa'}</div>
          <div style={{ flex: 1, overflowY: 'auto', padding: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
            {msgs.map(m => (
              <div key={m.id} style={{ display: 'flex', justifyContent: m.role === 'user' ? 'flex-start' : 'flex-end' }}>
                <div style={{
                  maxWidth: '76%', padding: '8px 12px',
                  borderRadius: m.role === 'user' ? '12px 12px 12px 3px' : '12px 12px 3px 12px',
                  background: m.role === 'user' ? '#fff' : 'var(--blue)',
                  color: m.role === 'user' ? 'var(--text)' : '#fff',
                  fontSize: '.8rem', lineHeight: 1.6,
                  border: m.role === 'user' ? '1px solid var(--border)' : 'none',
                  boxShadow: 'var(--sh)', whiteSpace: 'pre-wrap', wordBreak: 'break-word',
                }}>
                  {m.content}
                  <div style={{ fontSize: '.6rem', opacity: .6, marginTop: 4, textAlign: 'right' }}>
                    {new Date(m.created_at).toLocaleTimeString('pt-BR')}
                  </div>
                </div>
              </div>
            ))}
            {conv && msgs.length === 0 && <div style={{ textAlign: 'center', color: 'var(--muted)', fontSize: '.82rem', marginTop: 20 }}>Sem mensagens</div>}
          </div>
        </div>
      </div>
    </div>
  )
}

// ─── App principal ─────────────────────────────────────────────────────────
export default function App() {
  const [view, setView] = useState('dashboard')
  const [tenants, setTenants] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const loadTenants = useCallback(async () => {
    try {
      const data = await api('/tenants/')
      setTenants(data)
      setError(null)
    } catch (e) {
      setError('Não foi possível conectar à API. Verifique se o backend está rodando.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { loadTenants() }, [loadTenants])

  return (
    <>
      <style>{css}</style>
      <div style={{ display: 'flex', minHeight: '100vh' }}>
        <Sidebar view={view} setView={setView} />
        <main style={{ flex: 1, padding: '28px 32px', overflowY: 'auto' }}>
          {error && (
            <div style={{ background: 'var(--red-l)', color: 'var(--red)', borderRadius: 10, padding: '12px 16px', marginBottom: 20, fontSize: '.85rem', fontWeight: 500 }}>
              ⚠ {error}
            </div>
          )}
          {loading ? (
            <div style={{ textAlign: 'center', color: 'var(--muted)', marginTop: 60, fontSize: '.9rem' }}>Carregando...</div>
          ) : (
            <>
              {view === 'dashboard'  && <Dashboard tenants={tenants} />}
              {view === 'clientes'   && <Clientes  tenants={tenants} refresh={loadTenants} />}
              {view === 'conversas'  && <Conversas tenants={tenants} />}
            </>
          )}
        </main>
      </div>
    </>
  )
}
APPEOF
ok "Frontend (App.jsx) criado"

cat > frontend/.env << ENVEOF
VITE_API_URL=https://${API_DOMAIN}
VITE_ADMIN_TOKEN=${ADMIN_TOKEN}
ENVEOF

# ════════════════════════════════════════
# docker-compose.yml — CORRIGIDO
# ════════════════════════════════════════
cat > docker-compose.yml << 'COMPOSEEOF'
services:
  agentos-api:
    build: ./backend
    container_name: agentos-api
    restart: unless-stopped
    ports:
      - "8000:8000"
    env_file: .env
    depends_on:
      postgres-agentos:
        condition: service_healthy
    networks:
      - agentos-net

  postgres-agentos:
    image: pgvector/pgvector:pg16
    container_name: postgres-agentos
    restart: unless-stopped
    environment:
      POSTGRES_DB: agentos
      POSTGRES_USER: agentos
      POSTGRES_PASSWORD: ${AGENTOS_DB_PASS}
    volumes:
      - agentos-pg-data:/var/lib/postgresql/data
      - ./backend/init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U agentos -d agentos"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    networks:
      - agentos-net

  agentos-nginx:
    image: nginx:alpine
    container_name: agentos-nginx
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./frontend/dist:/usr/share/nginx/html:ro
    depends_on:
      - agentos-api
    networks:
      - agentos-net

volumes:
  agentos-pg-data:

networks:
  agentos-net:
    driver: bridge
COMPOSEEOF

# Detecta se a rede n8n_default existe e adiciona ao compose
if docker network inspect n8n_default &>/dev/null 2>&1; then
  warn "Rede n8n_default detectada — adicionando ao compose para coexistência"
  cat >> docker-compose.yml << 'NETEOF'
  n8n-net:
    external: true
    name: n8n_default
NETEOF
  # Adiciona n8n-net ao agentos-api
  sed -i '/container_name: agentos-api/,/networks:/{/networks:/{ n; s/      - agentos-net/      - agentos-net\n      - n8n-net/ }}' docker-compose.yml
  ok "Rede n8n_default integrada"
fi

ok "docker-compose.yml criado (YAML válido)"

# ════════════════════════════════════════
# nginx.conf
# ════════════════════════════════════════
cat > nginx.conf << NGINXEOF
events {
  worker_connections 1024;
}

http {
  include      mime.types;
  default_type application/octet-stream;

  gzip on;
  gzip_types text/plain application/json application/javascript text/css application/xml;
  gzip_min_length 1000;

  # API → FastAPI
  server {
    listen 80;
    server_name ${API_DOMAIN};

    location / {
      proxy_pass         http://agentos-api:8000;
      proxy_http_version 1.1;
      proxy_set_header   Host              \$host;
      proxy_set_header   X-Real-IP         \$remote_addr;
      proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_read_timeout 120s;
    }
  }

  # Admin → SPA React
  server {
    listen 80;
    server_name ${ADMIN_DOMAIN};
    root  /usr/share/nginx/html;
    index index.html;

    location / {
      try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(js|css|png|svg|ico|woff2)\$ {
      expires 30d;
      add_header Cache-Control "public, immutable";
    }
  }
}
NGINXEOF
ok "nginx.conf criado"

# ════════════════════════════════════════
# .gitignore
# ════════════════════════════════════════
cat > .gitignore << 'EOF'
.env
node_modules/
frontend/dist/
__pycache__/
*.pyc
.venv/
*.egg-info/
*.log
.DS_Store
EOF
ok ".gitignore criado"

# ════════════════════════════════════════
# GitHub Actions — CI/CD
# ════════════════════════════════════════
step "Criando CI/CD (GitHub Actions)"
mkdir -p .github/workflows

cat > .github/workflows/deploy.yml << 'GHEOF'
name: Deploy AgentOS

on:
  push:
    branches: [main]

jobs:
  deploy:
    name: Deploy no Droplet
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: frontend/package-lock.json

      - name: Build frontend
        working-directory: frontend
        run: |
          npm ci
          npm run build

      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.DROPLET_IP }}
          username: ${{ secrets.DROPLET_USER }}
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: |
            set -e
            cd ${{ secrets.PROJECT_DIR }}
            echo "▶ Atualizando código..."
            git pull origin main
            echo "▶ Reiniciando backend..."
            docker compose up -d --build agentos-api
            echo "✓ Deploy backend concluído"

      - name: Copiar dist via SCP
        uses: appleboy/scp-action@v0.1.7
        with:
          host: ${{ secrets.DROPLET_IP }}
          username: ${{ secrets.DROPLET_USER }}
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          source: frontend/dist/*
          target: ${{ secrets.PROJECT_DIR }}/frontend/dist
          strip_components: 2

      - name: Reload nginx
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.DROPLET_IP }}
          username: ${{ secrets.DROPLET_USER }}
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: |
            cd ${{ secrets.PROJECT_DIR }}
            docker compose restart agentos-nginx
            echo "✓ Nginx recarregado"
GHEOF
ok "GitHub Actions criado"

# ════════════════════════════════════════
# Verificação de dependências
# ════════════════════════════════════════
step "Verificando dependências"
command -v docker &>/dev/null || { warn "Instalando Docker..."; curl -fsSL https://get.docker.com | sh; systemctl enable --now docker; }
command -v node   &>/dev/null || {
  warn "Instalando Node 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
}
ok "Dependências OK"

# ════════════════════════════════════════
# Build frontend
# ════════════════════════════════════════
step "Buildando frontend"
cd frontend
npm install --silent
npm run build
cd ..
ok "Build completo → frontend/dist/"

# ════════════════════════════════════════
# Subindo containers
# ════════════════════════════════════════
step "Subindo containers"
docker compose up -d --build
ok "Containers iniciados"

step "Aguardando banco ficar pronto"
for i in {1..12}; do
  docker compose exec -T postgres-agentos pg_isready -U agentos -d agentos 2>/dev/null && break
  echo "  Aguardando... ($i/12)"
  sleep 5
done
docker compose exec -T postgres-agentos pg_isready -U agentos -d agentos && ok "Banco pronto" || warn "Banco demorando — verifique com: docker compose logs postgres-agentos"

# ════════════════════════════════════════
# Resumo
# ════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗"
echo   "║   ✅  AgentOS v2 instalado com sucesso!         ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Acesso:${NC}"
echo -e "  ${CYAN}Painel Admin:${NC}  http://${ADMIN_DOMAIN}"
echo -e "  ${CYAN}API:${NC}           http://${API_DOMAIN}"
echo -e "  ${CYAN}Health:${NC}        http://${API_DOMAIN}/health"
echo ""
echo -e "${BOLD}${YELLOW}Admin Token (guarde!):${NC}"
echo -e "  ${YELLOW}${ADMIN_TOKEN}${NC}"
echo ""
echo -e "${BOLD}Para CI/CD via GitHub Actions, adicione estes Secrets:${NC}"
echo -e "  ${CYAN}DROPLET_IP${NC}    → $(curl -s ifconfig.me 2>/dev/null || echo 'seu IP')"
echo -e "  ${CYAN}DROPLET_USER${NC}  → $(whoami)"
echo -e "  ${CYAN}PROJECT_DIR${NC}   → $(pwd)"
echo -e "  ${CYAN}DEPLOY_SSH_KEY${NC}→ sua chave SSH privada"
echo ""
echo -e "${BOLD}Comandos úteis:${NC}"
echo -e "  ${CYAN}docker compose logs -f agentos-api${NC}     — logs em tempo real"
echo -e "  ${CYAN}docker compose ps${NC}                      — status dos containers"
echo -e "  ${CYAN}docker compose restart agentos-api${NC}     — reiniciar backend"
echo -e "  ${CYAN}docker compose exec agentos-api bash${NC}   — entrar no container"
echo ""
echo -e "${BOLD}Próximos passos:${NC}"
echo -e "  1. Aponte ${CYAN}${API_DOMAIN}${NC} e ${CYAN}${ADMIN_DOMAIN}${NC} para o IP do Droplet"
echo -e "  2. Acesse http://${ADMIN_DOMAIN} com o token acima"
echo -e "  3. Crie um cliente e copie o webhook para a Evolution API"
echo -e "  4. Configure GitHub Actions com os secrets listados acima"

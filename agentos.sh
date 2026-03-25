#!/bin/bash
# =============================================================
# AgentOS — Setup Completo
# Troovi · WhatsApp AI Platform
# Execute: bash setup_agentos.sh
# =============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${BLUE}${BOLD}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${CYAN}  $1${NC}"; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║   troovi · AgentOS · Setup Completo     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

step "Configuração inicial"
read -p "$(echo -e "${BOLD}OpenAI API Key:${NC} ")" OPENAI_KEY
read -p "$(echo -e "${BOLD}Senha do banco (crie uma forte):${NC} ")" DB_PASS
read -p "$(echo -e "${BOLD}Domínio da API (ex: api.troovi.site):${NC} ")" API_DOMAIN
read -p "$(echo -e "${BOLD}Domínio do Admin (ex: admin.troovi.site):${NC} ")" ADMIN_DOMAIN

SECRET_KEY=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 16)

ok "Configuração coletada"
info "API:   https://$API_DOMAIN"
info "Admin: https://$ADMIN_DOMAIN"

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
# requirements.txt
# ════════════════════════════════════════
cat > backend/requirements.txt << 'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.0
python-multipart==0.0.9
httpx==0.27.2
langgraph==0.2.50
langchain==0.3.7
langchain-openai==0.2.9
langchain-postgres==0.0.12
sqlalchemy[asyncio]==2.0.35
asyncpg==0.30.0
psycopg[binary]==3.2.3
alembic==1.14.0
pgvector==0.3.5
redis[asyncio]==5.2.0
google-api-python-client==2.150.0
google-auth==2.35.0
apscheduler==3.10.4
pydantic-settings==2.6.0
python-dotenv==1.0.1
pytz==2024.1
EOF

# ════════════════════════════════════════
# Dockerfile
# ════════════════════════════════════════
cat > backend/Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc libpq-dev && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
EOF

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
    google_sa_json       TEXT,   -- JSON completo do service account
    calendar_id          TEXT,   -- email do calendário compartilhado
    -- Follow-up mensagens customizadas
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

    class Config:
        env_file = ".env"

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
from sqlalchemy.orm import DeclarativeBase
from .config import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    pool_size=10, max_overflow=20,
    echo=settings.ENVIRONMENT == "development"
)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

class Base(DeclarativeBase):
    pass

async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
EOF

# ════════════════════════════════════════
# models
# ════════════════════════════════════════
cat > backend/app/models/__init__.py << 'EOF'
from .tenant import Tenant
from .contact import Contact
from .message import Message
EOF

cat > backend/app/models/tenant.py << 'EOF'
from sqlalchemy import Column, String, Boolean, Text, Integer
from sqlalchemy.dialects.postgresql import UUID, JSONB, TIMESTAMPTZ
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from ..database import Base
import uuid

class Tenant(Base):
    __tablename__ = "tenants"
    id                 = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    slug               = Column(String, unique=True, nullable=False)
    nome               = Column(String, nullable=False)
    evolution_url      = Column(String, nullable=False, default="https://evolution.troovi.site")
    evolution_key      = Column(String, nullable=False)
    evolution_instance = Column(String, nullable=False)
    openai_key         = Column(String, nullable=True)
    llm_model          = Column(String, default="gpt-4o-mini")
    agent_name         = Column(String, default="Assistente")
    agent_prompt       = Column(Text, nullable=True)
    business_hours     = Column(JSONB, nullable=True)
    google_sa_json     = Column(Text, nullable=True)   # service account completo
    calendar_id        = Column(String, nullable=True)
    followup_1_msg     = Column(Text, nullable=True)
    followup_2_msg     = Column(Text, nullable=True)
    followup_1_hours   = Column(Integer, default=24)
    followup_2_hours   = Column(Integer, default=48)
    active             = Column(Boolean, default=True)
    paused             = Column(Boolean, default=False)
    plan               = Column(String, default="starter")
    created_at         = Column(TIMESTAMPTZ, server_default=func.now())
    updated_at         = Column(TIMESTAMPTZ, server_default=func.now(), onupdate=func.now())
    contacts  = relationship("Contact", back_populates="tenant", cascade="all, delete")
    messages  = relationship("Message", back_populates="tenant", cascade="all, delete")
EOF

cat > backend/app/models/contact.py << 'EOF'
from sqlalchemy import Column, String, Boolean, ForeignKey
from sqlalchemy.dialects.postgresql import UUID, TIMESTAMPTZ
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from ..database import Base
import uuid

class Contact(Base):
    __tablename__ = "contacts"
    id                  = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id           = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"))
    phone               = Column(String, nullable=False)
    nome                = Column(String, nullable=True)
    email               = Column(String, nullable=True)
    followup_1_sent     = Column(Boolean, default=False)
    followup_2_sent     = Column(Boolean, default=False)
    conversation_closed = Column(Boolean, default=False)
    last_activity       = Column(TIMESTAMPTZ, nullable=True)
    created_at          = Column(TIMESTAMPTZ, server_default=func.now())
    tenant   = relationship("Tenant",  back_populates="contacts")
    messages = relationship("Message", back_populates="contact", cascade="all, delete")
EOF

cat > backend/app/models/message.py << 'EOF'
from sqlalchemy import Column, String, Text, ForeignKey
from sqlalchemy.dialects.postgresql import UUID, TIMESTAMPTZ
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from ..database import Base
import uuid

class Message(Base):
    __tablename__ = "messages"
    id         = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id  = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"))
    contact_id = Column(UUID(as_uuid=True), ForeignKey("contacts.id"), nullable=True)
    phone      = Column(String, nullable=False)
    role       = Column(String, nullable=False)
    content    = Column(Text, nullable=True)
    created_at = Column(TIMESTAMPTZ, server_default=func.now())
    tenant  = relationship("Tenant",  back_populates="messages")
    contact = relationship("Contact", back_populates="messages")
EOF
ok "Models criados"

# ════════════════════════════════════════
# services/evolution.py
# ════════════════════════════════════════
cat > backend/app/services/__init__.py << 'EOF'
EOF

cat > backend/app/services/evolution.py << 'EOF'
import httpx
import logging

logger = logging.getLogger(__name__)

async def send_message(tenant, phone: str, text: str) -> bool:
    url = f"{tenant.evolution_url}/message/sendText/{tenant.evolution_instance}"
    headers = {"apikey": tenant.evolution_key, "Content-Type": "application/json"}
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            r = await client.post(url, json={"number": phone, "text": text}, headers=headers)
            r.raise_for_status()
            return True
    except Exception as e:
        logger.error(f"Evolution sendMessage error [{phone}]: {e}")
        return False

async def send_typing(tenant, phone: str):
    url = f"{tenant.evolution_url}/chat/sendPresence/{tenant.evolution_instance}"
    headers = {"apikey": tenant.evolution_key, "Content-Type": "application/json"}
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(url, json={"number": phone, "options": {"presence": "composing", "delay": 2000}}, headers=headers)
    except Exception:
        pass

async def check_instance(evolution_url: str, evolution_key: str, instance: str) -> dict:
    """Verifica estado da instância — usado no cadastro para testar conexão."""
    url = f"{evolution_url}/instance/connectionState/{instance}"
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            r = await client.get(url, headers={"apikey": evolution_key})
            data = r.json()
            state = data.get("instance", {}).get("state", data.get("state", "unknown"))
            return {"ok": state == "open", "state": state, "raw": data}
    except Exception as e:
        return {"ok": False, "state": "error", "error": str(e)}

async def fetch_instances(evolution_url: str, evolution_key: str) -> list:
    """Lista instâncias disponíveis na Evolution — para autocomplete no cadastro."""
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            r = await client.get(
                f"{evolution_url}/instance/fetchInstances",
                headers={"apikey": evolution_key}
            )
            data = r.json()
            if isinstance(data, list):
                return [{"name": i.get("instance", {}).get("instanceName", i.get("instanceName", "")),
                         "state": i.get("instance", {}).get("state", i.get("state", ""))} for i in data]
            return []
    except Exception:
        return []
EOF

# ════════════════════════════════════════
# services/calendar.py  (Service Account)
# ════════════════════════════════════════
cat > backend/app/services/calendar.py << 'EOF'
"""
Google Calendar via Service Account.
Sem OAuth, sem tela de login, sem token expirando.

Como funciona:
1. Você cria um Service Account no Google Cloud
2. Baixa o JSON do service account
3. Compartilha o calendário do cliente com o email do service account
4. Cola o JSON no painel — pronto, funciona para sempre
"""
import json
import logging
from datetime import datetime, timedelta
import pytz

logger = logging.getLogger(__name__)

def _build_service(sa_json: str):
    """Cria cliente autenticado com o service account."""
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    info = json.loads(sa_json)
    creds = service_account.Credentials.from_service_account_info(
        info,
        scopes=["https://www.googleapis.com/auth/calendar"]
    )
    return build("calendar", "v3", credentials=creds)

def test_service_account(sa_json: str, calendar_id: str) -> dict:
    """
    Testa se o service account consegue acessar o calendário.
    Chamado no painel antes de salvar.
    """
    try:
        service = _build_service(sa_json)
        cal = service.calendars().get(calendarId=calendar_id).execute()
        return {
            "ok": True,
            "calendar_name": cal.get("summary", ""),
            "timezone": cal.get("timeZone", ""),
        }
    except Exception as e:
        msg = str(e)
        if "404" in msg:
            return {"ok": False, "error": "Calendário não encontrado. Verifique o Calendar ID e se você compartilhou com o service account."}
        if "403" in msg:
            return {"ok": False, "error": "Permissão negada. Compartilhe o calendário com o email do service account."}
        return {"ok": False, "error": msg}

def get_free_slots(sa_json: str, calendar_id: str, date_str: str,
                   work_start: int = 8, work_end: int = 18,
                   slot_minutes: int = 60) -> list[str]:
    """Retorna horários livres para uma data (YYYY-MM-DD)."""
    try:
        service = _build_service(sa_json)
        tz = pytz.timezone("America/Sao_Paulo")
        day = tz.localize(datetime.strptime(date_str, "%Y-%m-%d"))

        result = service.events().list(
            calendarId=calendar_id,
            timeMin=day.isoformat(),
            timeMax=(day + timedelta(days=1)).isoformat(),
            singleEvents=True,
            orderBy="startTime"
        ).execute()

        busy = []
        for e in result.get("items", []):
            start = e.get("start", {})
            end   = e.get("end",   {})
            if "dateTime" in start:
                busy.append((
                    datetime.fromisoformat(start["dateTime"]),
                    datetime.fromisoformat(end["dateTime"])
                ))

        # Gera slots de 30 em 30, marca livre se não conflita
        slots = []
        t = day.replace(hour=work_start, minute=0, second=0, microsecond=0)
        end_work = day.replace(hour=work_end, minute=0, second=0, microsecond=0)

        while t + timedelta(minutes=slot_minutes) <= end_work:
            t_end = t + timedelta(minutes=slot_minutes)
            conflict = any(b[0] < t_end and b[1] > t for b in busy)
            if not conflict:
                slots.append(t.strftime("%H:%M"))
            t += timedelta(minutes=30)

        return slots
    except Exception as e:
        logger.error(f"get_free_slots error: {e}")
        return []

def create_event(sa_json: str, calendar_id: str,
                 summary: str, date_str: str, time_str: str,
                 duration_min: int = 60, description: str = "") -> dict:
    """Cria evento no calendário."""
    try:
        service = _build_service(sa_json)
        tz = pytz.timezone("America/Sao_Paulo")
        start = tz.localize(datetime.strptime(f"{date_str} {time_str}", "%Y-%m-%d %H:%M"))
        end   = start + timedelta(minutes=duration_min)

        event = service.events().insert(
            calendarId=calendar_id,
            body={
                "summary": summary,
                "description": description,
                "start": {"dateTime": start.isoformat(), "timeZone": "America/Sao_Paulo"},
                "end":   {"dateTime": end.isoformat(),   "timeZone": "America/Sao_Paulo"},
            }
        ).execute()
        return {"ok": True, "event_id": event["id"], "link": event.get("htmlLink", "")}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def delete_event(sa_json: str, calendar_id: str, event_id: str) -> dict:
    """Cancela evento pelo ID."""
    try:
        service = _build_service(sa_json)
        service.events().delete(calendarId=calendar_id, eventId=event_id).execute()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}
EOF

# ════════════════════════════════════════
# services/debounce.py
# ════════════════════════════════════════
cat > backend/app/services/debounce.py << 'EOF'
import asyncio, logging
from typing import Callable
import redis.asyncio as aioredis
from ..config import settings

logger = logging.getLogger(__name__)

class DebounceManager:
    """Acumula mensagens por DELAY segundos antes de chamar o agente."""
    def __init__(self, redis_url: str, delay: float = 3.0):
        self.redis  = aioredis.from_url(redis_url)
        self.delay  = delay
        self._tasks: dict[str, asyncio.Task] = {}

    async def schedule(self, tenant, phone: str, text: str, callback: Callable):
        key = f"{tenant.slug}:{phone}"
        await self.redis.rpush(f"msg:{key}", text.encode())
        await self.redis.expire(f"msg:{key}", 120)
        if key in self._tasks:
            self._tasks[key].cancel()
        self._tasks[key] = asyncio.create_task(self._fire(key, tenant, phone, callback))

    async def _fire(self, key, tenant, phone, callback):
        await asyncio.sleep(self.delay)
        try:
            pipe = self.redis.pipeline()
            pipe.lrange(f"msg:{key}", 0, -1)
            pipe.delete(f"msg:{key}")
            results = await pipe.execute()
            msgs = [m.decode() for m in results[0]]
            if not msgs: return
            self._tasks.pop(key, None)
            await callback(tenant, phone, msgs)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Debounce error [{key}]: {e}")
            self._tasks.pop(key, None)

debounce_manager = DebounceManager(settings.REDIS_URL, settings.DEBOUNCE_DELAY)
EOF

# ════════════════════════════════════════
# services/scheduler.py
# ════════════════════════════════════════
cat > backend/app/services/scheduler.py << 'EOF'
import logging
from datetime import datetime, timedelta
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from sqlalchemy import select, and_
from ..database import AsyncSessionLocal
from ..models import Contact, Tenant
from .evolution import send_message

logger = logging.getLogger(__name__)
scheduler = AsyncIOScheduler(timezone="America/Sao_Paulo")

@scheduler.scheduled_job("interval", hours=1)
async def send_followups():
    async with AsyncSessionLocal() as db:
        try:
            now = datetime.utcnow()
            tenants_r = await db.execute(select(Tenant).where(Tenant.active == True, Tenant.paused == False))
            for tenant in tenants_r.scalars():
                h1 = tenant.followup_1_hours or 24
                h2 = tenant.followup_2_hours or 48
                msg1 = tenant.followup_1_msg or f"Oi! Aqui é {tenant.agent_name} da {tenant.nome} 😊 Ficou alguma dúvida? Estou por aqui!"
                msg2 = tenant.followup_2_msg or f"Passando para ver se posso te ajudar! Qualquer coisa é só chamar 🌟"

                q1 = select(Contact).where(and_(
                    Contact.tenant_id == tenant.id,
                    Contact.last_activity < now - timedelta(hours=h1),
                    Contact.followup_1_sent == False,
                    Contact.conversation_closed == False
                ))
                for c in (await db.execute(q1)).scalars():
                    if await send_message(tenant, c.phone, msg1):
                        c.followup_1_sent = True

                q2 = select(Contact).where(and_(
                    Contact.tenant_id == tenant.id,
                    Contact.last_activity < now - timedelta(hours=h2),
                    Contact.followup_1_sent == True,
                    Contact.followup_2_sent == False,
                    Contact.conversation_closed == False
                ))
                for c in (await db.execute(q2)).scalars():
                    if await send_message(tenant, c.phone, msg2):
                        c.followup_2_sent = True
                        c.conversation_closed = True

            await db.commit()
        except Exception as e:
            logger.error(f"Scheduler error: {e}")
            await db.rollback()
EOF

# ════════════════════════════════════════
# agent/prompts.py
# ════════════════════════════════════════
cat > backend/app/agent/__init__.py << 'EOF'
EOF

cat > backend/app/agent/prompts.py << 'EOF'
from datetime import datetime
import pytz

def build_system_prompt(tenant, contact=None) -> str:
    tz  = pytz.timezone("America/Sao_Paulo")
    now = datetime.now(tz)
    contact_block = ""
    if contact:
        nome     = contact.nome or "Não identificado"
        primeiro = nome.split()[0]
        contact_block = f"""
<clientData>
Telefone: {contact.phone}
Nome: {nome}
Primeiro nome: {primeiro}
</clientData>"""

    base = tenant.agent_prompt or f"Você é {tenant.agent_name}, assistente virtual da {tenant.nome}. Seja prestativo, simpático e objetivo. Responda sempre em português brasileiro."

    return f"""# AGENTE: {tenant.agent_name} | EMPRESA: {tenant.nome}

{base}
{contact_block}

<systemData>
Agora: {now.strftime('%A, %d/%m/%Y %H:%M')}
</systemData>

REGRAS:
- NUNCA pergunte o nome — use clientData se disponível
- Não liste todos os serviços de uma vez
- Seja conciso e direto
- Use emojis com moderação
"""
EOF

# ════════════════════════════════════════
# agent/tools.py
# ════════════════════════════════════════
cat > backend/app/agent/tools.py << 'EOF'
import logging
from langchain_core.tools import StructuredTool
from langchain_postgres import PGVector
from langchain_openai import OpenAIEmbeddings
from ..config import settings
from ..services.calendar import get_free_slots, create_event, delete_event

logger = logging.getLogger(__name__)

def make_rag_tool(tenant):
    try:
        vs = PGVector(
            connection=settings.DATABASE_URL.replace("+asyncpg", ""),
            embeddings=OpenAIEmbeddings(
                model="text-embedding-3-small",
                api_key=tenant.openai_key or settings.OPENAI_API_KEY
            ),
            collection_name=f"docs_{tenant.slug}",
        )
        retriever = vs.as_retriever(search_kwargs={"k": 5})
    except Exception as e:
        logger.warning(f"RAG indisponível para {tenant.slug}: {e}")
        retriever = None

    def busca_documentos(query: str) -> str:
        """Busca informações sobre serviços, preços e condições da empresa."""
        if not retriever:
            return "Base de conhecimento não configurada."
        try:
            docs = retriever.invoke(query)
            return "\n\n---\n\n".join(d.page_content for d in docs) if docs else "Nenhuma informação encontrada."
        except Exception as e:
            return f"Erro na busca: {e}"

    return StructuredTool(name="busca_documentos", func=busca_documentos,
        description="Consulta documentos sobre serviços, preços e condições. Use sempre que precisar de info específica.")

def make_calendar_tools(tenant):
    """Calendar tools usando Service Account — sem OAuth."""
    sa  = tenant.google_sa_json
    cid = tenant.calendar_id

    def buscar_horarios(data: str) -> str:
        """Verifica horários livres para uma data no formato YYYY-MM-DD."""
        slots = get_free_slots(sa, cid, data)
        return "Horários disponíveis:\n" + "\n".join(f"• {s}" for s in slots) if slots else "Sem horários disponíveis neste dia."

    def criar_agendamento(resumo: str, data: str, hora: str, duracao_minutos: int = 60, descricao: str = "") -> str:
        """Cria um agendamento. data: YYYY-MM-DD, hora: HH:MM"""
        r = create_event(sa, cid, resumo, data, hora, duracao_minutos, descricao)
        return f"✅ Agendado: {resumo} em {data} às {hora}" if r["ok"] else f"Erro: {r['error']}"

    def cancelar_agendamento(event_id: str) -> str:
        """Cancela um agendamento pelo ID."""
        r = delete_event(sa, cid, event_id)
        return "✅ Cancelado com sucesso." if r["ok"] else f"Erro: {r['error']}"

    return [
        StructuredTool(name="buscar_horarios",      func=buscar_horarios,      description="Verifica horários livres para uma data (YYYY-MM-DD)"),
        StructuredTool(name="criar_agendamento",    func=criar_agendamento,    description="Cria um agendamento no calendário do cliente"),
        StructuredTool(name="cancelar_agendamento", func=cancelar_agendamento, description="Cancela um agendamento pelo ID do evento"),
    ]

async def get_tools_for_tenant(tenant) -> list:
    tools = [make_rag_tool(tenant)]
    if tenant.google_sa_json and tenant.calendar_id:
        try:
            tools.extend(make_calendar_tools(tenant))
        except Exception as e:
            logger.warning(f"Calendar tools indisponíveis para {tenant.slug}: {e}")
    return tools
EOF

# ════════════════════════════════════════
# agent/graph.py
# ════════════════════════════════════════
cat > backend/app/agent/graph.py << 'EOF'
import logging
from typing import TypedDict, Annotated
from langchain_openai import ChatOpenAI
from langchain_core.messages import SystemMessage, BaseMessage
from langchain_core.runnables import RunnableConfig
from langgraph.graph import StateGraph, END, START
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from langgraph.prebuilt import ToolNode
from langgraph.graph.message import add_messages
from .prompts import build_system_prompt
from .tools import get_tools_for_tenant
from ..config import settings

logger = logging.getLogger(__name__)

class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]

_graphs: dict = {}

async def get_graph(tenant):
    if tenant.id not in _graphs:
        tools = await get_tools_for_tenant(tenant)
        db_url = settings.DATABASE_URL.replace("+asyncpg", "")
        checkpointer = await AsyncPostgresSaver.from_conn_string(db_url)
        await checkpointer.setup()

        def agent_node(state: AgentState):
            llm = ChatOpenAI(
                model=tenant.llm_model,
                api_key=tenant.openai_key or settings.OPENAI_API_KEY,
                temperature=0.3, max_tokens=800,
            ).bind_tools(tools)
            response = llm.invoke([SystemMessage(content=build_system_prompt(tenant))] + state["messages"])
            return {"messages": [response]}

        def should_continue(state: AgentState):
            last = state["messages"][-1]
            return "tools" if (hasattr(last, "tool_calls") and last.tool_calls) else END

        builder = StateGraph(AgentState)
        builder.add_node("agent", agent_node)
        builder.add_node("tools", ToolNode(tools))
        builder.add_edge(START, "agent")
        builder.add_conditional_edges("agent", should_continue, {"tools": "tools", END: END})
        builder.add_edge("tools", "agent")
        _graphs[tenant.id] = builder.compile(checkpointer=checkpointer)

    return _graphs[tenant.id]

async def run_agent(tenant, phone: str, messages: list[str]) -> str:
    graph  = await get_graph(tenant)
    config = RunnableConfig(configurable={"thread_id": f"{tenant.slug}:{phone}"})
    try:
        result = await graph.ainvoke(
            {"messages": [{"role": "user", "content": "\n".join(messages)}]},
            config=config
        )
        return result["messages"][-1].content
    except Exception as e:
        logger.error(f"Agente erro [{tenant.slug}:{phone}]: {e}")
        return "Desculpe, ocorreu um erro. Tente novamente em instantes. 🙏"
EOF
ok "Agente LangGraph criado"

# ════════════════════════════════════════
# routers
# ════════════════════════════════════════
cat > backend/app/routers/__init__.py << 'EOF'
EOF

cat > backend/app/routers/webhook.py << 'EOF'
import logging
from datetime import datetime
from fastapi import APIRouter, BackgroundTasks, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..database import get_db
from ..models import Tenant, Contact, Message
from ..services.debounce import debounce_manager
from ..services.evolution import send_message, send_typing
from ..agent.graph import run_agent

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/webhook", tags=["webhook"])

@router.post("/{tenant_slug}")
async def receive_message(tenant_slug: str, payload: dict,
                          bg: BackgroundTasks, db: AsyncSession = Depends(get_db)):
    data = payload.get("data", {})
    if data.get("key", {}).get("participant"):
        return {"status": "ignored"}
    if data.get("key", {}).get("fromMe"):
        return {"status": "ignored"}

    msg  = data.get("message", {})
    text = (msg.get("conversation") or msg.get("extendedTextMessage", {}).get("text") or "").strip()
    if not text:
        return {"status": "ignored"}

    phone = data["key"]["remoteJid"]
    result = await db.execute(select(Tenant).where(Tenant.slug == tenant_slug))
    tenant = result.scalar_one_or_none()
    if not tenant or not tenant.active or tenant.paused:
        return {"status": "ignored"}

    # Upsert contato
    rc = await db.execute(select(Contact).where(Contact.tenant_id == tenant.id, Contact.phone == phone))
    contact = rc.scalar_one_or_none()
    if not contact:
        contact = Contact(tenant_id=tenant.id, phone=phone)
        db.add(contact)
        await db.flush()
    contact.last_activity = datetime.utcnow()
    db.add(Message(tenant_id=tenant.id, contact_id=contact.id, phone=phone, role="user", content=text))
    await db.commit()

    bg.add_task(debounce_manager.schedule, tenant, phone, text, _process)
    return {"status": "queued"}

async def _process(tenant, phone: str, messages: list[str]):
    try:
        await send_typing(tenant, phone)
        reply = await run_agent(tenant, phone, messages)
        await send_message(tenant, phone, reply)
        async with __import__("app.database", fromlist=["AsyncSessionLocal"]).AsyncSessionLocal() as db:
            rc = await db.execute(
                __import__("sqlalchemy", fromlist=["select"]).select(Contact).where(
                    Contact.tenant_id == tenant.id, Contact.phone == phone))
            c = rc.scalar_one_or_none()
            db.add(Message(tenant_id=tenant.id, contact_id=c.id if c else None,
                           phone=phone, role="assistant", content=reply))
            await db.commit()
    except Exception as e:
        logger.error(f"Process error [{phone}]: {e}")
EOF

cat > backend/app/routers/tenants.py << 'EOF'
import logging, json
from fastapi import APIRouter, Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from pydantic import BaseModel
from typing import Optional
from ..database import get_db
from ..models import Tenant, Contact, Message
from ..config import settings
from ..services.evolution import check_instance, fetch_instances
from ..services.calendar import test_service_account

logger = logging.getLogger(__name__)
router = APIRouter(tags=["admin"])

def require_admin(x_admin_token: str = Header(None)):
    if settings.ADMIN_TOKEN and x_admin_token != settings.ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Token inválido")

# ── Pydantic schemas ──
class TenantCreate(BaseModel):
    slug: str
    nome: str
    evolution_url: str = "https://evolution.troovi.site"
    evolution_key: str
    evolution_instance: str
    openai_key: Optional[str] = None
    llm_model: str = "gpt-4o-mini"
    agent_name: str = "Assistente"
    agent_prompt: Optional[str] = None

class TenantUpdate(BaseModel):
    nome: Optional[str] = None
    agent_name: Optional[str] = None
    agent_prompt: Optional[str] = None
    llm_model: Optional[str] = None
    evolution_key: Optional[str] = None
    evolution_instance: Optional[str] = None
    evolution_url: Optional[str] = None
    openai_key: Optional[str] = None
    active: Optional[bool] = None
    paused: Optional[bool] = None
    calendar_id: Optional[str] = None
    google_sa_json: Optional[str] = None
    followup_1_msg: Optional[str] = None
    followup_2_msg: Optional[str] = None
    followup_1_hours: Optional[int] = None
    followup_2_hours: Optional[int] = None
    business_hours: Optional[dict] = None

class EvolutionTestRequest(BaseModel):
    evolution_url: str
    evolution_key: str
    instance: str

class CalendarTestRequest(BaseModel):
    google_sa_json: str
    calendar_id: str

# ── Rotas ──
@router.get("/tenants")
async def list_tenants(db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    result = await db.execute(select(Tenant).order_by(Tenant.created_at.desc()))
    out = []
    for t in result.scalars():
        msgs = (await db.execute(select(func.count()).where(Message.tenant_id == t.id))).scalar()
        cons = (await db.execute(select(func.count()).where(Contact.tenant_id == t.id))).scalar()
        out.append({
            "id": str(t.id), "slug": t.slug, "nome": t.nome,
            "active": t.active, "paused": t.paused, "plan": t.plan,
            "llm_model": t.llm_model, "agent_name": t.agent_name,
            "has_calendar": bool(t.google_sa_json and t.calendar_id),
            "created_at": str(t.created_at),
            "stats": {"messages": msgs, "contacts": cons},
            "webhook_url": f"{settings.BASE_URL}/webhook/{t.slug}"
        })
    return out

@router.post("/tenants")
async def create_tenant(data: TenantCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    ex = await db.execute(select(Tenant).where(Tenant.slug == data.slug))
    if ex.scalar_one_or_none():
        raise HTTPException(400, detail=f"Slug '{data.slug}' já existe")
    tenant = Tenant(**data.dict())
    db.add(tenant)
    await db.commit()
    await db.refresh(tenant)
    webhook_url = f"{settings.BASE_URL}/webhook/{tenant.slug}"
    return {
        "tenant": {"id": str(tenant.id), "slug": tenant.slug, "nome": tenant.nome},
        "webhook_url": webhook_url,
    }

@router.get("/tenants/{tenant_id}")
async def get_tenant(tenant_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    msgs = (await db.execute(select(func.count()).where(Message.tenant_id == t.id))).scalar()
    cons = (await db.execute(select(func.count()).where(Contact.tenant_id == t.id))).scalar()
    return {
        "id": str(t.id), "slug": t.slug, "nome": t.nome,
        "active": t.active, "paused": t.paused,
        "agent_name": t.agent_name, "agent_prompt": t.agent_prompt,
        "llm_model": t.llm_model,
        "evolution_url": t.evolution_url, "evolution_instance": t.evolution_instance,
        "calendar_id": t.calendar_id,
        "has_calendar": bool(t.google_sa_json and t.calendar_id),
        "has_sa_json": bool(t.google_sa_json),
        "followup_1_msg": t.followup_1_msg, "followup_2_msg": t.followup_2_msg,
        "followup_1_hours": t.followup_1_hours, "followup_2_hours": t.followup_2_hours,
        "business_hours": t.business_hours,
        "stats": {"messages": msgs, "contacts": cons},
        "webhook_url": f"{settings.BASE_URL}/webhook/{t.slug}",
    }

@router.put("/tenants/{tenant_id}")
async def update_tenant(tenant_id: str, data: TenantUpdate,
                        db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    for k, v in data.dict(exclude_none=True).items():
        setattr(t, k, v)
    await db.commit()
    return {"ok": True}

@router.post("/tenants/{tenant_id}/pause")
async def pause_tenant(tenant_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    t.paused = True; await db.commit()
    return {"ok": True}

@router.post("/tenants/{tenant_id}/resume")
async def resume_tenant(tenant_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    t.paused = False; await db.commit()
    return {"ok": True}

@router.delete("/tenants/{tenant_id}")
async def delete_tenant(tenant_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    await db.delete(t); await db.commit()
    return {"ok": True}

# ── Testes de conexão (usados no painel antes de salvar) ──
@router.post("/test/evolution")
async def test_evolution(data: EvolutionTestRequest, _=Depends(require_admin)):
    """Testa conexão com a Evolution API — chamado ao digitar os dados no cadastro."""
    result = await check_instance(data.evolution_url, data.evolution_key, data.instance)
    return result

@router.post("/test/evolution/instances")
async def list_evolution_instances(data: EvolutionTestRequest, _=Depends(require_admin)):
    """Lista instâncias disponíveis para autocomplete no cadastro."""
    instances = await fetch_instances(data.evolution_url, data.evolution_key)
    return {"instances": instances}

@router.post("/test/calendar")
async def test_calendar(data: CalendarTestRequest, _=Depends(require_admin)):
    """Testa Service Account + acesso ao calendário."""
    result = test_service_account(data.google_sa_json, data.calendar_id)
    return result

@router.get("/stats")
async def global_stats(db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    return {
        "tenants":        (await db.execute(select(func.count()).select_from(Tenant))).scalar(),
        "active_tenants": (await db.execute(select(func.count()).where(Tenant.active == True))).scalar(),
        "contacts":       (await db.execute(select(func.count()).select_from(Contact))).scalar(),
        "messages":       (await db.execute(select(func.count()).select_from(Message))).scalar(),
    }
EOF

cat > backend/app/routers/conversations.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..database import get_db
from ..models import Tenant, Contact, Message
from .tenants import require_admin

router = APIRouter(tags=["conversations"])

@router.get("/tenants/{tenant_id}/conversations")
async def list_conversations(tenant_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    result = await db.execute(
        select(Contact).where(Contact.tenant_id == t.id).order_by(Contact.last_activity.desc().nullslast())
    )
    out = []
    for c in result.scalars():
        last = (await db.execute(
            select(Message).where(Message.contact_id == c.id).order_by(Message.created_at.desc()).limit(1)
        )).scalar_one_or_none()
        out.append({
            "id": str(c.id), "phone": c.phone, "nome": c.nome,
            "last_activity": str(c.last_activity) if c.last_activity else None,
            "followup_1": c.followup_1_sent, "followup_2": c.followup_2_sent,
            "closed": c.conversation_closed,
            "last_message": last.content if last else None,
            "last_role": last.role if last else None,
        })
    return out

@router.get("/conversations/{contact_id}/messages")
async def get_messages(contact_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin)):
    result = await db.execute(
        select(Message).where(Message.contact_id == contact_id).order_by(Message.created_at)
    )
    return [{"id": str(m.id), "role": m.role, "content": m.content,
             "created_at": str(m.created_at)} for m in result.scalars()]
EOF

cat > backend/app/routers/docs.py << 'EOF'
import logging
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from sqlalchemy.ext.asyncio import AsyncSession
from ..database import get_db
from ..models import Tenant
from .tenants import require_admin
from ..config import settings

logger = logging.getLogger(__name__)
router = APIRouter(tags=["documents"])

@router.post("/tenants/{tenant_id}/documents")
async def upload_document(
    tenant_id: str, title: str = Form(...), file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db), _=Depends(require_admin)
):
    t = await db.get(Tenant, tenant_id)
    if not t: raise HTTPException(404)
    content = (await file.read()).decode("utf-8", errors="ignore")
    if not content.strip(): raise HTTPException(400, detail="Arquivo vazio")
    try:
        from langchain_postgres import PGVector
        from langchain_openai import OpenAIEmbeddings
        from langchain_core.documents import Document
        vs = PGVector(
            connection=settings.DATABASE_URL.replace("+asyncpg", ""),
            embeddings=OpenAIEmbeddings(model="text-embedding-3-small",
                                         api_key=t.openai_key or settings.OPENAI_API_KEY),
            collection_name=f"docs_{t.slug}",
        )
        chunks = [content[i:i+500] for i in range(0, len(content), 400)]
        docs   = [Document(page_content=c, metadata={"title": title, "tenant": t.slug})
                  for c in chunks if c.strip()]
        vs.add_documents(docs)
        return {"ok": True, "chunks": len(docs), "title": title}
    except Exception as e:
        raise HTTPException(500, detail=str(e))
EOF

cat > backend/app/main.py << 'EOF'
import logging
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from .database import init_db
from .services.scheduler import scheduler
from .routers import webhook, tenants, conversations, docs
from .config import settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    scheduler.start()
    yield
    scheduler.shutdown()

app = FastAPI(title="AgentOS", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware,
    allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

app.include_router(webhook.router)
app.include_router(tenants.router,       prefix="/admin")
app.include_router(conversations.router, prefix="/admin")
app.include_router(docs.router,          prefix="/admin")

@app.get("/health")
async def health():
    return {"status": "ok", "version": "1.0.0"}
EOF
ok "Backend completo"

step "Gerando frontend React"

cat > frontend/package.json << 'EOF'
{
  "name": "agentos-admin",
  "version": "1.0.0",
  "private": true,
  "scripts": { "dev": "vite", "build": "vite build" },
  "dependencies": { "react": "^18.3.1", "react-dom": "^18.3.1", "react-router-dom": "^6.26.2" },
  "devDependencies": { "@vitejs/plugin-react": "^4.3.2", "vite": "^5.4.8" }
}
EOF

cat > frontend/vite.config.js << 'EOF'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  plugins: [react()],
  server: { proxy: { "/admin": "http://localhost:8000", "/webhook": "http://localhost:8000" } },
});
EOF

cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>troovi · AgentOS</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@300;400;500;600;700;800;900&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet" />
</head>
<body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body>
</html>
EOF

cat > frontend/src/main.jsx << 'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";
ReactDOM.createRoot(document.getElementById("root")).render(<App />);
EOF

cat > frontend/src/index.css << 'EOF'
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Geist', system-ui, sans-serif; background: #f7f9fc; color: #0a0f1e; -webkit-font-smoothing: antialiased; }
a { text-decoration: none; color: inherit; }
:root {
  --blue: #1b6ef3; --blue-d: #1259d4; --blue-l: #eff5ff; --blue-m: #dbeafe;
  --off: #f7f9fc; --border: #e8edf5; --text: #0a0f1e; --muted: #5a6a85; --muted2: #8899b4;
  --green: #16a34a; --green-l: #dcfce7; --green-b: #bbf7d0;
  --red: #dc2626; --red-l: #fee2e2; --red-b: #fecaca;
  --amber: #b45309; --amber-l: #fef3c7; --amber-b: #fde68a;
  --purple: #7c3aed; --purple-l: #f5f3ff; --purple-b: #ddd6fe;
  --sh: 0 2px 12px rgba(10,15,40,.06), 0 1px 3px rgba(10,15,40,.04);
  --shm: 0 8px 32px rgba(10,15,40,.1), 0 2px 8px rgba(10,15,40,.06);
  --mono: 'Geist Mono', monospace;
}
::-webkit-scrollbar { width: 4px; } ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
EOF

cat > frontend/src/api.js << 'EOF'
const BASE  = import.meta.env.VITE_API_URL  || "";
const TOKEN = import.meta.env.VITE_ADMIN_TOKEN || "";
const h = () => ({ "Content-Type": "application/json", "x-admin-token": TOKEN });

export const api = {
  get:    (p)    => fetch(`${BASE}${p}`, { headers: h() }).then(r => r.json()),
  post:   (p, b) => fetch(`${BASE}${p}`, { method: "POST",   headers: h(), body: JSON.stringify(b) }).then(r => r.json()),
  put:    (p, b) => fetch(`${BASE}${p}`, { method: "PUT",    headers: h(), body: JSON.stringify(b) }).then(r => r.json()),
  delete: (p)    => fetch(`${BASE}${p}`, { method: "DELETE", headers: h() }).then(r => r.json()),
  upload: (p, fd) => fetch(`${BASE}${p}`, { method: "POST", headers: { "x-admin-token": TOKEN }, body: fd }).then(r => r.json()),
};
EOF

cat > frontend/src/App.jsx << 'EOF'
import React from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Clients from "./pages/Clients";
import ClientDetail from "./pages/ClientDetail";
import Conversations from "./pages/Conversations";
import NewClient from "./pages/NewClient";

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Layout />}>
          <Route index element={<Navigate to="/dashboard" replace />} />
          <Route path="dashboard"       element={<Dashboard />} />
          <Route path="clients"         element={<Clients />} />
          <Route path="clients/new"     element={<NewClient />} />
          <Route path="clients/:id"     element={<ClientDetail />} />
          <Route path="conversations"   element={<Conversations />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}
EOF

cat > frontend/src/components/Layout.jsx << 'EOF'
import React from "react";
import { Outlet, NavLink } from "react-router-dom";

const items = [
  { to: "/dashboard",   label: "Dashboard",  icon: "◈" },
  { to: "/clients",     label: "Clientes",   icon: "⊡" },
  { to: "/conversations",label:"Conversas",  icon: "⊟" },
];

export default function Layout() {
  return (
    <div style={{ display: "flex", minHeight: "100vh" }}>
      <aside style={{ width: 220, flexShrink: 0, background: "#fff", borderRight: "1px solid var(--border)", display: "flex", flexDirection: "column", position: "sticky", top: 0, height: "100vh", overflowY: "auto" }}>
        <div style={{ padding: "20px 18px 16px", borderBottom: "1px solid var(--border)" }}>
          <div style={{ fontSize: "1rem", fontWeight: 800, letterSpacing: "-.04em", display: "flex", alignItems: "center", gap: 5 }}>
            troovi <div style={{ width: 7, height: 7, borderRadius: "50%", background: "var(--blue)", animation: "pulse 2.5s infinite" }} />
          </div>
          <div style={{ fontSize: ".6rem", color: "var(--muted2)", fontFamily: "var(--mono)", letterSpacing: ".06em", textTransform: "uppercase", marginTop: 3 }}>AgentOS Admin</div>
        </div>
        <nav style={{ padding: "10px 0", flex: 1 }}>
          {items.map(({ to, label, icon }) => (
            <NavLink key={to} to={to} style={({ isActive }) => ({
              display: "flex", alignItems: "center", gap: 9, padding: "9px 18px",
              fontSize: ".78rem", fontWeight: isActive ? 700 : 500,
              color: isActive ? "var(--blue)" : "var(--muted)",
              background: isActive ? "var(--blue-l)" : "transparent",
              borderLeft: isActive ? "2px solid var(--blue)" : "2px solid transparent",
            })}>
              <span style={{ fontSize: "1rem" }}>{icon}</span>{label}
            </NavLink>
          ))}
        </nav>
        <NavLink to="/clients/new" style={{ margin: "0 12px 16px", display: "flex", alignItems: "center", justifyContent: "center", gap: 6, padding: "10px", borderRadius: 12, background: "var(--blue)", color: "#fff", fontSize: ".8rem", fontWeight: 700 }}>
          + Novo cliente
        </NavLink>
      </aside>
      <main style={{ flex: 1, padding: "28px 36px", maxWidth: 1100, minWidth: 0 }}>
        <Outlet />
      </main>
      <style>{`@keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.4);opacity:.7}}`}</style>
    </div>
  );
}
EOF

# ── Dashboard ─────────────────────────────────────────────
cat > frontend/src/pages/Dashboard.jsx << 'EOF'
import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../api";

const card = { background: "#fff", border: "1.5px solid var(--border)", borderRadius: 16, padding: "20px 22px", boxShadow: "var(--sh)" };

export default function Dashboard() {
  const [stats, setStats]     = useState(null);
  const [tenants, setTenants] = useState([]);

  useEffect(() => {
    api.get("/admin/stats").then(setStats);
    api.get("/admin/tenants").then(setTenants);
  }, []);

  return (
    <div>
      <div style={{ marginBottom: 28 }}>
        <h1 style={{ fontSize: "1.6rem", fontWeight: 900, letterSpacing: "-.04em" }}>Dashboard</h1>
        <p style={{ color: "var(--muted)", fontSize: ".85rem", marginTop: 4 }}>Visão geral da plataforma</p>
      </div>

      {stats && (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 14, marginBottom: 32 }}>
          {[
            { label: "Clientes ativos",  val: stats.active_tenants },
            { label: "Total clientes",   val: stats.tenants },
            { label: "Contatos",         val: stats.contacts },
            { label: "Mensagens",        val: stats.messages },
          ].map(({ label, val }) => (
            <div key={label} style={card}>
              <div style={{ fontSize: ".63rem", fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--muted2)", marginBottom: 8 }}>{label}</div>
              <div style={{ fontSize: "2.2rem", fontWeight: 900, letterSpacing: "-.05em" }}>{(val || 0).toLocaleString()}</div>
            </div>
          ))}
        </div>
      )}

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 14 }}>
        <h2 style={{ fontSize: "1rem", fontWeight: 800 }}>Clientes</h2>
        <Link to="/clients/new" style={{ background: "var(--blue)", color: "#fff", padding: "8px 18px", borderRadius: 100, fontSize: ".8rem", fontWeight: 700 }}>+ Novo</Link>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {tenants.map(t => (
          <Link key={t.id} to={`/clients/${t.id}`} style={{ ...card, display: "flex", alignItems: "center", gap: 14 }}>
            <div style={{ width: 38, height: 38, borderRadius: "50%", background: "var(--blue-l)", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 900, color: "var(--blue)", flexShrink: 0 }}>
              {t.nome[0]}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontWeight: 700, fontSize: ".88rem" }}>{t.nome}</div>
              <div style={{ fontSize: ".7rem", color: "var(--muted)", fontFamily: "var(--mono)", marginTop: 1 }}>{t.slug} · {t.llm_model}</div>
            </div>
            <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
              {t.has_calendar && <span title="Calendar configurado" style={{ fontSize: ".75rem" }}>📅</span>}
              <span style={{ background: t.paused ? "var(--amber-l)" : "var(--green-l)", color: t.paused ? "var(--amber)" : "var(--green)", padding: "3px 10px", borderRadius: 100, fontSize: ".68rem", fontWeight: 700 }}>
                {t.paused ? "Pausado" : "Ativo"}
              </span>
            </div>
            <div style={{ textAlign: "right", fontSize: ".72rem", color: "var(--muted2)", flexShrink: 0 }}>
              <div>{t.stats?.messages?.toLocaleString()} msgs</div>
              <div>{t.stats?.contacts} contatos</div>
            </div>
          </Link>
        ))}
        {tenants.length === 0 && (
          <div style={{ ...card, background: "var(--blue-l)", border: "1.5px solid var(--blue-m)", textAlign: "center", padding: 48 }}>
            <div style={{ fontSize: "2rem", marginBottom: 12 }}>🚀</div>
            <div style={{ fontWeight: 700, marginBottom: 8 }}>Nenhum cliente ainda</div>
            <Link to="/clients/new" style={{ color: "var(--blue)", fontWeight: 700 }}>Cadastrar primeiro cliente →</Link>
          </div>
        )}
      </div>
    </div>
  );
}
EOF

# ── NewClient — wizard completo com teste de Evolution ────
cat > frontend/src/pages/NewClient.jsx << 'EOF'
import React, { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../api";

const inp  = { width:"100%", padding:"10px 14px", border:"1.5px solid var(--border)", borderRadius:10, fontSize:".85rem", fontFamily:"'Geist',sans-serif", outline:"none", background:"#fff", color:"var(--text)", transition:"border-color .15s" };
const lbl  = { fontSize:".72rem", fontWeight:700, color:"var(--muted)", marginBottom:5, display:"block" };
const grp  = { marginBottom:16 };
const card = { background:"#fff", border:"1.5px solid var(--border)", borderRadius:16, padding:24, marginBottom:14, boxShadow:"var(--sh)" };
const st   = { fontSize:".68rem", fontWeight:700, letterSpacing:".08em", textTransform:"uppercase", color:"var(--muted2)", marginBottom:16, fontFamily:"var(--mono)" };
const hint = { fontSize:".7rem", color:"var(--muted2)", marginTop:5 };

const STEPS = ["Empresa", "WhatsApp", "Agente", "Pronto"];

export default function NewClient() {
  const nav = useNavigate();
  const [step, setStep]   = useState(0);
  const [loading, setLoading]   = useState(false);
  const [error, setError]       = useState("");
  const [result, setResult]     = useState(null);

  // Evolution test state
  const [testEvolution, setTestEvolution] = useState(null); // null | {ok,state}
  const [testingEvolution, setTestingEvolution] = useState(false);
  const [instances, setInstances] = useState([]);
  const [loadingInstances, setLoadingInstances] = useState(false);

  const [form, setForm] = useState({
    nome: "", slug: "",
    evolution_url: "https://evolution.troovi.site",
    evolution_key: "", evolution_instance: "",
    agent_name: "Assistente", llm_model: "gpt-4o-mini",
    agent_prompt: "",
  });

  const set = (k) => (e) => {
    let v = e.target.value;
    if (k === "slug") v = v.toLowerCase().replace(/[^a-z0-9-]/g, "-");
    // auto-slug from nome
    if (k === "nome" && !form.slug) {
      const auto = v.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"");
      setForm(f => ({ ...f, nome: v, slug: auto }));
      return;
    }
    setForm(f => ({ ...f, [k]: v }));
    if (k === "evolution_key" || k === "evolution_url") {
      setTestEvolution(null); setInstances([]);
    }
  };

  const handleTestEvolution = async () => {
    if (!form.evolution_key || !form.evolution_instance) return;
    setTestingEvolution(true); setTestEvolution(null);
    const r = await api.post("/admin/test/evolution", {
      evolution_url: form.evolution_url,
      evolution_key: form.evolution_key,
      instance: form.evolution_instance,
    });
    setTestEvolution(r);
    setTestingEvolution(false);
  };

  const handleLoadInstances = async () => {
    if (!form.evolution_key) return;
    setLoadingInstances(true);
    const r = await api.post("/admin/test/evolution/instances", {
      evolution_url: form.evolution_url,
      evolution_key: form.evolution_key,
      instance: "_",
    });
    setInstances(r.instances || []);
    setLoadingInstances(false);
  };

  const canNext = () => {
    if (step === 0) return form.nome && form.slug;
    if (step === 1) return form.evolution_key && form.evolution_instance;
    if (step === 2) return form.agent_name;
    return true;
  };

  const handleSubmit = async () => {
    setLoading(true); setError("");
    try {
      const data = await api.post("/admin/tenants", form);
      if (data.webhook_url) setResult(data);
      else setError(data.detail || "Erro ao criar cliente");
    } catch { setError("Erro de conexão"); }
    finally { setLoading(false); }
  };

  if (result) return (
    <div style={{ maxWidth: 600 }}>
      <div style={{ ...card, background:"var(--green-l)", border:"1.5px solid var(--green-b)", textAlign:"center", padding:32 }}>
        <div style={{ fontSize:"2.5rem", marginBottom:12 }}>✅</div>
        <h2 style={{ fontSize:"1.2rem", fontWeight:900, marginBottom:8 }}>{result.tenant.nome} criado!</h2>
        <p style={{ color:"var(--muted)", marginBottom:20, fontSize:".85rem" }}>Cole este webhook na Evolution API da instância <strong>{form.evolution_instance}</strong>:</p>
        <div style={{ background:"#fff", border:"1px solid var(--border)", borderRadius:10, padding:"12px 16px", fontFamily:"var(--mono)", fontSize:".78rem", color:"var(--blue)", wordBreak:"break-all", marginBottom:20 }}>
          {result.webhook_url}
        </div>
        <div style={{ background:"var(--blue-l)", border:"1px solid var(--blue-m)", borderRadius:10, padding:"12px 16px", fontSize:".8rem", color:"var(--muted)", marginBottom:20, textAlign:"left" }}>
          <strong style={{ color:"var(--text)" }}>Próximos passos opcionais:</strong>
          <ul style={{ marginTop:6, paddingLeft:18 }}>
            <li>Ir em <strong>Configurar</strong> para adicionar Google Calendar (Service Account)</li>
            <li>Fazer upload de documentos para a base de conhecimento (RAG)</li>
            <li>Personalizar as mensagens de follow-up</li>
          </ul>
        </div>
        <div style={{ display:"flex", gap:10, justifyContent:"center", flexWrap:"wrap" }}>
          <button onClick={() => navigator.clipboard.writeText(result.webhook_url)}
            style={{ background:"var(--blue)", color:"#fff", padding:"10px 20px", borderRadius:10, border:"none", fontWeight:700, cursor:"pointer", fontFamily:"'Geist',sans-serif" }}>
            Copiar webhook
          </button>
          <button onClick={() => nav(`/clients/${result.tenant.id}`)}
            style={{ background:"#fff", border:"1.5px solid var(--border)", padding:"10px 20px", borderRadius:10, fontWeight:700, cursor:"pointer", fontFamily:"'Geist',sans-serif" }}>
            Configurar cliente →
          </button>
        </div>
      </div>
    </div>
  );

  return (
    <div style={{ maxWidth: 600 }}>
      {/* Progress */}
      <div style={{ marginBottom:28 }}>
        <h1 style={{ fontSize:"1.5rem", fontWeight:900, letterSpacing:"-.04em" }}>Novo cliente</h1>
        <div style={{ display:"flex", gap:0, marginTop:16 }}>
          {STEPS.map((s,i) => (
            <React.Fragment key={s}>
              <div style={{ display:"flex", flexDirection:"column", alignItems:"center" }}>
                <div style={{ width:28, height:28, borderRadius:"50%", display:"flex", alignItems:"center", justifyContent:"center", fontSize:".72rem", fontWeight:800, background: i < step ? "var(--green)" : i === step ? "var(--blue)" : "var(--border)", color: i <= step ? "#fff" : "var(--muted)" }}>
                  {i < step ? "✓" : i + 1}
                </div>
                <div style={{ fontSize:".65rem", fontWeight: i === step ? 700 : 500, color: i === step ? "var(--blue)" : "var(--muted)", marginTop:4, whiteSpace:"nowrap" }}>{s}</div>
              </div>
              {i < STEPS.length-1 && <div style={{ flex:1, height:2, background: i < step ? "var(--green)" : "var(--border)", marginTop:13, marginInline:4 }} />}
            </React.Fragment>
          ))}
        </div>
      </div>

      {error && <div style={{ background:"var(--red-l)", border:"1px solid var(--red-b)", color:"var(--red)", padding:"12px 16px", borderRadius:10, marginBottom:16, fontSize:".85rem" }}>{error}</div>}

      {/* Step 0 — Empresa */}
      {step === 0 && (
        <div style={card}>
          <div style={st}>// Dados da empresa</div>
          <div style={grp}>
            <label style={lbl}>Nome da empresa *</label>
            <input style={inp} value={form.nome} onChange={set("nome")} placeholder="Espaço Lorenna" autoFocus />
          </div>
          <div style={grp}>
            <label style={lbl}>Slug (identificador único) *</label>
            <input style={inp} value={form.slug} onChange={set("slug")} placeholder="espaco-lorenna" />
            <div style={hint}>Gerado automaticamente. Só letras minúsculas e hífens.</div>
          </div>
        </div>
      )}

      {/* Step 1 — Evolution */}
      {step === 1 && (
        <div style={card}>
          <div style={st}>// Conexão WhatsApp (Evolution API)</div>
          <div style={grp}>
            <label style={lbl}>URL da Evolution *</label>
            <input style={inp} value={form.evolution_url} onChange={set("evolution_url")} />
          </div>
          <div style={grp}>
            <label style={lbl}>API Key *</label>
            <input style={inp} value={form.evolution_key} onChange={set("evolution_key")} placeholder="5a44ee895c..." type="password" />
          </div>
          <div style={grp}>
            <label style={lbl}>Nome da instância *</label>
            <div style={{ display:"flex", gap:8 }}>
              <input style={{ ...inp, flex:1 }} value={form.evolution_instance} onChange={set("evolution_instance")} placeholder="nome-da-instancia"
                list="instances-list" />
              <datalist id="instances-list">
                {instances.map(i => <option key={i.name} value={i.name}>{i.name} ({i.state})</option>)}
              </datalist>
              <button type="button" onClick={handleLoadInstances} disabled={!form.evolution_key || loadingInstances}
                style={{ padding:"10px 14px", borderRadius:10, border:"1.5px solid var(--border)", background:"var(--off)", fontWeight:600, cursor:"pointer", fontSize:".78rem", fontFamily:"'Geist',sans-serif", whiteSpace:"nowrap", flexShrink:0 }}>
                {loadingInstances ? "..." : "Buscar"}
              </button>
            </div>
            <div style={hint}>Clique em "Buscar" para ver as instâncias disponíveis na sua Evolution.</div>
          </div>
          {/* Teste de conexão */}
          <div style={{ marginTop:8 }}>
            <button type="button" onClick={handleTestEvolution} disabled={!form.evolution_key || !form.evolution_instance || testingEvolution}
              style={{ padding:"9px 18px", borderRadius:10, border:"1.5px solid var(--blue-m)", background:"var(--blue-l)", color:"var(--blue)", fontWeight:700, cursor:"pointer", fontSize:".8rem", fontFamily:"'Geist',sans-serif" }}>
              {testingEvolution ? "Testando..." : "🔌 Testar conexão"}
            </button>
            {testEvolution && (
              <div style={{ marginTop:10, padding:"10px 14px", borderRadius:10, background: testEvolution.ok ? "var(--green-l)" : "var(--red-l)", border:`1px solid ${testEvolution.ok ? "var(--green-b)" : "var(--red-b)"}`, fontSize:".8rem", color: testEvolution.ok ? "var(--green)" : "var(--red)", fontWeight:700 }}>
                {testEvolution.ok
                  ? `✅ Conectado! Instância "${form.evolution_instance}" está online (${testEvolution.state})`
                  : `❌ ${testEvolution.error || `Estado: ${testEvolution.state}`}`}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Step 2 — Agente */}
      {step === 2 && (
        <div style={card}>
          <div style={st}>// Configuração do agente</div>
          <div style={grp}>
            <label style={lbl}>Nome do agente</label>
            <input style={inp} value={form.agent_name} onChange={set("agent_name")} placeholder="Assistente" />
            <div style={hint}>Como o agente vai se apresentar. Ex: "Lari", "Bia", "Assistente Studio V"</div>
          </div>
          <div style={grp}>
            <label style={lbl}>Modelo LLM</label>
            <select style={inp} value={form.llm_model} onChange={set("llm_model")}>
              <option value="gpt-4o-mini">GPT-4o Mini — rápido e barato (recomendado)</option>
              <option value="gpt-4o">GPT-4o — mais inteligente</option>
              <option value="gpt-4-turbo">GPT-4 Turbo</option>
            </select>
          </div>
          <div style={grp}>
            <label style={lbl}>Prompt do agente</label>
            <textarea style={{ ...inp, minHeight:140, resize:"vertical" }}
              value={form.agent_prompt} onChange={set("agent_prompt")}
              placeholder={`Você é ${form.agent_name || "Assistente"}, atendente virtual da ${form.nome || "empresa"}.\n\nAtenda clientes que buscam [seus serviços].\nSeja simpático, objetivo e profissional.\nHorário de funcionamento: seg-sex 8h-18h.`} />
            <div style={hint}>Deixe vazio para usar o padrão. Pode editar depois com calma.</div>
          </div>
        </div>
      )}

      {/* Navegação */}
      <div style={{ display:"flex", gap:10, justifyContent:"space-between" }}>
        <button onClick={() => setStep(s => s-1)} disabled={step === 0}
          style={{ padding:"12px 24px", borderRadius:10, border:"1.5px solid var(--border)", background:"#fff", fontWeight:700, cursor: step===0?"not-allowed":"pointer", opacity: step===0?0.4:1, fontSize:".85rem", fontFamily:"'Geist',sans-serif" }}>
          ← Voltar
        </button>
        {step < 2
          ? <button onClick={() => { if(canNext()) setStep(s=>s+1); }} disabled={!canNext()}
              style={{ padding:"12px 28px", borderRadius:10, border:"none", background: canNext()?"var(--blue)":"var(--muted2)", color:"#fff", fontWeight:700, cursor: canNext()?"pointer":"not-allowed", fontSize:".85rem", fontFamily:"'Geist',sans-serif" }}>
              Continuar →
            </button>
          : <button onClick={handleSubmit} disabled={loading}
              style={{ padding:"12px 28px", borderRadius:10, border:"none", background: loading?"var(--muted2)":"var(--blue)", color:"#fff", fontWeight:700, cursor: loading?"wait":"pointer", fontSize:".85rem", fontFamily:"'Geist',sans-serif" }}>
              {loading ? "Criando..." : "Criar cliente →"}
            </button>
        }
      </div>
    </div>
  );
}
EOF

# ── ClientDetail — tudo editável, Calendar SA, follow-up ──
cat > frontend/src/pages/ClientDetail.jsx << 'EOF'
import React, { useEffect, useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { api } from "../api";

const inp  = { width:"100%", padding:"10px 14px", border:"1.5px solid var(--border)", borderRadius:10, fontSize:".85rem", fontFamily:"'Geist',sans-serif", outline:"none", background:"#fff", color:"var(--text)" };
const lbl  = { fontSize:".72rem", fontWeight:700, color:"var(--muted)", marginBottom:5, display:"block" };
const grp  = { marginBottom:14 };
const sec  = { background:"#fff", border:"1.5px solid var(--border)", borderRadius:16, padding:22, marginBottom:14, boxShadow:"var(--sh)" };
const stit = { fontSize:".68rem", fontWeight:700, letterSpacing:".08em", textTransform:"uppercase", color:"var(--muted2)", marginBottom:14, fontFamily:"var(--mono)", display:"flex", alignItems:"center", justifyContent:"space-between" };
const hint = { fontSize:".7rem", color:"var(--muted2)", marginTop:5 };

function SaveBtn({ label="Salvar", loading, saved, onClick }) {
  return (
    <button onClick={onClick} disabled={loading}
      style={{ padding:"9px 20px", borderRadius:10, border:"none", background: saved?"var(--green)":loading?"var(--muted2)":"var(--blue)", color:"#fff", fontWeight:700, cursor: loading?"wait":"pointer", fontSize:".82rem", fontFamily:"'Geist',sans-serif", transition:"background .2s" }}>
      {saved ? "✓ Salvo!" : loading ? "Salvando..." : label}
    </button>
  );
}

function Section({ title, badge, children }) {
  const [open, setOpen] = useState(true);
  return (
    <div style={sec}>
      <div style={{ ...stit, cursor:"pointer" }} onClick={() => setOpen(o=>!o)}>
        <span>{title} {badge && <span style={{ background:"var(--green-l)", color:"var(--green)", padding:"2px 8px", borderRadius:100, fontSize:".65rem", fontWeight:700, marginLeft:6, fontFamily:"var(--mono)" }}>{badge}</span>}</span>
        <span style={{ fontSize:".8rem", color:"var(--muted2)" }}>{open?"▲":"▼"}</span>
      </div>
      {open && children}
    </div>
  );
}

export default function ClientDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const [t, setT] = useState(null);

  // Agente
  const [agente, setAgente] = useState({});
  const [savedAgente, setSavedAgente] = useState(false);

  // Calendar SA
  const [calSaJson, setCalSaJson]   = useState("");
  const [calId, setCalId]           = useState("");
  const [calTest, setCalTest]       = useState(null);
  const [testingCal, setTestingCal] = useState(false);
  const [savedCal, setSavedCal]     = useState(false);
  const [savingCal, setSavingCal]   = useState(false);

  // Follow-up
  const [fu, setFu]         = useState({});
  const [savedFu, setSavedFu] = useState(false);

  // Docs
  const [docFile, setDocFile]   = useState(null);
  const [docTitle, setDocTitle] = useState("");
  const [docMsg, setDocMsg]     = useState("");
  const [docLoading, setDocLoading] = useState(false);

  // Evolução (webhook)
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    api.get(`/admin/tenants/${id}`).then(d => {
      setT(d);
      setAgente({ agent_name: d.agent_name, agent_prompt: d.agent_prompt||"", llm_model: d.llm_model });
      setCalId(d.calendar_id||"");
      setFu({ followup_1_msg: d.followup_1_msg||"", followup_2_msg: d.followup_2_msg||"",
               followup_1_hours: d.followup_1_hours||24, followup_2_hours: d.followup_2_hours||48 });
    });
  }, [id]);

  const saveAgente = async () => {
    await api.put(`/admin/tenants/${id}`, agente);
    setSavedAgente(true); setTimeout(()=>setSavedAgente(false),2000);
  };

  const testCalendar = async () => {
    if (!calSaJson || !calId) return;
    setTestingCal(true); setCalTest(null);
    const r = await api.post("/admin/test/calendar", { google_sa_json: calSaJson, calendar_id: calId });
    setCalTest(r);
    setTestingCal(false);
  };

  const saveCalendar = async () => {
    setSavingCal(true);
    await api.put(`/admin/tenants/${id}`, { google_sa_json: calSaJson||undefined, calendar_id: calId||undefined });
    setT(tt => ({ ...tt, has_calendar: !!(calSaJson && calId), calendar_id: calId }));
    setSavedCal(true); setTimeout(()=>setSavedCal(false),2500);
    setSavingCal(false);
  };

  const saveFu = async () => {
    await api.put(`/admin/tenants/${id}`, fu);
    setSavedFu(true); setTimeout(()=>setSavedFu(false),2000);
  };

  const togglePause = async () => {
    await api.post(`/admin/tenants/${id}/${t.paused?"resume":"pause"}`, {});
    setT(tt => ({ ...tt, paused: !tt.paused }));
  };

  const uploadDoc = async (e) => {
    e.preventDefault();
    if (!docFile || !docTitle) return;
    setDocLoading(true); setDocMsg("");
    const fd = new FormData();
    fd.append("title", docTitle); fd.append("file", docFile);
    const r = await api.upload(`/admin/tenants/${id}/documents`, fd);
    setDocMsg(r.ok ? `✅ ${r.chunks} chunks adicionados ao índice` : `❌ ${r.detail||"Erro"}`);
    setDocLoading(false); setDocFile(null); setDocTitle("");
  };

  const copyWebhook = () => {
    navigator.clipboard.writeText(t.webhook_url);
    setCopied(true); setTimeout(()=>setCopied(false),2000);
  };

  if (!t) return <div style={{ color:"var(--muted)", padding:40, textAlign:"center" }}>Carregando...</div>;

  return (
    <div style={{ maxWidth: 660 }}>
      {/* Header */}
      <div style={{ display:"flex", alignItems:"center", gap:12, marginBottom:22 }}>
        <button onClick={() => nav(-1)} style={{ border:"1.5px solid var(--border)", background:"#fff", borderRadius:8, padding:"6px 12px", cursor:"pointer", fontSize:".82rem" }}>←</button>
        <div style={{ flex:1 }}>
          <h1 style={{ fontSize:"1.4rem", fontWeight:900, letterSpacing:"-.04em" }}>{t.nome}</h1>
          <div style={{ fontSize:".7rem", color:"var(--muted)", fontFamily:"var(--mono)", marginTop:2 }}>
            {t.slug} · {t.stats?.messages?.toLocaleString()} msgs · {t.stats?.contacts} contatos
          </div>
        </div>
        <button onClick={togglePause} style={{ padding:"8px 16px", borderRadius:100, border:"1.5px solid var(--border)", background: t.paused?"var(--green-l)":"var(--amber-l)", color: t.paused?"var(--green)":"var(--amber)", fontWeight:700, cursor:"pointer", fontSize:".78rem", fontFamily:"'Geist',sans-serif" }}>
          {t.paused ? "▶ Retomar IA" : "⏸ Pausar IA"}
        </button>
      </div>

      {/* Webhook */}
      <Section title="// Webhook URL">
        <div style={{ display:"flex", gap:8, marginBottom:8 }}>
          <div style={{ flex:1, padding:"10px 14px", background:"var(--blue-l)", border:"1px solid var(--blue-m)", borderRadius:10, fontFamily:"var(--mono)", fontSize:".76rem", color:"var(--blue)", wordBreak:"break-all" }}>
            {t.webhook_url}
          </div>
          <button onClick={copyWebhook} style={{ padding:"10px 16px", borderRadius:10, border:"1.5px solid var(--blue-m)", background: copied?"var(--green-l)":"var(--blue-l)", color: copied?"var(--green)":"var(--blue)", fontWeight:700, cursor:"pointer", fontSize:".78rem", flexShrink:0, fontFamily:"'Geist',sans-serif", transition:"all .2s" }}>
            {copied ? "✓ Copiado!" : "Copiar"}
          </button>
        </div>
        <div style={{ fontSize:".72rem", color:"var(--muted2)" }}>Configure este webhook na Evolution API · instância: <strong style={{ fontFamily:"var(--mono)" }}>{t.evolution_instance}</strong></div>
      </Section>

      {/* Agente */}
      <Section title="// Agente IA">
        <div style={grp}>
          <label style={lbl}>Nome do agente</label>
          <input style={inp} value={agente.agent_name||""} onChange={e => setAgente(a=>({...a,agent_name:e.target.value}))} />
        </div>
        <div style={grp}>
          <label style={lbl}>Modelo LLM</label>
          <select style={inp} value={agente.llm_model||"gpt-4o-mini"} onChange={e => setAgente(a=>({...a,llm_model:e.target.value}))}>
            <option value="gpt-4o-mini">GPT-4o Mini — rápido e barato</option>
            <option value="gpt-4o">GPT-4o — mais inteligente</option>
            <option value="gpt-4-turbo">GPT-4 Turbo</option>
          </select>
        </div>
        <div style={grp}>
          <label style={lbl}>Prompt do agente</label>
          <textarea style={{ ...inp, minHeight:160, resize:"vertical" }}
            value={agente.agent_prompt||""} onChange={e => setAgente(a=>({...a,agent_prompt:e.target.value}))}
            placeholder="Você é [nome], atendente da [empresa]..." />
          <div style={hint}>Editável a qualquer momento. Mudanças entram em vigor na próxima mensagem.</div>
        </div>
        <SaveBtn label="Salvar agente" saved={savedAgente} onClick={saveAgente} />
      </Section>

      {/* Google Calendar — Service Account */}
      <Section title="// Google Calendar" badge={t.has_calendar ? "configurado ✓" : undefined}>
        <div style={{ background:"var(--blue-l)", border:"1px solid var(--blue-m)", borderRadius:10, padding:"12px 14px", marginBottom:14, fontSize:".8rem", color:"var(--muted)" }}>
          <strong style={{ color:"var(--text)", display:"block", marginBottom:4 }}>Como configurar (sem OAuth, funciona para sempre):</strong>
          1. Acesse <a href="https://console.cloud.google.com" target="_blank" rel="noreferrer" style={{ color:"var(--blue)" }}>console.cloud.google.com</a> → APIs & Services → Credentials<br/>
          2. Crie um <strong>Service Account</strong> e baixe o JSON<br/>
          3. No Google Calendar, compartilhe o calendário do cliente com o <strong>email do service account</strong> (permissão: Fazer alterações)<br/>
          4. Cole o JSON e o ID do calendário abaixo
        </div>
        <div style={grp}>
          <label style={lbl}>Service Account JSON</label>
          <textarea style={{ ...inp, minHeight:100, resize:"vertical", fontFamily:"var(--mono)", fontSize:".72rem" }}
            value={calSaJson} onChange={e => { setCalSaJson(e.target.value); setCalTest(null); }}
            placeholder={'{\n  "type": "service_account",\n  "project_id": "...",\n  ...\n}'} />
          {t.has_sa_json && !calSaJson && <div style={{ ...hint, color:"var(--green)" }}>✓ Service account já configurado. Cole novamente para substituir.</div>}
        </div>
        <div style={grp}>
          <label style={lbl}>Calendar ID (email do calendário)</label>
          <input style={inp} value={calId} onChange={e => { setCalId(e.target.value); setCalTest(null); }}
            placeholder="cliente@gmail.com ou id@group.calendar.google.com" />
          <div style={hint}>Encontre em: Google Calendar → Configurações do calendário → "Endereço do calendário em formato iCal"</div>
        </div>
        <div style={{ display:"flex", gap:10, alignItems:"center", flexWrap:"wrap" }}>
          <button onClick={testCalendar} disabled={(!calSaJson && !t.has_sa_json) || !calId || testingCal}
            style={{ padding:"9px 18px", borderRadius:10, border:"1.5px solid var(--blue-m)", background:"var(--blue-l)", color:"var(--blue)", fontWeight:700, cursor:"pointer", fontSize:".8rem", fontFamily:"'Geist',sans-serif" }}>
            {testingCal ? "Testando..." : "🔌 Testar acesso"}
          </button>
          <SaveBtn label="Salvar Calendar" saved={savedCal} loading={savingCal} onClick={saveCalendar} />
        </div>
        {calTest && (
          <div style={{ marginTop:12, padding:"10px 14px", borderRadius:10, background: calTest.ok?"var(--green-l)":"var(--red-l)", border:`1px solid ${calTest.ok?"var(--green-b)":"var(--red-b)"}`, fontSize:".8rem", color: calTest.ok?"var(--green)":"var(--red)", fontWeight:700 }}>
            {calTest.ok
              ? `✅ Acesso confirmado! Calendário: "${calTest.calendar_name}" (${calTest.timezone})`
              : `❌ ${calTest.error}`}
          </div>
        )}
      </Section>

      {/* Follow-up */}
      <Section title="// Mensagens de Follow-up">
        <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:12, marginBottom:14 }}>
          <div>
            <label style={lbl}>Horas para follow-up 1</label>
            <input style={inp} type="number" value={fu.followup_1_hours||24} min={1} max={168}
              onChange={e => setFu(f=>({...f,followup_1_hours:parseInt(e.target.value)}))} />
          </div>
          <div>
            <label style={lbl}>Horas para follow-up 2</label>
            <input style={inp} type="number" value={fu.followup_2_hours||48} min={1} max={336}
              onChange={e => setFu(f=>({...f,followup_2_hours:parseInt(e.target.value)}))} />
          </div>
        </div>
        <div style={grp}>
          <label style={lbl}>Mensagem follow-up 1 (após {fu.followup_1_hours}h sem resposta)</label>
          <textarea style={{ ...inp, minHeight:80, resize:"vertical" }}
            value={fu.followup_1_msg||""} onChange={e => setFu(f=>({...f,followup_1_msg:e.target.value}))}
            placeholder={`Oi! Aqui é [Agente] da [Empresa] 😊 Ficou alguma dúvida? Estou por aqui!`} />
        </div>
        <div style={grp}>
          <label style={lbl}>Mensagem follow-up 2 (após {fu.followup_2_hours}h sem resposta)</label>
          <textarea style={{ ...inp, minHeight:80, resize:"vertical" }}
            value={fu.followup_2_msg||""} onChange={e => setFu(f=>({...f,followup_2_msg:e.target.value}))}
            placeholder="Última mensagem! Se precisar estou à disposição 🌟" />
        </div>
        <SaveBtn label="Salvar follow-up" saved={savedFu} onClick={saveFu} />
      </Section>

      {/* RAG — Upload de documentos */}
      <Section title="// Base de Conhecimento (RAG)">
        <p style={{ fontSize:".82rem", color:"var(--muted)", marginBottom:14 }}>
          Faça upload de arquivos .txt ou .pdf com informações sobre serviços, preços, horários e FAQ.
          O agente consultará estes documentos automaticamente ao responder.
        </p>
        <form onSubmit={uploadDoc}>
          <div style={grp}>
            <label style={lbl}>Título do documento</label>
            <input style={inp} value={docTitle} onChange={e=>setDocTitle(e.target.value)} placeholder="Ex: Tabela de preços, FAQ, Serviços disponíveis..." required />
          </div>
          <div style={grp}>
            <label style={lbl}>Arquivo (.txt ou .pdf)</label>
            <input type="file" accept=".txt,.pdf" onChange={e=>setDocFile(e.target.files[0])} required style={{ fontSize:".82rem", color:"var(--muted)" }} />
          </div>
          {docMsg && <div style={{ marginBottom:12, fontSize:".8rem", color: docMsg.startsWith("✅")?"var(--green)":"var(--red)", fontWeight:600 }}>{docMsg}</div>}
          <button type="submit" disabled={docLoading}
            style={{ padding:"10px 20px", borderRadius:10, border:"none", background: docLoading?"var(--muted2)":"var(--text)", color:"#fff", fontWeight:700, cursor: docLoading?"wait":"pointer", fontSize:".82rem", fontFamily:"'Geist',sans-serif" }}>
            {docLoading ? "Processando e vetorizando..." : "Upload e indexar →"}
          </button>
        </form>
      </Section>
    </div>
  );
}
EOF

# ── Clients.jsx ───────────────────────────────────────────
cat > frontend/src/pages/Clients.jsx << 'EOF'
import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../api";

export default function Clients() {
  const [tenants, setTenants] = useState([]);
  const [loading, setLoading] = useState(true);

  const reload = () => {
    setLoading(true);
    api.get("/admin/tenants").then(d => { setTenants(d); setLoading(false); });
  };
  useEffect(reload, []);

  const togglePause = async (e, t) => {
    e.preventDefault();
    await api.post(`/admin/tenants/${t.id}/${t.paused?"resume":"pause"}`, {});
    reload();
  };

  if (loading) return <div style={{ color:"var(--muted)", padding:40, textAlign:"center" }}>Carregando...</div>;

  return (
    <div>
      <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:24 }}>
        <div>
          <h1 style={{ fontSize:"1.5rem", fontWeight:900, letterSpacing:"-.04em" }}>Clientes</h1>
          <p style={{ color:"var(--muted)", fontSize:".85rem", marginTop:4 }}>{tenants.length} cliente{tenants.length!==1?"s":""}</p>
        </div>
        <Link to="/clients/new" style={{ background:"var(--blue)", color:"#fff", padding:"10px 20px", borderRadius:100, fontSize:".82rem", fontWeight:700 }}>
          + Novo cliente
        </Link>
      </div>

      <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
        {tenants.map(t => (
          <Link key={t.id} to={`/clients/${t.id}`} style={{ background:"#fff", border:"1.5px solid var(--border)", borderRadius:16, padding:"16px 20px", display:"flex", alignItems:"center", gap:14, boxShadow:"var(--sh)", textDecoration:"none" }}>
            <div style={{ width:40, height:40, borderRadius:"50%", background:"var(--blue-l)", display:"flex", alignItems:"center", justifyContent:"center", fontWeight:900, color:"var(--blue)", fontSize:".9rem", flexShrink:0 }}>
              {t.nome[0]}
            </div>
            <div style={{ flex:1, minWidth:0 }}>
              <div style={{ fontWeight:700, fontSize:".88rem", color:"var(--text)" }}>{t.nome}</div>
              <div style={{ fontSize:".7rem", color:"var(--muted)", fontFamily:"var(--mono)", marginTop:2, display:"flex", gap:8, flexWrap:"wrap" }}>
                <span>{t.slug}</span>
                <span>·</span>
                <span>{t.llm_model}</span>
                {t.has_calendar && <><span>·</span><span style={{ color:"var(--green)" }}>📅 Calendar</span></>}
              </div>
            </div>
            <div style={{ fontSize:".72rem", color:"var(--muted2)", textAlign:"right", flexShrink:0 }}>
              <div>{t.stats?.messages?.toLocaleString()} msgs</div>
              <div>{t.stats?.contacts} contatos</div>
            </div>
            <div style={{ display:"flex", gap:6, flexShrink:0 }}>
              <span style={{ background: t.paused?"var(--amber-l)":"var(--green-l)", color: t.paused?"var(--amber)":"var(--green)", padding:"3px 10px", borderRadius:100, fontSize:".68rem", fontWeight:700 }}>
                {t.paused ? "Pausado" : "Ativo"}
              </span>
              <button onClick={(e) => togglePause(e, t)} style={{ padding:"4px 12px", borderRadius:8, border:"1.5px solid var(--border)", background:"#fff", fontSize:".72rem", fontWeight:600, cursor:"pointer", fontFamily:"'Geist',sans-serif" }}>
                {t.paused ? "▶ Retomar" : "⏸ Pausar"}
              </button>
            </div>
          </Link>
        ))}
        {tenants.length === 0 && (
          <div style={{ background:"var(--blue-l)", border:"1.5px solid var(--blue-m)", borderRadius:16, padding:48, textAlign:"center" }}>
            <div style={{ fontSize:"2rem", marginBottom:12 }}>👥</div>
            <div style={{ fontWeight:700, marginBottom:8 }}>Nenhum cliente cadastrado</div>
            <Link to="/clients/new" style={{ color:"var(--blue)", fontWeight:700 }}>Cadastrar primeiro cliente →</Link>
          </div>
        )}
      </div>
    </div>
  );
}
EOF

# ── Conversations.jsx ─────────────────────────────────────
cat > frontend/src/pages/Conversations.jsx << 'EOF'
import React, { useEffect, useState } from "react";
import { api } from "../api";

export default function Conversations() {
  const [tenants, setTenants]   = useState([]);
  const [sel, setSel]           = useState(null);
  const [convs, setConvs]       = useState([]);
  const [conv, setConv]         = useState(null);
  const [msgs, setMsgs]         = useState([]);

  useEffect(() => { api.get("/admin/tenants").then(setTenants); }, []);

  const loadConvs = (t) => { setSel(t); setConv(null); setMsgs([]); api.get(`/admin/tenants/${t.id}/conversations`).then(setConvs); };
  const loadMsgs  = (c) => { setConv(c); api.get(`/admin/conversations/${c.id}/messages`).then(setMsgs); };

  const col = { background:"#fff", border:"1.5px solid var(--border)", borderRadius:14, overflow:"hidden", display:"flex", flexDirection:"column" };
  const colHead = { padding:"10px 14px", borderBottom:"1px solid var(--border)", fontSize:".68rem", fontWeight:700, letterSpacing:".06em", textTransform:"uppercase", color:"var(--muted2)", flexShrink:0 };

  return (
    <div>
      <h1 style={{ fontSize:"1.5rem", fontWeight:900, letterSpacing:"-.04em", marginBottom:20 }}>Conversas</h1>
      <div style={{ display:"grid", gridTemplateColumns:"180px 240px 1fr", gap:12, height:"calc(100vh - 140px)" }}>

        {/* Tenants */}
        <div style={col}>
          <div style={colHead}>Clientes</div>
          <div style={{ overflowY:"auto", flex:1 }}>
            {tenants.map(t => (
              <div key={t.id} onClick={() => loadConvs(t)} style={{ padding:"10px 14px", cursor:"pointer", background: sel?.id===t.id?"var(--blue-l)":"transparent", borderLeft: sel?.id===t.id?"2px solid var(--blue)":"2px solid transparent", fontSize:".78rem", fontWeight: sel?.id===t.id?700:500, color: sel?.id===t.id?"var(--blue)":"var(--muted)", transition:"all .15s" }}>
                <div>{t.nome}</div>
                <div style={{ fontSize:".65rem", color:"var(--muted2)", marginTop:2 }}>{t.stats?.contacts} contatos</div>
              </div>
            ))}
          </div>
        </div>

        {/* Conversas */}
        <div style={col}>
          <div style={colHead}>Conversas {convs.length>0&&`(${convs.length})`}</div>
          <div style={{ overflowY:"auto", flex:1 }}>
            {convs.map(c => (
              <div key={c.id} onClick={() => loadMsgs(c)} style={{ padding:"10px 14px", borderBottom:"1px solid var(--border)", cursor:"pointer", background: conv?.id===c.id?"var(--off)":"transparent" }}>
                <div style={{ fontSize:".75rem", fontWeight:700, color:"var(--text)", marginBottom:2 }}>{c.nome||c.phone}</div>
                {c.nome && <div style={{ fontSize:".65rem", color:"var(--muted2)", fontFamily:"var(--mono)", marginBottom:2 }}>{c.phone}</div>}
                <div style={{ fontSize:".68rem", color:"var(--muted2)", overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{c.last_message||"Sem mensagens"}</div>
                {c.last_activity && <div style={{ fontSize:".6rem", color:"var(--muted2)", marginTop:2 }}>{new Date(c.last_activity).toLocaleString("pt-BR")}</div>}
                <div style={{ display:"flex", gap:4, marginTop:4, flexWrap:"wrap" }}>
                  {c.closed && <span style={{ background:"var(--muted2)", color:"#fff", padding:"1px 6px", borderRadius:100, fontSize:".58rem", fontWeight:700 }}>Encerrada</span>}
                  {c.followup_1 && <span style={{ background:"var(--amber-l)", color:"var(--amber)", padding:"1px 6px", borderRadius:100, fontSize:".58rem", fontWeight:700 }}>FU1 ✓</span>}
                  {c.followup_2 && <span style={{ background:"var(--amber-l)", color:"var(--amber)", padding:"1px 6px", borderRadius:100, fontSize:".58rem", fontWeight:700 }}>FU2 ✓</span>}
                </div>
              </div>
            ))}
            {sel && convs.length===0 && <div style={{ padding:20, fontSize:".8rem", color:"var(--muted)", textAlign:"center" }}>Sem conversas ainda</div>}
            {!sel && <div style={{ padding:20, fontSize:".8rem", color:"var(--muted)", textAlign:"center" }}>← Selecione um cliente</div>}
          </div>
        </div>

        {/* Mensagens */}
        <div style={{ ...col, background:"var(--off)" }}>
          <div style={{ ...colHead, background:"#fff" }}>{conv ? (conv.nome||conv.phone) : "Selecione uma conversa"}</div>
          <div style={{ flex:1, overflowY:"auto", padding:12, display:"flex", flexDirection:"column", gap:8 }}>
            {msgs.map(m => (
              <div key={m.id} style={{ display:"flex", justifyContent: m.role==="user"?"flex-start":"flex-end" }}>
                <div style={{ maxWidth:"76%", padding:"8px 12px", borderRadius: m.role==="user"?"12px 12px 12px 3px":"12px 12px 3px 12px", background: m.role==="user"?"#fff":"var(--blue)", color: m.role==="user"?"var(--text)":"#fff", fontSize:".78rem", lineHeight:1.6, border: m.role==="user"?"1px solid var(--border)":"none", boxShadow:"var(--sh)", whiteSpace:"pre-wrap", wordBreak:"break-word" }}>
                  {m.content}
                  <div style={{ fontSize:".6rem", opacity:.6, marginTop:4, textAlign:"right" }}>{new Date(m.created_at).toLocaleTimeString("pt-BR")}</div>
                </div>
              </div>
            ))}
            {conv && msgs.length===0 && <div style={{ textAlign:"center", color:"var(--muted)", fontSize:".82rem", marginTop:20 }}>Sem mensagens</div>}
          </div>
        </div>
      </div>
    </div>
  );
}
EOF
ok "Frontend completo gerado"

cat > frontend/.env << ENVEOF
VITE_API_URL=https://${API_DOMAIN}
VITE_ADMIN_TOKEN=${ADMIN_TOKEN}
ENVEOF

# ════════════════════════════════════════
# docker-compose.yml
# ════════════════════════════════════════
cat > docker-compose.yml << COMPOSEEOF
version: '3.9'
services:
  agentos-api:
    build: ./backend
    container_name: agentos-api
    restart: unless-stopped
    ports: ["8000:8000"]
    env_file: .env
    depends_on:
      postgres-agentos:
        condition: service_healthy
    networks: [agentos-net, n8n-net]

  postgres-agentos:
    image: pgvector/pgvector:pg16
    container_name: postgres-agentos
    restart: unless-stopped
    environment:
      POSTGRES_DB: agentos
      POSTGRES_USER: agentos
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - agentos-pg-data:/var/lib/postgresql/data
      - ./backend/init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U agentos -d agentos"]
      interval: 10s; timeout: 5s; retries: 5
    networks: [agentos-net]

  agentos-nginx:
    image: nginx:alpine
    container_name: agentos-nginx
    restart: unless-stopped
    ports: ["80:80"]
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./frontend/dist:/usr/share/nginx/html:ro
    depends_on: [agentos-api]
    networks: [agentos-net]

volumes:
  agentos-pg-data:

networks:
  agentos-net:
  n8n-net:
    external: true
    name: n8n_default
COMPOSEEOF

# ════════════════════════════════════════
# nginx.conf
# ════════════════════════════════════════
cat > nginx.conf << NGINXEOF
events { worker_connections 1024; }
http {
  include mime.types;
  default_type application/octet-stream;
  gzip on; gzip_types text/plain application/json application/javascript text/css;

  server {
    listen 80;
    server_name ${API_DOMAIN};
    location / {
      proxy_pass http://agentos-api:8000;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_read_timeout 120;
    }
  }

  server {
    listen 80;
    server_name ${ADMIN_DOMAIN};
    root /usr/share/nginx/html;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
    location ~* \.(js|css|png|svg|ico)\$ { expires 30d; add_header Cache-Control "public, immutable"; }
  }
}
NGINXEOF

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
EOF

# ════════════════════════════════════════
# Build e subida
# ════════════════════════════════════════
step "Verificando dependências"
command -v docker &>/dev/null || { warn "Instalando Docker..."; curl -fsSL https://get.docker.com | sh; }
command -v node   &>/dev/null || { warn "Instalando Node..."; curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs; }
ok "Dependências OK"

step "Buildando frontend"
cd frontend
npm install --silent
npm run build
cd ..
ok "Build completo → frontend/dist/"

step "Subindo containers"
docker network inspect n8n_default &>/dev/null || {
  warn "Rede n8n_default não encontrada — criando rede standalone"
  sed -i '/n8n-net:/d; /external: true/d; /name: n8n_default/d' docker-compose.yml
}
docker compose up -d --build
ok "Containers no ar"

step "Aguardando banco"
sleep 10
docker compose exec -T postgres-agentos pg_isready -U agentos -d agentos && ok "Banco pronto" || warn "Banco ainda inicializando — aguarde 30s"

# ════════════════════════════════════════
# Resumo final
# ════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗"
echo   "║   ✅  AgentOS instalado com sucesso!            ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Acesso:${NC}"
echo -e "  ${CYAN}Painel Admin:${NC}  http://${ADMIN_DOMAIN}"
echo -e "  ${CYAN}API:${NC}           http://${API_DOMAIN}"
echo -e "  ${CYAN}Health check:${NC}  http://${API_DOMAIN}/health"
echo ""
echo -e "${BOLD}Admin Token (guarde!):${NC}"
echo -e "  ${YELLOW}${ADMIN_TOKEN}${NC}"
echo ""
echo -e "${BOLD}Fluxo para cadastrar um cliente:${NC}"
echo -e "  1. Acesse ${CYAN}http://${ADMIN_DOMAIN}${NC}"
echo -e "  2. Clique em ${BOLD}+ Novo cliente${NC}"
echo -e "  3. Preencha o wizard (3 passos)"
echo -e "  4. Copie o webhook gerado → cole na Evolution API"
echo -e "  5. Opcional: configure Google Calendar via Service Account na tela do cliente"
echo ""
echo -e "${BOLD}Para o Google Calendar (Service Account):${NC}"
echo -e "  1. console.cloud.google.com → Service Accounts → criar → baixar JSON"
echo -e "  2. Compartilhar o calendário do cliente com o email do service account"
echo -e "  3. Colar o JSON no painel admin → testar → salvar"
echo ""
echo -e "${BOLD}Comandos úteis:${NC}"
echo -e "  ${CYAN}docker compose logs -f agentos-api${NC}   — logs em tempo real"
echo -e "  ${CYAN}docker compose restart agentos-api${NC}   — reiniciar após mudanças"
echo -e "  ${CYAN}docker compose ps${NC}                    — status dos containers"

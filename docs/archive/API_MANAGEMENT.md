# VoIP Stack Management API

## 🎯 Overview

PostgreSQL-centric mimarisi sayesinde tüm sistem REST API ile yönetilebilir.

```
┌─────────────────────────────────────────┐
│      Management REST API (FastAPI)     │
│  • Tenant Management                    │
│  • User Management                      │
│  • Dialplan Management                  │
│  • CDR Reporting                        │
│  • Real-time Monitoring                 │
└─────────────────────────────────────────┘
           ↓                    ↓
    ┌──────────┐         ┌──────────────┐
    │PostgreSQL│         │ FreeSWITCH   │
    │(Data)    │         │(ESL API)     │
    └──────────┘         └──────────────┘
```

---

## 📋 API Capabilities

### ✅ Tenant Management
```bash
POST   /api/v1/tenants              # Yeni tenant oluştur
GET    /api/v1/tenants              # Tüm tenantları listele
GET    /api/v1/tenants/{id}         # Tenant detayı
PUT    /api/v1/tenants/{id}         # Tenant güncelle
DELETE /api/v1/tenants/{id}         # Tenant sil
```

### ✅ User Management
```bash
POST   /api/v1/tenants/{tid}/users        # Yeni kullanıcı ekle
GET    /api/v1/tenants/{tid}/users        # Tenant kullanıcıları
GET    /api/v1/users/{id}                 # Kullanıcı detayı
PUT    /api/v1/users/{id}                 # Kullanıcı güncelle
DELETE /api/v1/users/{id}                 # Kullanıcı sil
POST   /api/v1/users/{id}/password        # Şifre değiştir
```

### ✅ Dialplan Management
```bash
POST   /api/v1/tenants/{tid}/dialplan     # Yeni rule ekle
GET    /api/v1/tenants/{tid}/dialplan     # Tenant dialplan
PUT    /api/v1/dialplan/{id}              # Rule güncelle
DELETE /api/v1/dialplan/{id}              # Rule sil
```

### ✅ CDR & Reporting
```bash
GET    /api/v1/cdr                        # CDR query (filters)
GET    /api/v1/tenants/{tid}/cdr          # Tenant CDR
GET    /api/v1/users/{uid}/cdr            # User CDR
GET    /api/v1/reports/usage              # Kullanım raporu
GET    /api/v1/reports/billing            # Fatura raporu
```

### ✅ Real-time Monitoring
```bash
GET    /api/v1/status                     # Sistem durumu
GET    /api/v1/tenants/{tid}/status       # Tenant durumu
GET    /api/v1/calls/active               # Aktif çağrılar
WS     /api/v1/events                     # WebSocket events
```

### ✅ FreeSWITCH Control
```bash
POST   /api/v1/calls/{uuid}/hangup       # Çağrı sonlandır
POST   /api/v1/calls/{uuid}/transfer     # Transfer
GET    /api/v1/channels                  # Aktif kanallar
POST   /api/v1/reload                    # Config reload
```

---

## 🏗️ Architecture Design

### Components

**1. Management API Service** (FastAPI)
- REST endpoints
- WebSocket for real-time events
- Authentication/Authorization
- Rate limiting per tenant

**2. Database Layer** (SQLAlchemy)
- PostgreSQL ORM
- Transaction management
- Connection pooling

**3. FreeSWITCH Integration** (ESL)
- Event Socket Layer connection
- Real-time call control
- Event streaming

**4. Kamailio Integration** (MI/RPC)
- SIP registration management
- Dispatcher control
- Statistics

---

## 📁 Project Structure

```
managementapi/
├── app/
│   ├── api/
│   │   ├── v1/
│   │   │   ├── endpoints/
│   │   │   │   ├── tenants.py
│   │   │   │   ├── users.py
│   │   │   │   ├── dialplan.py
│   │   │   │   ├── cdr.py
│   │   │   │   ├── calls.py
│   │   │   │   └── monitoring.py
│   │   │   └── api.py
│   │   └── deps.py
│   ├── core/
│   │   ├── config.py
│   │   ├── security.py
│   │   └── events.py
│   ├── db/
│   │   ├── models.py
│   │   ├── schemas.py
│   │   └── crud.py
│   ├── integrations/
│   │   ├── freeswitch.py  # ESL client
│   │   └── kamailio.py    # MI/RPC client
│   └── main.py
├── requirements.txt
└── Dockerfile
```

---

## 💻 Implementation

### Step 1: Create Management API Service

**managementapi/requirements.txt**:
```
fastapi==0.109.0
uvicorn[standard]==0.27.0
sqlalchemy==2.0.25
psycopg2-binary==2.9.9
pydantic==2.5.3
pydantic-settings==2.1.0
python-multipart==0.0.6
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
websockets==12.0
greenswitch==2.0.0  # FreeSWITCH ESL
```

**managementapi/app/main.py**:
```python
from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from app.api.v1.api import api_router
from app.core.config import settings

app = FastAPI(
    title="VoIP Stack Management API",
    version="1.0.0",
    description="Multi-tenant VoIP management"
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API routes
app.include_router(api_router, prefix="/api/v1")

@app.get("/")
def root():
    return {
        "service": "VoIP Stack Management API",
        "version": "1.0.0",
        "docs": "/docs"
    }

@app.get("/health")
def health():
    return {"status": "healthy"}
```

### Step 2: Database Models (SQLAlchemy)

**managementapi/app/db/models.py**:
```python
from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship
from datetime import datetime

Base = declarative_base()

class Tenant(Base):
    __tablename__ = "tenants"

    id = Column(Integer, primary_key=True)
    tenant_code = Column(String(16), unique=True, nullable=False)
    domain = Column(String(128), unique=True, nullable=False)
    name = Column(String(255), nullable=False)
    company_name = Column(String(255))
    freeswitch_url = Column(String(255))
    max_channels = Column(Integer, default=100)
    max_users = Column(Integer, default=1000)
    active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # Relationships
    users = relationship("User", back_populates="tenant")
    dialplan_rules = relationship("Dialplan", back_populates="tenant")

class User(Base):
    __tablename__ = "subscriber"

    id = Column(Integer, primary_key=True)
    tenant_id = Column(Integer, ForeignKey("tenants.id"))
    username = Column(String(64), nullable=False)
    domain = Column(String(64), nullable=False)
    password = Column(String(64), nullable=False)
    ha1 = Column(String(64))
    ha1b = Column(String(64))
    display_name = Column(String(128))
    email_address = Column(String(128))
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    tenant = relationship("Tenant", back_populates="users")

class Dialplan(Base):
    __tablename__ = "dialplan"

    id = Column(Integer, primary_key=True)
    tenant_id = Column(Integer, ForeignKey("tenants.id"))
    context = Column(String(64), default="default")
    destination_number = Column(String(64), nullable=False)
    priority = Column(Integer, default=10)
    actions = Column(Text, nullable=False)
    description = Column(String(255))
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    tenant = relationship("Tenant", back_populates="dialplan_rules")
```

### Step 3: Pydantic Schemas

**managementapi/app/db/schemas.py**:
```python
from pydantic import BaseModel, EmailStr, validator
from typing import Optional, List
from datetime import datetime
import hashlib

# Tenant Schemas
class TenantBase(BaseModel):
    tenant_code: str
    domain: str
    name: str
    company_name: Optional[str] = None
    max_channels: int = 100
    max_users: int = 1000

class TenantCreate(TenantBase):
    pass

class TenantUpdate(BaseModel):
    name: Optional[str] = None
    company_name: Optional[str] = None
    max_channels: Optional[int] = None
    max_users: Optional[int] = None
    active: Optional[bool] = None

class TenantResponse(TenantBase):
    id: int
    active: bool
    created_at: datetime

    class Config:
        from_attributes = True

# User Schemas
class UserBase(BaseModel):
    username: str
    display_name: Optional[str] = None
    email_address: Optional[EmailStr] = None

class UserCreate(UserBase):
    password: str

    @validator('password')
    def hash_password(cls, v, values):
        # Will be hashed in CRUD layer with proper realm
        return v

class UserUpdate(BaseModel):
    display_name: Optional[str] = None
    email_address: Optional[EmailStr] = None
    enabled: Optional[bool] = None

class PasswordChange(BaseModel):
    old_password: str
    new_password: str

class UserResponse(UserBase):
    id: int
    tenant_id: int
    domain: str
    enabled: bool
    created_at: datetime

    class Config:
        from_attributes = True

# Dialplan Schemas
class DialplanBase(BaseModel):
    destination_number: str
    actions: str
    context: str = "default"
    priority: int = 10
    description: Optional[str] = None

class DialplanCreate(DialplanBase):
    pass

class DialplanUpdate(BaseModel):
    destination_number: Optional[str] = None
    actions: Optional[str] = None
    priority: Optional[int] = None
    description: Optional[str] = None
    enabled: Optional[bool] = None

class DialplanResponse(DialplanBase):
    id: int
    tenant_id: int
    enabled: bool
    created_at: datetime

    class Config:
        from_attributes = True

# CDR Schemas
class CDRQuery(BaseModel):
    tenant_id: Optional[int] = None
    start_date: Optional[datetime] = None
    end_date: Optional[datetime] = None
    caller_number: Optional[str] = None
    destination_number: Optional[str] = None
    limit: int = 100
    offset: int = 0

class CDRResponse(BaseModel):
    id: int
    tenant_id: int
    uuid: str
    caller_id_number: str
    destination_number: str
    start_stamp: datetime
    duration: int
    billsec: int
    hangup_cause: str

    class Config:
        from_attributes = True
```

### Step 4: CRUD Operations

**managementapi/app/db/crud.py**:
```python
from sqlalchemy.orm import Session
from sqlalchemy import and_, or_
from app.db import models, schemas
from typing import List, Optional
import hashlib

# Tenant CRUD
def create_tenant(db: Session, tenant: schemas.TenantCreate) -> models.Tenant:
    db_tenant = models.Tenant(**tenant.dict())
    db.add(db_tenant)
    db.commit()
    db.refresh(db_tenant)
    return db_tenant

def get_tenants(db: Session, skip: int = 0, limit: int = 100) -> List[models.Tenant]:
    return db.query(models.Tenant).offset(skip).limit(limit).all()

def get_tenant(db: Session, tenant_id: int) -> Optional[models.Tenant]:
    return db.query(models.Tenant).filter(models.Tenant.id == tenant_id).first()

def update_tenant(db: Session, tenant_id: int, tenant: schemas.TenantUpdate) -> Optional[models.Tenant]:
    db_tenant = get_tenant(db, tenant_id)
    if not db_tenant:
        return None

    for key, value in tenant.dict(exclude_unset=True).items():
        setattr(db_tenant, key, value)

    db.commit()
    db.refresh(db_tenant)
    return db_tenant

def delete_tenant(db: Session, tenant_id: int) -> bool:
    db_tenant = get_tenant(db, tenant_id)
    if not db_tenant:
        return False

    db.delete(db_tenant)
    db.commit()
    return True

# User CRUD
def create_user(db: Session, tenant_id: int, user: schemas.UserCreate) -> models.User:
    tenant = get_tenant(db, tenant_id)
    if not tenant:
        raise ValueError("Tenant not found")

    # Hash password with MD5 (SIP authentication)
    username = user.username
    domain = tenant.domain
    password = user.password
    ha1 = hashlib.md5(f"{username}:{domain}:{password}".encode()).hexdigest()
    ha1b = hashlib.md5(f"{username}@{domain}:{domain}:{password}".encode()).hexdigest()

    db_user = models.User(
        tenant_id=tenant_id,
        username=username,
        domain=domain,
        password=password,
        ha1=ha1,
        ha1b=ha1b,
        display_name=user.display_name,
        email_address=user.email_address
    )

    db.add(db_user)
    db.commit()
    db.refresh(db_user)
    return db_user

def get_users_by_tenant(db: Session, tenant_id: int) -> List[models.User]:
    return db.query(models.User).filter(models.User.tenant_id == tenant_id).all()

def get_user(db: Session, user_id: int) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.id == user_id).first()

def update_user(db: Session, user_id: int, user: schemas.UserUpdate) -> Optional[models.User]:
    db_user = get_user(db, user_id)
    if not db_user:
        return None

    for key, value in user.dict(exclude_unset=True).items():
        setattr(db_user, key, value)

    db.commit()
    db.refresh(db_user)
    return db_user

def change_user_password(db: Session, user_id: int, new_password: str) -> Optional[models.User]:
    db_user = get_user(db, user_id)
    if not db_user:
        return None

    # Rehash with new password
    username = db_user.username
    domain = db_user.domain
    ha1 = hashlib.md5(f"{username}:{domain}:{new_password}".encode()).hexdigest()
    ha1b = hashlib.md5(f"{username}@{domain}:{domain}:{new_password}".encode()).hexdigest()

    db_user.password = new_password
    db_user.ha1 = ha1
    db_user.ha1b = ha1b

    db.commit()
    db.refresh(db_user)
    return db_user

# Dialplan CRUD
def create_dialplan_rule(db: Session, tenant_id: int, rule: schemas.DialplanCreate) -> models.Dialplan:
    db_rule = models.Dialplan(tenant_id=tenant_id, **rule.dict())
    db.add(db_rule)
    db.commit()
    db.refresh(db_rule)
    return db_rule

def get_dialplan_by_tenant(db: Session, tenant_id: int) -> List[models.Dialplan]:
    return db.query(models.Dialplan).filter(models.Dialplan.tenant_id == tenant_id).all()
```

### Step 5: API Endpoints

**managementapi/app/api/v1/endpoints/tenants.py**:
```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from app.db import crud, schemas
from app.api.deps import get_db

router = APIRouter()

@router.post("/", response_model=schemas.TenantResponse, status_code=201)
def create_tenant(tenant: schemas.TenantCreate, db: Session = Depends(get_db)):
    """Create new tenant"""
    try:
        return crud.create_tenant(db, tenant)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@router.get("/", response_model=List[schemas.TenantResponse])
def list_tenants(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    """List all tenants"""
    return crud.get_tenants(db, skip=skip, limit=limit)

@router.get("/{tenant_id}", response_model=schemas.TenantResponse)
def get_tenant(tenant_id: int, db: Session = Depends(get_db)):
    """Get tenant details"""
    tenant = crud.get_tenant(db, tenant_id)
    if not tenant:
        raise HTTPException(status_code=404, detail="Tenant not found")
    return tenant

@router.put("/{tenant_id}", response_model=schemas.TenantResponse)
def update_tenant(tenant_id: int, tenant: schemas.TenantUpdate, db: Session = Depends(get_db)):
    """Update tenant"""
    updated = crud.update_tenant(db, tenant_id, tenant)
    if not updated:
        raise HTTPException(status_code=404, detail="Tenant not found")
    return updated

@router.delete("/{tenant_id}", status_code=204)
def delete_tenant(tenant_id: int, db: Session = Depends(get_db)):
    """Delete tenant"""
    if not crud.delete_tenant(db, tenant_id):
        raise HTTPException(status_code=404, detail="Tenant not found")
```

**managementapi/app/api/v1/endpoints/users.py**:
```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from app.db import crud, schemas
from app.api.deps import get_db

router = APIRouter()

@router.post("/tenants/{tenant_id}/users", response_model=schemas.UserResponse, status_code=201)
def create_user(tenant_id: int, user: schemas.UserCreate, db: Session = Depends(get_db)):
    """Create new user for tenant"""
    try:
        return crud.create_user(db, tenant_id, user)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@router.get("/tenants/{tenant_id}/users", response_model=List[schemas.UserResponse])
def list_tenant_users(tenant_id: int, db: Session = Depends(get_db)):
    """List all users for tenant"""
    return crud.get_users_by_tenant(db, tenant_id)

@router.get("/users/{user_id}", response_model=schemas.UserResponse)
def get_user(user_id: int, db: Session = Depends(get_db)):
    """Get user details"""
    user = crud.get_user(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user

@router.put("/users/{user_id}", response_model=schemas.UserResponse)
def update_user(user_id: int, user: schemas.UserUpdate, db: Session = Depends(get_db)):
    """Update user"""
    updated = crud.update_user(db, user_id, user)
    if not updated:
        raise HTTPException(status_code=404, detail="User not found")
    return updated

@router.post("/users/{user_id}/password", response_model=schemas.UserResponse)
def change_password(user_id: int, password: schemas.PasswordChange, db: Session = Depends(get_db)):
    """Change user password"""
    # TODO: Verify old password
    updated = crud.change_user_password(db, user_id, password.new_password)
    if not updated:
        raise HTTPException(status_code=404, detail="User not found")
    return updated
```

---

## 🚀 Deployment

**docker-compose.yml addition**:
```yaml
services:
  managementapi:
    build: ./managementapi
    container_name: managementapi
    environment:
      DATABASE_URL: postgresql://kamailio:kamailio@postgres:5432/kamailio
      FREESWITCH_ESL_HOST: freeswitch
      FREESWITCH_ESL_PORT: 8021
      FREESWITCH_ESL_PASSWORD: ClueCon
    ports:
      - "8000:8000"
    depends_on:
      - postgres
      - freeswitch
    networks:
      - voip_net
```

---

## 📚 API Usage Examples

### Create Tenant
```bash
curl -X POST http://localhost:8000/api/v1/tenants \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_code": "3000",
    "domain": "newcorp.voip.local",
    "name": "New Corporation",
    "company_name": "New Corp Ltd",
    "max_channels": 200,
    "max_users": 500
  }'
```

### Create User
```bash
curl -X POST http://localhost:8000/api/v1/tenants/1/users \
  -H "Content-Type: application/json" \
  -d '{
    "username": "john",
    "password": "john123",
    "display_name": "John Doe",
    "email_address": "john@example.com"
  }'
```

### Get CDR
```bash
curl "http://localhost:8000/api/v1/cdr?tenant_id=1&limit=10"
```

### Active Calls
```bash
curl "http://localhost:8000/api/v1/calls/active"
```

---

## 🎯 Benefits

- ✅ **Programmatic Management**: Otomatik tenant/user provisioning
- ✅ **Integration Ready**: CI/CD, admin portals, billing systems
- ✅ **Real-time Control**: Active call management, monitoring
- ✅ **Scalable**: Microservice architecture
- ✅ **Multi-tenant**: Tenant isolation and resource management

**Sonraki adım**: Management API'yi implement etmek ister misin?

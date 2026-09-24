from fastapi import FastAPI
from core.config import settings
from routers import items

app = FastAPI()

@app.get("/")
def read_root():
    return {"message": "Hello World", "environment": settings.environment}

app.include_router(items.router, prefix="/items")

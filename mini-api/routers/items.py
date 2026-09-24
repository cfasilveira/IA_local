from fastapi import APIRouter, HTTPException
from typing import List
from schemas.item import Item

router = APIRouter()

items_db = []

@router.get("/", response_model=List[Item])
def read_items():
    return items_db

@router.get("/health")
def health_check():
    return {"status": "UP"}

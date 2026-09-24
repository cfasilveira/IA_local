# /// script
# dependencies = [
#   "polars",
#   "yfinance",
#   "plotly",
#   "streamlit",
#   "scikit-learn",
#   "pandas"
# ]
# ///

import yfinance as yf
import polars as pl
import pandas as pd
import numpy as np
from sklearn.linear_model import LinearRegression
import plotly.graph_objects as go
import streamlit as st
from datetime import datetime, timedelta

class CommodityPredictor:
    def __init__(self, symbol, name):
        self.symbol = symbol
        self.name = name

    def fetch_and_process(self):
        # Baixa os dados
        raw_data = yf.download(self.symbol, period="1y", interval="1d")
        
        # CORREÇÃO PARA MULTI-INDEX: Achata os nomes das colunas se necessário
        if isinstance(raw_data.columns, pd.MultiIndex):
            raw_data.columns = raw_data.columns.get_level_values(0)
        
        # Reseta o índice para transformar a 'Date' em uma coluna comum
        raw_data = raw_data.reset_index()
        
        # Converte para Polars
        df = pl.from_pandas(raw_data)
        
        # Garante que as colunas sejam apenas 'Date' e 'Close'
        return df.select([
            pl.col("Date"),
            pl.col("Close")
        ]).drop_nulls()

    def predict(self, df):
        # Prepara X (dias passados) e y (preços)
        y = df["Close"].to_numpy().reshape(-1, 1)
        X = np.array(range(len(y))).reshape(-1, 1)
        
        model = LinearRegression()
        model.fit(X, y)
        
        # Projeta 30 dias à frente
        future_X = np.array(range(len(y), len(y) + 30)).reshape(-1, 1)
        y_pred = model.predict(future_X).flatten()
        
        last_date = df["Date"].max()
        future_dates = [last_date + timedelta(days=i) for i in range(1, 31)]
        
        return future_dates, y_pred

    def display(self):
        st.subheader(f"Análise de Base: {self.name} ({self.symbol})")
        df = self.fetch_and_process()
        future_dates, y_pred = self.predict(df)
        
        # Gráfico Plotly
        fig = go.Figure()
        fig.add_trace(go.Scatter(x=df["Date"], y=df["Close"], name='Histórico (12m)', line=dict(color='#00fbff')))
        fig.add_trace(go.Scatter(x=future_dates, y=y_pred, name='Projeção (30d)', line=dict(color='#ff0055', dash='dot')))
        fig.update_layout(template="plotly_dark", hovermode="x unified")
        st.plotly_chart(fig, use_container_width=True)
        
        # Insights do Engenheiro (O que o Devol esqueceu)
        current_price = df["Close"][-1]
        projected_price = y_pred[-1]
        delta = ((projected_price / current_price) - 1) * 100
        
        col1, col2 = st.columns(2)
        col1.metric("Variação Projetada (30d)", f"{delta:.2f}%")
        
        with col2:
            if delta > 1:
                st.error("🚨 RISCO: Tendência de alta nos insumos. Antecipe compras de hardware/frotas.")
            elif delta < -1:
                st.success("✅ OPORTUNIDADE: Tendência de queda. Aguarde para renovar estoque de TI.")
            else:
                st.warning("⚖️ ESTABILIDADE: Mercado lateralizado. Monitore transbordamento.")

# --- APP PRINCIPAL ---
st.set_page_config(layout="wide", page_title="Devol Predictive Monitor")
st.title("🐍 Devol: Inteligência de Insumos e Base Atômica")

# Execução
copper = CommodityPredictor("HG=F", "Cobre (High Grade)")
metals = CommodityPredictor("XME", "Metais e Mineração")

copper.display()
st.divider()
metals.display()

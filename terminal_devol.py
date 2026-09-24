# /// script
# run-with = "uv"
# deps = ["yfinance", "polars", "scipy", "scikit-learn", "streamlit", "plotly", "pandas", "numpy"]
# ///
import yfinance as yf
import polars as pl
from sklearn.ensemble import RandomForestRegressor
from sklearn.preprocessing import StandardScaler
from scipy.signal import hilbert
import streamlit as st
import plotly.graph_objects as go
import numpy as np
import pandas as pd
from concurrent.futures import ThreadPoolExecutor, as_completed

def fetch_data(symbol):
    try:
        df = yf.download(symbol, start="2015-01-01", progress=False)
        if df.empty: return None
        if isinstance(df.columns, pd.MultiIndex): df.columns = df.columns.get_level_values(0)
        return df.reset_index()
    except: return None

def create_features(df):
    df = df.copy()
    df['MA_7'] = df["Close"].rolling(window=7).mean()
    df['MA_21'] = df["Close"].rolling(window=21).mean()
    # Preenche NaNs iniciais para o Hilbert não falhar
    close_filled = df["Close"].ffill().bfill()
    h = hilbert(close_filled)
    df['Amplitude'] = np.abs(h)
    df['Phase'] = np.angle(h)
    return df

class AssetPredictor:
    def __init__(self, symbol):
        self.symbol = symbol
        self.raw_data = fetch_data(symbol)

    def predict_prices(self, df):
        cols = ["Close", "MA_7", "MA_21", "Amplitude", "Phase"]
        train_df = df.dropna()
        X = train_df[cols].to_numpy()
        y = train_df["Close"].shift(-10).dropna().to_numpy()
        scaler = StandardScaler()
        X_scaled = scaler.fit_transform(X[:len(y)])
        model = RandomForestRegressor(n_estimators=100, random_state=42, n_jobs=-1)
        model.fit(X_scaled, y)
        # Gerar datas futuras (Próximos 10 dias úteis)
        last_date = pd.to_datetime(df["Date"].iloc[-1])
        future_dates = pd.date_range(start=last_date + pd.Timedelta(days=1), periods=10, freq='B')
        # Contexto para features (Últimos 30 dias + 10 dias "flat" para projetar)
        last_context = df.tail(30).copy()
        future_df = pd.DataFrame({"Date": future_dates, "Close": [df["Close"].iloc[-1]] * 10})
        full_context = pd.concat([last_context, future_df], ignore_index=True)
        full_context = create_features(full_context)
        X_future = full_context[cols].tail(10).ffill().bfill()
        X_future_scaled = scaler.transform(X_future.to_numpy())
        # Monte Carlo simplificado via Random Forest
        y_preds = np.array([tree.predict(X_future_scaled) for tree in model.estimators_])
        return future_dates, np.mean(y_preds, axis=0), np.std(y_preds, axis=0)

# --- App Streamlit ---
st.set_page_config(layout="wide", page_title="DEVOL Sênior Terminal")
st.title("🏛️ DEVOL - Gestão de Ativos de Alta Precisão")

symbols = ["HG=F", "NVDA"]
results = {}
with st.spinner("Calculando Hilbert e Sharpe Ratio..."):
    for sym in symbols:
        pred_obj = AssetPredictor(sym)
        hist = pred_obj.raw_data
        if hist is not None:
            hist_feat = create_features(hist).dropna()
            dates, m, s = pred_obj.predict_prices(hist_feat)
            results[sym] = {"hist": hist_feat, "f_dates": dates, "mean": m, "std": s}

col1, col2 = st.columns(2)

for i, (sym, res) in enumerate(results.items()):
    with [col1, col2][i]:
        # Cálculo do Sharpe Ratio (Simplificado: Retorno Esperado / Volatilidade Prevista)
        expected_ret = (res["mean"][-1] - res["hist"]["Close"].iloc[-1]) / res["hist"]["Close"].iloc[-1]
        volatility = np.mean(res["std"]) / res["hist"]["Close"].iloc[-1]
        sharpe = expected_ret / volatility if volatility > 0 else 0
        st.metric(f"Ativo: {sym}", f"Sharpe: {sharpe:.2f}")

        # Função de Alerta de Oportunidade
        if sharpe > 1.5:
            st.success(f'🚨 OPORTUNIDADE DE ALTA CONFIANÇA DETECTADA EM {sym}')

        fig = go.Figure(layout=dict(template="plotly_dark", title=f"Projeção {sym}"))
        # Sombra de Incerteza
        fig.add_trace(go.Scatter(x=res["f_dates"], y=res["mean"] + 2*res["std"], mode='lines', line_color='rgba(0,255,0,0)', showlegend=False))
        fig.add_trace(go.Scatter(x=res["f_dates"], y=res["mean"] - 2*res["std"], mode='lines', line_color='rgba(0,255,0,0)', fill='tonexty', fillcolor='rgba(0,255,100,0.2)', name="Confiança 95%"))
        # Linha Principal
        fig.add_trace(go.Scatter(x=res["f_dates"], y=res["mean"], mode='lines+markers', name="Predição", line=dict(color='yellow', width=3)))
        st.plotly_chart(fig, use_container_width=True)

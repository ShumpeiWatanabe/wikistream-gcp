FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Cloud Run expects your container to listen on $PORT
CMD ["sh", "-c", "exec gunicorn -b 0.0.0.0:8080 main:app"]

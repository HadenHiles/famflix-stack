FROM python:3.12-alpine
WORKDIR /app
COPY rolling_window.py .
RUN pip install --no-cache-dir requests
CMD ["python3", "/app/rolling_window.py"]

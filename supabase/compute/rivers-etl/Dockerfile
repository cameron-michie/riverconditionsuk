FROM public.ecr.aws/docker/library/python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN pip install httpx "psycopg[binary]" pandas numpy scipy h5py pillow scikit-image shapely pyproj pyarrow eccodes
WORKDIR /app
COPY app/ /app/
# job commands in ops.etl_job call ../../.venv/bin/python; point that at the image's interpreter
RUN mkdir -p /app/.venv/bin /app/data/raw && ln -s /usr/local/bin/python /app/.venv/bin/python
RUN python -c "import eccodes, h5py, skimage, pyarrow, psycopg, shapely, pyproj, scipy, pandas, os; print('imports ok'); os._exit(0)"
CMD ["python", "/app/server.py"]

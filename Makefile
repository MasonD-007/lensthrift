VENV   := backend/.venv
PY     := $(VENV)/bin/python
PORT   ?= 8080

.PHONY: help install run dev test tunnel clean

help:
	@echo "make install  create venv and install backend deps"
	@echo "make run      serve backend + web on :$(PORT)"
	@echo "make dev      same as run, with auto-reload"
	@echo "make test     run backend tests"
	@echo "make tunnel   HTTPS tunnel to :$(PORT) (cloudflared, falls back to ngrok)"
	@echo "make clean    remove venv and caches"

$(PY):
	python3 -m venv $(VENV)
	$(PY) -m pip install -q --upgrade pip
	$(PY) -m pip install -q -r backend/requirements.txt

install: $(PY)

run: $(PY)
	cd backend && .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port $(PORT)

dev: $(PY)
	cd backend && .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port $(PORT) --reload

test: $(PY)
	$(PY) -m pip install -q -r backend/requirements-dev.txt
	cd backend && .venv/bin/python -m pytest -q

tunnel:
	@command -v cloudflared >/dev/null && cloudflared tunnel --url http://localhost:$(PORT) \
		|| ngrok http $(PORT)

clean:
	rm -rf $(VENV)
	find backend -name __pycache__ -type d -prune -exec rm -rf {} +

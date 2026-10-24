VENV   := backend/.venv
PY     := $(VENV)/bin/python
PORT   ?= 8080

.PHONY: help install run dev test tunnel clean

help:
	@echo "make install  create venv and install backend deps"
	@echo "make run      serve backend + web on :$(PORT)"
	@echo "make dev      same as run, with auto-reload"
	@echo "make test     backend tests (pytest) + web tests (node --test)"
	@echo "make tunnel   HTTPS tunnel to :$(PORT) (cloudflared, falls back to ngrok)"
	@echo "make clean    remove venv and caches"

STAMP := $(VENV)/.installed

$(STAMP): backend/requirements.txt
	test -x $(PY) || python3 -m venv $(VENV)
	$(PY) -m pip install -q --upgrade pip
	$(PY) -m pip install -q -r backend/requirements.txt
	touch $(STAMP)

install: $(STAMP)

run: $(STAMP)
	cd backend && .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port $(PORT)

dev: $(STAMP)
	cd backend && .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port $(PORT) --reload

test: $(STAMP)
	cd backend && .venv/bin/python -m pytest -q
	node --test web/tests/

tunnel:
	@command -v cloudflared >/dev/null && cloudflared tunnel --url http://localhost:$(PORT) \
		|| ngrok http $(PORT)

clean:
	rm -rf $(VENV)
	find backend -name __pycache__ -type d -prune -exec rm -rf {} +

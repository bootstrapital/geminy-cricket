SHELL := /bin/bash
RUBOCOP_CACHE_ROOT ?= tmp/rubocop_cache
BUNDLE_AUDIT_DB ?= tmp/ruby-advisory-db
BUNDLE_AUDIT_STRICT ?= false
SMOKE_PORT ?= 48213
SMOKE_DB_PATH ?= tmp/smoke.duckdb
SMOKE_SERVER_URL ?= http://127.0.0.1:$(SMOKE_PORT)
SMOKE_MODE ?= auto
SMOKE_HEALTH_RETRIES ?= 40
SMOKE_HEALTH_SLEEP ?= 0.25

.PHONY: install syntax lint test security security-strict smoke release-check release-check-install check

install:
	bundle install

syntax:
	@set -euo pipefail; \
	find lib -type f -name "*.rb" -print0 | xargs -0 -n1 ruby -c; \
	ruby -c bin/geminy-cricket; \
	ruby -c bin/geminy-cricket-mcp; \
	ruby -c bin/geminy-cricket-server; \
	ruby -c config.ru

lint:
	@mkdir -p "$(RUBOCOP_CACHE_ROOT)"
	RUBOCOP_CACHE_ROOT="$(RUBOCOP_CACHE_ROOT)" bundle exec rubocop

test:
	bundle exec rspec

security:
	bundle exec brakeman -q --force .
	@if [ "$(BUNDLE_AUDIT_STRICT)" = "true" ]; then \
		bundle exec bundle-audit check --update --database "$(BUNDLE_AUDIT_DB)"; \
	else \
		bundle exec bundle-audit check --update --database "$(BUNDLE_AUDIT_DB)" || { \
			echo "WARN: bundle-audit DB update failed (likely offline). Skipping advisory check."; \
		}; \
	fi

security-strict:
	BUNDLE_AUDIT_STRICT=true $(MAKE) security

smoke:
	@set -euo pipefail; \
	mkdir -p tmp; \
	rm -f "$(SMOKE_DB_PATH)"; \
	mode="$(SMOKE_MODE)"; \
	run_direct=0; \
	server_pid=""; \
	start_server_smoke() { \
		GC_DB_PATH="$(SMOKE_DB_PATH)" GC_DASHBOARD_PORT="$(SMOKE_PORT)" bundle exec ruby bin/geminy-cricket-server > tmp/smoke-server.log 2>&1 & \
		server_pid=$$!; \
		for i in $$(seq 1 "$(SMOKE_HEALTH_RETRIES)"); do \
			if curl -fsS "$(SMOKE_SERVER_URL)/health" >/dev/null 2>&1; then \
				return 0; \
			fi; \
			sleep "$(SMOKE_HEALTH_SLEEP)"; \
		done; \
		return 1; \
	}; \
	stop_server_smoke() { \
		if [ -n "$$server_pid" ]; then \
			kill "$$server_pid" 2>/dev/null || true; \
			wait "$$server_pid" 2>/dev/null || true; \
		fi; \
	}; \
	trap 'stop_server_smoke' EXIT; \
	if [ "$$mode" = "server" ] || [ "$$mode" = "auto" ]; then \
		if start_server_smoke; then \
			:; \
		elif [ "$$mode" = "server" ]; then \
			echo "ERROR: smoke server failed to start in server mode. See tmp/smoke-server.log"; \
			tail -n 120 tmp/smoke-server.log || true; \
			exit 1; \
		else \
			echo "WARN: smoke server failed to start; falling back to direct mode."; \
			tail -n 40 tmp/smoke-server.log || true; \
			stop_server_smoke; \
			run_direct=1; \
		fi; \
	else \
		run_direct=1; \
	fi; \
	run_cli_server() { \
		step="$$1"; payload="$$2"; \
		if ! printf "%s" "$$payload" | GC_SUPERVISOR_MODE=server GC_SERVER_URL="$(SMOKE_SERVER_URL)" bundle exec ruby bin/geminy-cricket; then \
			echo "ERROR: smoke step '$$step' failed in server mode. See tmp/smoke-server.log"; \
			tail -n 120 tmp/smoke-server.log || true; \
			exit 1; \
		fi; \
	}; \
	run_cli_direct() { \
		step="$$1"; payload="$$2"; \
		if ! printf "%s" "$$payload" | GC_SUPERVISOR_MODE=direct GC_DB_PATH="$(SMOKE_DB_PATH)" bundle exec ruby bin/geminy-cricket; then \
			echo "ERROR: smoke step '$$step' failed in direct mode."; \
			exit 1; \
		fi; \
	}; \
	if [ "$$run_direct" -eq 1 ]; then \
		run_cli_direct "gc_start" '{"tool":"gc_start","args":{"goal":"smoke"}}'; \
		run_cli_direct "gc_plan_step" '{"tool":"gc_plan_step","args":{"desc":"smoke-step"}}'; \
		run_cli_direct "gc_health" '{"tool":"gc_health","args":{}}'; \
	else \
		run_cli_server "gc_start" '{"tool":"gc_start","args":{"goal":"smoke"}}'; \
		run_cli_server "gc_plan_step" '{"tool":"gc_plan_step","args":{"desc":"smoke-step"}}'; \
		run_cli_server "gc_health" '{"tool":"gc_health","args":{}}'; \
		stop_server_smoke; \
	fi

release-check:
	@set -euo pipefail; \
	rm -f geminy-cricket-*.gem; \
	gem build geminy-cricket.gemspec; \
	GEM_FILE=$$(ls geminy-cricket-*.gem | head -n 1); \
	tar -tf "$$GEM_FILE" >/dev/null; \
	gem specification "$$GEM_FILE" executables >/dev/null; \
	ruby -c bin/geminy-cricket >/dev/null; \
	ruby -c bin/geminy-cricket-mcp >/dev/null; \
	ruby -c bin/geminy-cricket-server >/dev/null

release-check-install:
	@set -euo pipefail; \
	rm -f geminy-cricket-*.gem; \
	gem build geminy-cricket.gemspec; \
	GEM_FILE=$$(ls geminy-cricket-*.gem | head -n 1); \
	rm -rf tmp/gem-home; \
	mkdir -p tmp/gem-home; \
	gem install --local --no-document --ignore-dependencies --install-dir tmp/gem-home "$$GEM_FILE"; \
	test -x tmp/gem-home/bin/geminy-cricket; \
	test -x tmp/gem-home/bin/geminy-cricket-mcp; \
	test -x tmp/gem-home/bin/geminy-cricket-server

check: syntax lint test security

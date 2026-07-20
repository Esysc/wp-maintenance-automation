.PHONY: all keys test clean

all: keys test

keys:
	./generate-ssh-keys.sh

DETECTED_WP_VERSION := $(shell ls -dt ../backup_artifacts/2*/wp/wp-includes/version.php 2>/dev/null | head -1 | xargs grep "^\\$$wp_version" 2>/dev/null | head -1 | sed "s/.*= '\(.*\)';/\1/")
DETECTED_WP_UPGRADE_VERSION := $(shell curl -sf https://api.wordpress.org/core/version-check/1.7/ 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['offers'][0]['version'])" 2>/dev/null)
DETECTED_PHP_VERSION := $(shell grep -m1 '^WP_PHP_VERSION=' ../.env 2>/dev/null | cut -d= -f2)

test: keys
	WP_INITIAL_VERSION=$(or $(DETECTED_WP_VERSION),7.0.2) \
	WP_UPGRADE_VERSION=$(or $(DETECTED_WP_UPGRADE_VERSION),7.0.2) \
	WP_PHP_VERSION=$(or $(DETECTED_PHP_VERSION),8.2) \
	docker compose -f docker-compose.yml up --build --abort-on-container-exit --exit-code-from test-runner

clean:
	docker compose -f docker-compose.yml down -v
	rm -f ssh/id_rsa ssh/id_rsa.pub ssh/authorized_keys

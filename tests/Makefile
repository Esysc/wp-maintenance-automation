.PHONY: all keys test clean

WP_INITIAL_VERSION ?= 6.6.2
WP_UPGRADE_VERSION ?= 6.7.2

all: keys test

keys:
	./generate-ssh-keys.sh

test: keys
	WP_INITIAL_VERSION=$(WP_INITIAL_VERSION) \
	WP_UPGRADE_VERSION=$(WP_UPGRADE_VERSION) \
	docker compose -f docker-compose.yml up --build --abort-on-container-exit --exit-code-from test-runner

clean:
	docker compose -f docker-compose.yml down -v
	rm -f ssh/id_rsa ssh/id_rsa.pub ssh/authorized_keys

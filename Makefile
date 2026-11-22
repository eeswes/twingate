.PHONY: vendor build certs trust-cert start stop status test selftest clean

vendor:
	sh scripts/fetch-vendor.sh

build:
	sh scripts/build.sh

certs:
	sh scripts/gen-certs.sh

trust-cert:
	sh scripts/install-ca.sh

start:
	sh scripts/start.sh

stop:
	sh scripts/stop.sh

status:
	sh scripts/status.sh

# 需要外网的协议探测（目标默认为 example.com）
test:
	python3 tests/tg_probe.py --mode all

# 不依赖外网的本地自测，自动拉起/停止代理，含认证与证书校验
selftest:
	python3 tests/tg_local_test.py

clean:
	sh scripts/stop.sh || true
	rm -f run/*.pid run/3proxy.cfg

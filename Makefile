.PHONY: vendor build certs trust-cert start stop status test selftest install uninstall clean

# 安装为单个 twingate 命令。默认装到 ~/.local；可指定 PREFIX / CONFIG_DIR / DATA_DIR。
# 例：make install PREFIX=/usr/local
#     make install PREFIX=/data/data/com.termux/files/usr
#     make uninstall PREFIX=/usr/local
install:
	sh scripts/install.sh $(if $(PREFIX),--prefix $(PREFIX)) $(if $(CONFIG_DIR),--config-dir $(CONFIG_DIR)) $(if $(DATA_DIR),--data-dir $(DATA_DIR))

uninstall:
	sh scripts/uninstall.sh $(if $(PREFIX),--prefix $(PREFIX)) $(if $(CONFIG_DIR),--config-dir $(CONFIG_DIR)) $(if $(DATA_DIR),--data-dir $(DATA_DIR))

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

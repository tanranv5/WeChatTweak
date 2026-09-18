.PHONY: build runtime release clean

# 版本号（发布 tarball 用），默认取 config.json 里最新一条
VERSION ?= $(shell python3 -c "import json;print(json.load(open('config.json'))[-1]['version'])" 2>/dev/null || echo 0)

# 主 CLI（universal）
build::
	swift build -c release --arch arm64 --arch x86_64
	cp -f .build/apple/Products/Release/wechattweak ./wechattweak

# 撤回提示运行时组件（x86_64 dylib）
runtime::
	cd runtime && ./build.sh

# 组装可分发产物：wechattweak + libwxrevoketip.dylib + add_load_dylib.py
# 三者放同一目录；brew 装到 libexec 后工具会自动定位
release:: build runtime
	rm -rf dist
	mkdir -p dist
	cp -f wechattweak dist/
	cp -f runtime/build/libwxrevoketip.dylib dist/
	cp -f runtime/add_load_dylib.py dist/
	tar -C dist -czf wechattweak-v$(VERSION)-macos-universal.tar.gz .
	@echo "== 产物 =="
	@ls -la wechattweak-v$(VERSION)-macos-universal.tar.gz
	@echo "sha256: $$(shasum -a 256 wechattweak-v$(VERSION)-macos-universal.tar.gz | awk '{print $$1}')"

clean::
	rm -rf .build dist
	rm -f wechattweak wechattweak-v*-macos-universal.tar.gz

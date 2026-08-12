.PHONY: build clean

build:
	./macos/build.sh

clean:
	$(MAKE) -C nfq clean
	find build dist -depth -delete 2>/dev/null || true

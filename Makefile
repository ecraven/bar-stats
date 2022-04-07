.PHONY: all image run

all: image run

image:
	podman build . --isolation=chroot -t bar-stats
run:
	podman run --rm -ti --net=host bar-stats

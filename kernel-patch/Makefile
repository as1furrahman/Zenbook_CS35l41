# Out-of-tree build of the patched CS35L41 HDA I2C driver.
# Produces snd-hda-scodec-cs35l41-i2c.ko — the SAME module name as the
# in-kernel one — so that installing it into
#   /lib/modules/$(uname -r)/updates/
# (which depmod ranks above the stock kernel/ directory) cleanly overrides
# the packaged module without touching any packaged file.

obj-m += snd-hda-scodec-cs35l41-i2c.o
snd-hda-scodec-cs35l41-i2c-objs := cs35l41_hda_i2c.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

install: all
	install -D -m 0644 snd-hda-scodec-cs35l41-i2c.ko \
		$(DESTDIR)/lib/modules/$(shell uname -r)/updates/snd-hda-scodec-cs35l41-i2c.ko
	depmod -a $(shell uname -r)

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all install clean

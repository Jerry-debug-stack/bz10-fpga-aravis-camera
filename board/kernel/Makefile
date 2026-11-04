KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) $(if $(O),O=$(O)) modules

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) $(if $(O),O=$(O)) modules_install

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) $(if $(O),O=$(O)) clean

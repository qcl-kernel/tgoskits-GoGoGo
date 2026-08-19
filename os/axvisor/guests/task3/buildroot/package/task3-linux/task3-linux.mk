################################################################################
#
# task3-linux
#
################################################################################

TASK3_LINUX_VERSION = 1
TASK3_LINUX_SITE = $(BR2_EXTERNAL_TASK3_PATH)/../build/staging/linux-app
TASK3_LINUX_SITE_METHOD = local

define TASK3_LINUX_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c11 -O2 -Wall -Wextra \
		-I$(@D) -o $(@D)/task3-linux \
		$(@D)/main.c $(@D)/rtipc_client.c $(@D)/deadline.c $(@D)/metrics.c \
		$(@D)/y4m.c $(@D)/cnn.c $(@D)/session.c \
		$(@D)/task3_protocol.c $(@D)/rt_ipc.c
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/task2/linux \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -Wall -Wextra -O2 -static -I../common" \
		target/rtipic-client
endef

define TASK3_LINUX_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/task2/linux/target/rtipic-client \
		$(TARGET_DIR)/bin/rtipic-client
	$(INSTALL) -D -m 0755 $(@D)/task3-linux \
		$(TARGET_DIR)/usr/bin/task3-linux
	$(INSTALL) -D -m 0644 $(TASK3_LINUX_SITE)/line-follow.y4m \
		$(TARGET_DIR)/opt/task3/line-follow.y4m
	$(INSTALL) -D -m 0644 $(TASK3_LINUX_SITE)/truth.csv \
		$(TARGET_DIR)/opt/task3/truth.csv
	$(INSTALL) -D -m 0755 $(TASK3_LINUX_SITE)/init-task123 \
		$(TARGET_DIR)/init
endef

$(eval $(generic-package))

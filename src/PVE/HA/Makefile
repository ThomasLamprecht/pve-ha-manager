SIM_SOURCES=CRM.pm Env.pm Groups.pm Resources.pm LRM.pm Manager.pm \
	NodeStatus.pm Tools.pm FenceConfig.pm Fence.pm Usage.pm

SOURCES=${SIM_SOURCES} Config.pm

.PHONY: install
install:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE/HA
	for i in ${SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/HA/$$i; done
	make -C Resources install
	make -C Usage install
	make -C Env install

.PHONY: installsim
installsim:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE/HA
	for i in ${SIM_SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/HA/$$i; done
	make -C Sim install

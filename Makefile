# include .build.mode.env file
BUILD_MODE_ENV_FILE=./docker/.build.mode.env
include $(BUILD_MODE_ENV_FILE)
export $(shell sed 's/=.*//' $(BUILD_MODE_ENV_FILE))

# hide output for clear log
ifndef VERBOSE
.SILENT:
endif


.PHONY: ckb ckb2 ckb3 connect-ckb chaos version
###### command list ########

### 1. utils
version:
	echo "=== kicker info ===" && cd docker && cat .build.mode.env

manual-image:
	@read -p "Please Enter New Image Tag: " VERSION ; \
	cd docker/manual-image && docker build . -t ${DOCKER_MANUAL_BUILD_IMAGE_NAME}:$$VERSION ;\

create-folder:
	mkdir -p workspace/bin
	mkdir -p workspace/deploy/backend
	mkdir -p workspace/deploy/polyjuice-backend
	mkdir -p workspace/scripts/release

uninstall:
	rm -rf packages/*
	echo "remove all packages."

clean-cache:
	rm -rf cache/activity/*
	echo "remove all cache activities data."

clean-workspace:
	rm -rf workspace/*
	echo "remove all files in workspace."

clean-data: clean-cache clean-workspace
	rm -rf quick-mode

clean: uninstall clean-data
	echo "successful remove packages, workspace and cache activities."

clean-build-cache:
	rm -rf cache/build/*
	echo "remove build cache."

### 2. main command

# init: create-folder prepare-files install build-image
init: create-folder install build-image

prepare-files:
	cp ./config/private_key ./workspace/deploy/private_key
	cp ./config/meta_user_private_key ./workspace/deploy/meta_user_private_key
	sh ./docker/layer2/init_config_json.sh

build-image:
	cd docker && docker-compose build --no-rm

install: SHELL:=/bin/bash
install:
# if manual build web3
	if [ "$(MANUAL_BUILD_WEB3)" = true ] ; then \
		source ./gw_util.sh && prepare_package godwoken-web3 $$WEB3_GIT_URL $$WEB3_GIT_CHECKOUT > /dev/null; \
		"$(INSTALL_JS_NODE_MODULE_NOT_COPY)" && make install-web3-node-modules-if-empty || make copy-web3-node-modules-if-empty ;\
		docker run --rm -v `pwd`/packages/godwoken-web3:/app -w=/app $$DOCKER_WEB3_PREBUILD_IMAGE_NAME:$$DOCKER_WEB3_PREBUILD_IMAGE_TAG /bin/bash -c "yarn build" ; \
		make copy-web3-from-packages-to-manual-artifacts; \
	fi
	echo "Web3 has been initialized."
# if manual build web3-indexer
	if [ "$(MANUAL_BUILD_WEB3_INDEXER)" = true ] ; then \
		source ./gw_util.sh && prepare_package godwoken-web3 $$WEB3_GIT_URL $$WEB3_GIT_CHECKOUT > /dev/null; \
		source ./gw_util.sh &&  cargo_build_web3_indexer_on_local_or_docker ; \
		make copy-web3-indexer-binary-from-packages-to-workspace ; \
		make copy-web3-indexer-binary-from-packages-to-manual-artifacts ; \
	else make copy-web3-indexer-bin-from-docker;\
	fi
	echo "Web3-indexer has been initialized."
# if manual build polyman
	if [ "$(MANUAL_BUILD_POLYMAN)" = true ] ; then \
		source ./gw_util.sh && prepare_package godwoken-polyman $$POLYMAN_GIT_URL $$POLYMAN_GIT_CHECKOUT > /dev/null; \
		"$(INSTALL_JS_NODE_MODULE_NOT_COPY)" && make install-polyman-node-modules-if-empty || make copy-polyman-node-modules-if-empty ;\
	fi
	echo "Polyman has been initialized."
# if manual build godwoken
	if [ "$(MANUAL_BUILD_GODWOKEN)" = true ] ; then \
		source ./gw_util.sh && prepare_package godwoken $$GODWOKEN_GIT_URL $$GODWOKEN_GIT_CHECKOUT > /dev/null; \
		source ./gw_util.sh && cargo_build_local_or_docker ; \
		make copy-godwoken-binary-from-packages-to-workspace ; \
		make copy-godwoken-binary-from-packages-to-manual-artifacts; \
	else make copy-godwoken-bin-from-docker ; \
	fi
	echo "Godwoken has been initialized."
# if manual build godwoken-polyjuice
	if [ "$(MANUAL_BUILD_POLYJUICE)" = true ] ; then \
		source ./gw_util.sh && prepare_package godwoken-polyjuice $$POLYJUICE_GIT_URL $$POLYJUICE_GIT_CHECKOUT > /dev/null ; \
		cd packages/godwoken-polyjuice && git submodule update --init --recursive --depth=1 && cd ../.. ; \
		make rebuild-polyjuice-bin ; \
	else make copy-polyjuice-bin-from-docker ; \
	fi
	echo "Godwoken-Polyjuice has been initialized."
# if manual build godwoken-scripts
	if [ "$(MANUAL_BUILD_SCRIPTS)" = true ] ; then \
		source ./gw_util.sh && prepare_package godwoken-scripts $$SCRIPTS_GIT_URL $$SCRIPTS_GIT_CHECKOUT > /dev/null ; \
		make rebuild-gw-scripts-and-bin ; \
	else make copy-gw-scripts-and-bin-from-docker ; \
	fi
	echo "Godwoken-scripts has been initialized."
# if manual build omni lock
	if [ "$(MANUAL_BUILD_OMNI_LOCK)" = true ] ; then \
		source ./gw_util.sh && prepare_package ckb-production-scripts $$OMNI_LOCK_GIT_URL $$OMNI_LOCK_CHECKOUT > /dev/null ; \
		make rebuild-omni-lock ; \
	else make copy-omni-lock-from-docker ; \
	fi
	echo "Omni-lock has been initialized."
# if multi ckb nodes, install deps for plugins
# todo: maybe use prebuild image here
	if [ "$(ENABLE_MULTI_CKB_NODES)" = true ] ; then \
		cd plugins/chaos && yarn ;\
	fi

# Missing workspace/bin/godwoken means that init step is required
workspace/bin/godwoken:
	make init

start: SHELL:=/bin/bash
start: workspace/bin/godwoken
	if [ "$(ENABLE_MULTI_CKB_NODES)" = true ] ; then \
		source ./gw_util.sh && wait_to_connect_ckb > connect-ckb.log 2>&1 & \
	fi
	if [ "$(WATCH_CKB_REORG)" = true ] ; then \
		source ./gw_util.sh && watch_ckb_reorg > chain-reorg.log 2>&1 & \
	fi
	source ./gw_util.sh && start
	# make show_wait_tips

start-f:
	cd docker && FORCE_GODWOKEN_REDEPLOY=true docker-compose --env-file .build.mode.env up -d --build > /dev/null
	make show_wait_tips

show_wait_tips: SHELL:=/bin/bash
show_wait_tips:
	source ./gw_util.sh && show_wait_tips

restart:
	cd docker && docker-compose restart

stop:
	cd docker && docker-compose stop

pause:
	cd docker && docker-compose pause

unpause:
	cd docker && docker-compose unpause

down:
	cd docker && docker-compose down --remove-orphans

status:
	cd docker && docker-compose ps

### 3. activity logs command
# show polyjuice
sp:
	cd docker && docker-compose logs -f --tail 200 polyjuice
polyjuice:
	cd docker && docker-compose logs -f --tail 200 polyjuice
# show godwoken
sg:
	cd docker && docker-compose logs -f --tail 200 godwoken
godwoken:
	cd docker && docker-compose logs -f --tail 200 godwoken
godwoken-readonly:
	cd docker && docker-compose logs -f --tail 200 godwoken-readonly
# show ckb-indexer
indexer:
	cd docker && docker-compose logs -f indexer
# show web3
web3:
	cd docker && docker-compose logs -f --tail 200 web3
web3-indexer:
	cd docker && docker-compose logs -f --tail 200 web3-indexer
# show ckb
ckb:
	cd docker && docker-compose logs -f --tail 200 ckb
# show ckb2
ckb2:
	cd docker && docker-compose logs -f --tail 200 ckb2

# show ckb3
ckb3:
	cd docker && docker-compose logs -f --tail 200 ckb3

# show call-polyman
call-polyman:
	cd docker && docker-compose logs -f call-polyman
# show postgres db
db:
	cd docker && docker-compose logs -f postgres

# show redis cache
redis:
	cd docker && docker-compose logs -f redis

# show zookeeper
zookeeper:
	cd docker && docker-compose logs -f --tail 200 zookeeper

# show kafka
kafka:
	cd docker && docker-compose logs -f --tail 200 kafka

### 4. component control command
start-godwoken:
	cd docker && docker-compose start godwoken

stop-godwoken:
	cd docker && docker-compose stop godwoken

start-godwoken-readonly:
	cd docker && docker-compose start godwoken-readonly

stop-godwoken-readonly:
	cd docker && docker-compose stop godwoken-readonly

start-polyjuice:
	cd docker && docker-compose start polyjuice

stop-polyjuice:
	cd docker && docker-compose stop polyjuice

start-web3:
	cd docker && docker-compose start web3

stop-web3:
	cd docker && docker-compose stop web3

start-web3-indexer:
	cd docker && docker-compose start web3-indexer

stop-web3-indexer:
	cd docker && docker-compose stop web3-indexer

start-ckb:
	cd docker && docker-compose start ckb

start-ckb2:
	cd docker && docker-compose start ckb2

start-ckb3:
	cd docker && docker-compose start ckb3

stop-ckb:
	cd docker && docker-compose stop ckb

stop-ckb2:
	cd docker && docker-compose stop ckb2

stop-ckb3:
	cd docker && docker-compose stop ckb3

start-db:
	cd docker && docker-compose start postgres

stop-db:
	cd docker && docker-compose stop postgres

start-call-polyman:
	cd docker && docker-compose start call-polyman

stop-call-polyman:
	cd docker && docker-compose stop call-polyman

start-redis:
	cd docker && docker-compose start redis

stop-redis:
	cd docker && docker-compose stop redis

start-zookeeper:
	cd docker && docker-compose start zookeeper

stop-zookeeper:
	cd docker && docker-compose stop zookeeper

start-kafka:
	cd docker && docker-compose start kafka

stop-kafka:
	cd docker && docker-compose stop kafka

### 5. component interact command
enter-godwoken:
	cd docker && docker-compose exec godwoken bash

enter-godwoken-readonly:
	cd docker && docker-compose exec godwoken-readonly bash

enter-polyjuice:
	cd docker && docker-compose exec polyjuice bash

enter-web3:
	cd docker && docker-compose exec web3 bash

enter-web3-indexer:
	cd docker && docker-compose exec web3-indexer bash

enter-ckb:
	cd docker && docker-compose exec ckb bash

enter-ckb2:
	cd docker && docker-compose exec ckb2 bash

enter-ckb3:
	cd docker && docker-compose exec ckb3 bash

enter-db:
	cd docker && docker-compose exec postgres bash

enter-call-polyman:
	cd docker && docker-compose exec call-polyman bash

enter-redis:
	cd docker && docker-compose exec redis bash

enter-zookeeper:
	cd docker && docker-compose exec zookeeper bash

enter-kafka:
	cd docker && docker-compose exec kafka bash

########### manual-build-mode #############
### rebuild components's scripts and bin all in one
rebuild-scripts: rebuild-gw-scripts-and-bin rebuild-polyjuice-bin rebuild-omni-lock

#### rebuild components's scripts and bin standalone
rebuild-polyjuice-bin:
	cd packages/godwoken-polyjuice && make all-via-docker
	cp packages/godwoken-polyjuice/build/validator_log workspace/scripts/release/polyjuice-validator
	cp packages/godwoken-polyjuice/build/generator_log workspace/deploy/polyjuice-backend/polyjuice-generator
	cp packages/godwoken-polyjuice/build/generator_log.aot workspace/deploy/polyjuice-backend/polyjuice-generator.aot
	cp packages/godwoken-polyjuice/build/validator_log workspace/deploy/polyjuice-backend/polyjuice-validator
	cp packages/godwoken-polyjuice/build/eth_addr_reg_validator workspace/scripts/release/eth_addr_reg_validator
	cp packages/godwoken-polyjuice/build/eth_addr_reg_generator workspace/deploy/polyjuice-backend/eth_addr_reg_generator
	cp packages/godwoken-polyjuice/build/eth_addr_reg_validator workspace/deploy/polyjuice-backend/eth_addr_reg_validator

rebuild-gw-scripts-and-bin:
	cd packages/godwoken-scripts && cd c && make && cd - && capsule build --release --debug-output
	cp packages/godwoken-scripts/build/release/* workspace/scripts/release/
	cp packages/godwoken-scripts/c/build/meta-contract-validator workspace/scripts/release/
	cp packages/godwoken-scripts/c/build/meta-contract-generator workspace/deploy/backend/meta-contract-generator
	cp packages/godwoken-scripts/c/build/meta-contract-validator workspace/deploy/backend/meta-contract-validator
	cp packages/godwoken-scripts/c/build/sudt-validator workspace/scripts/release/
	cp packages/godwoken-scripts/c/build/sudt-generator workspace/deploy/backend/sudt-generator
	cp packages/godwoken-scripts/c/build/sudt-validator workspace/deploy/backend/sudt-validator

rebuild-omni-lock:
	cd packages/ckb-production-scripts && git submodule update --init --recursive --depth=1 && make all-via-docker
	cp packages/ckb-production-scripts/build/omni_lock workspace/scripts/release/

########## prebuild-quick-mode #############
rm-dummy-docker-if-name-exits: SHELL:=/bin/bash
rm-dummy-docker-if-name-exits:
	source ./gw_util.sh && remove_dummy_docker_if_exits

copy-godwoken-bin-from-docker: rm-dummy-docker-if-name-exits
	mkdir -p `pwd`/quick-mode/godwoken
	docker run -it -d --name dummy $$DOCKER_PREBUILD_IMAGE_NAME:$$DOCKER_PREBUILD_IMAGE_TAG
	docker cp dummy:/bin/godwoken `pwd`/quick-mode/godwoken/godwoken
	docker cp dummy:/bin/gw-tools `pwd`/quick-mode/godwoken/gw-tools
	docker rm -f dummy
# paste the prebuild bin to workspace dir for use
	cp quick-mode/godwoken/godwoken workspace/bin/
	cp quick-mode/godwoken/gw-tools workspace/bin/

copy-polyjuice-bin-from-docker:	rm-dummy-docker-if-name-exits
	mkdir -p `pwd`/quick-mode/polyjuice
	docker run -it -d --name dummy $$DOCKER_PREBUILD_IMAGE_NAME:$$DOCKER_PREBUILD_IMAGE_TAG
	docker cp dummy:/scripts/godwoken-polyjuice/. `pwd`/quick-mode/polyjuice
	docker rm -f dummy
# paste the prebuild bin to workspace dir for use
	cp quick-mode/polyjuice/validator_log workspace/scripts/release/polyjuice-validator
	cp quick-mode/polyjuice/generator_log workspace/deploy/polyjuice-backend/polyjuice-generator
	cp quick-mode/polyjuice/generator_log.aot workspace/deploy/polyjuice-backend/polyjuice-generator.aot
	cp quick-mode/polyjuice/validator_log workspace/deploy/polyjuice-backend/polyjuice-validator
	cp quick-mode/polyjuice/eth_addr_reg_validator workspace/scripts/release/eth_addr_reg_validator
	cp quick-mode/polyjuice/eth_addr_reg_generator workspace/deploy/polyjuice-backend/eth_addr_reg_generator
	cp quick-mode/polyjuice/eth_addr_reg_validator workspace/deploy/polyjuice-backend/eth_addr_reg_validator

copy-gw-scripts-and-bin-from-docker: rm-dummy-docker-if-name-exits
	mkdir -p `pwd`/quick-mode/godwoken
	docker run -it -d --name dummy $$DOCKER_PREBUILD_IMAGE_NAME:$$DOCKER_PREBUILD_IMAGE_TAG
	docker cp dummy:/scripts/godwoken-scripts/. `pwd`/quick-mode/godwoken
	docker rm -f dummy
# paste the prebuild bin to workspace dir for use
	cp quick-mode/godwoken/meta-contract-validator workspace/scripts/release/
	cp quick-mode/godwoken/meta-contract-generator workspace/deploy/backend/meta-contract-generator
	cp quick-mode/godwoken/meta-contract-validator workspace/deploy/backend/meta-contract-validator
	cp quick-mode/godwoken/sudt-validator workspace/scripts/release/
	cp quick-mode/godwoken/sudt-generator workspace/deploy/backend/sudt-generator
	cp quick-mode/godwoken/sudt-validator workspace/deploy/backend/sudt-validator
# paste the prebuild scripts to workspace dir for use
	cp quick-mode/godwoken/withdrawal-lock workspace/scripts/release/
	cp quick-mode/godwoken/eth-account-lock workspace/scripts/release/
	cp quick-mode/godwoken/tron-account-lock workspace/scripts/release/
	cp quick-mode/godwoken/stake-lock workspace/scripts/release/
	cp quick-mode/godwoken/challenge-lock workspace/scripts/release/
	cp quick-mode/godwoken/state-validator workspace/scripts/release/
	cp quick-mode/godwoken/custodian-lock workspace/scripts/release/
	cp quick-mode/godwoken/deposit-lock workspace/scripts/release/
	cp quick-mode/godwoken/always-success workspace/scripts/release/

copy-omni-lock-from-docker:
	mkdir -p workspace/scripts/release/
	docker run --rm -v`pwd`/workspace/scripts/release/:/target-dir/ \
	  $$DOCKER_PREBUILD_IMAGE_NAME:$$DOCKER_PREBUILD_IMAGE_TAG \
  	  cp /scripts/godwoken-scripts/omni_lock /target-dir/

copy-web3-indexer-bin-from-docker: rm-dummy-docker-if-name-exits
	mkdir -p `pwd`/quick-mode/web3
	docker run -it -d --name dummy $$DOCKER_WEB3_INDEXER_PREBUILD_IMAGE_NAME:$$DOCKER_WEB3_INDEXER_PREBUILD_IMAGE_TAG
	docker cp dummy:/bin/gw-web3-indexer `pwd`/quick-mode/web3/gw-web3-indexer
	docker rm -f dummy
# paste the prebuild bin to workspace dir for use
	cp quick-mode/web3/gw-web3-indexer workspace/bin/

copy-godwoken-binary-from-packages-to-workspace:
	mkdir -p workspace/bin
	cp packages/godwoken/target/release/godwoken workspace/bin/godwoken
	cp packages/godwoken/target/release/gw-tools workspace/bin/gw-tools

copy-godwoken-binary-from-packages-to-manual-artifacts:
	mkdir -p docker/manual-artifacts/
	echo 'cp packages/godwoken/target/release/godwoken docker/manual-artifacts/godwoken'
	echo 'cp packages/godwoken/target/release/gw-tools docker/manual-artifacts/gw-tools'
	cp packages/godwoken/target/release/godwoken docker/manual-artifacts/godwoken
	cp packages/godwoken/target/release/gw-tools docker/manual-artifacts/gw-tools

copy-web3-indexer-binary-from-packages-to-workspace:
	mkdir -p workspace/bin
	cp packages/godwoken-web3/target/release/gw-web3-indexer workspace/bin/gw-web3-indexer

copy-web3-indexer-binary-from-packages-to-manual-artifacts:
	mkdir -p docker/manual-artifacts/
	echo 'cp packages/godwoken-web3/target/release/gw-web3-indexer /docker/manual-artifacts/gw-web3-indexer'
	cp packages/godwoken-web3/target/release/gw-web3-indexer docker/manual-artifacts/gw-web3-indexer

copy-web3-from-packages-to-manual-artifacts:
	rm -rf docker/manual-artifacts/godwoken-web3/
	mkdir -p docker/manual-artifacts/godwoken-web3/
	echo 'cp -r packages/godwoken-web3/packages/ docker/manual-artifacts/godwoken-web3/'
	cp -r packages/godwoken-web3/packages/ docker/manual-artifacts/godwoken-web3/

copy-web3-node-modules-if-empty:
	docker run --rm -v `pwd`/packages/godwoken-web3:/app $$DOCKER_WEB3_PREBUILD_IMAGE_NAME:$$DOCKER_WEB3_PREBUILD_IMAGE_TAG /bin/bash -c "cd app && yarn check --verify-tree && cd .. || ( cd .. && echo 'start copying web3 node_modules from docker to local package..' && cp -r ./godwoken-web3/node_modules ./app/) ;"

copy-polyman-node-modules-if-empty::
	docker run --rm -v `pwd`/packages/godwoken-polyman:/app $$DOCKER_POLYMAN_PREBUILD_IMAGE_NAME:$$DOCKER_POLYMAN_PREBUILD_IMAGE_TAG /bin/bash -c "cd app && yarn check --verify-tree && cd .. || ( cd .. && echo 'start copying polyman node_modules from docker to local package..' && cp -r ./godwoken-polyman/node_modules ./app/) ;"

install-web3-node-modules-if-empty:
	cd `pwd`/packages/godwoken-web3 && yarn check --verify-tree && cd .. || yarn install

install-polyman-node-modules-if-empty:
	cd `pwd`/packages/godwoken-polyman && yarn check --verify-tree && cd .. || yarn install

patch-lumos-indexer-for-polyman:
	cp `pwd`/patches/lumos-indexer-linux/index.node `pwd`/packages/godwoken-polyman/node_modules/@ckb-lumos/indexer/native/index.node

### 7. godwoken gen schema helper command
SHELL:=/bin/bash
gen-schema: clean-schema
	cd plugins/gw-schema && source generate.sh 

clean-schema:
	cd plugins/gw-schema && rm -rf schemas/*

prepare-schema-for-polyman: gen-schema
	cp -r ./plugins/gw-schema/schemas/* ./packages/godwoken-polyman/packages/godwoken/schemas/
	cd ./packages/godwoken-polyman/packages/godwoken/schemas/ && for filename in index*; do mv "$filename" "${filename//index/godwoken}"; done

prepare-schema-for-web3:
	make gen-schema
	cp -r ./docker/gen-godwoken-schema/schemas/godwoken.* ./packages/godwoken-web3/packages/godwoken/
	mv ./godwoken-web3/packages/godwoken/godwoken.d.ts ./packages/godwoken-web3/packages/godwoken/schemas/index.d.ts
	mv ./godwoken-web3/packages/godwoken/godwoken.esm.js ./packages/godwoken-web3/packages/godwoken/schemas/index.esm.js
	mv ./godwoken-web3/packages/godwoken/godwoken.js ./packages/godwoken-web3/packages/godwoken/schemas/index.js
	mv ./godwoken-web3/packages/godwoken/godwoken.json ./packages/godwoken-web3/packages/godwoken/schemas/index.json

########### helper function #############
connect-ckb:
	cd plugins/chaos && yarn connect

watch-reorg:
	cd plugins/chaos && yarn watch > chain-reorg.log 2>&1 &

delay-ckb:
	pumba -v && echo "ready to delay ckb network..." || echo "you need to install Pumba, https://github.com/alexei-led/pumba";
	pumba netem --duration 50s --tc-image gaiadocker/iproute2 delay --time 3000 docker_ckb3_1 & pumba netem --duration 50s --tc-image gaiadocker/iproute2 delay --time 3000 docker_ckb2_1

chaos: SHELL:=/bin/bash
chaos:
	source gw_util.sh && start_chaos > chaos.log 2>&1 &

show-reorg:
	cat chain-reorg.log | grep "reorgs!"


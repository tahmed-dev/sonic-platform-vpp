#  Copyright (c) 2024 Cisco and/or its affiliates.
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at:

#      http://www.apache.org/licenses/LICENSE-2.0

#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

.ONESHELL:
SHELL = /bin/bash
.SHELLFLAGS += -e

USER = $(shell id -un)
UID = $(shell id -u)
GUID = $(shell id -g)

VPP_REPO_DIR = repo
VPP_CUSTOM_PLUGINS_DIR = plugins
VPP_BUILD_JOBS ?= $(or $(SONIC_CONFIG_MAKE_JOBS),4)

# VPP source is tracked as a git submodule at $(VPP_REPO_DIR).
# The submodule commit pins the exact VPP version to build.
# To update: cd $(VPP_REPO_DIR) && git checkout <new-commit> && cd .. && git add repo

# Patch series applied in order on top of the submodule checkout.
# vpp.patch                  - SONiC adaptations (libnl, libbpf, vxlan export, version)
# vpp-l2-barrier-sync.patch  - Fix SIGSEGV in l2output_node when adding interfaces
#                               to bridge-domain with active worker threads.
#                               Wraps bd_add/remove_member and l2_output_config vec
#                               resizes with vlib_worker_thread_barrier_sync/release.
VPP_PATCHES = vpp.patch vpp-l2-barrier-sync.patch

MAIN_TARGET = $(VPPINFRA)
DERIVED_TARGETS = $(VPP_MAIN) $(VPP_PLUGIN_CORE) $(VPP_PLUGIN_DPDK) \
				  $(VPP_PLUGIN_DEV) $(VPP_DEV) $(VPPINFRA_DEV) $(VPPDBG)
ALL_TARGETS = $(MAIN_TARGET) $(DERIVED_TARGETS)

.PHONY: repo_prep build_locally

repo_prep:
	git submodule update --init $(VPP_REPO_DIR)
	cp -r $(VPP_CUSTOM_PLUGINS_DIR)/* $(VPP_REPO_DIR)/src/plugins/
	pushd $(VPP_REPO_DIR)
	$(foreach patch,$(VPP_PATCHES),\
		echo "Applying $(patch)..." && git apply ../$(patch) && \
	) true
	popd

$(addprefix $(DEST)/, $(MAIN_TARGET)): build_locally

build_locally: repo_prep
	pushd $(VPP_REPO_DIR)
	make UNATTENDED=y PLATFORM=vpp DPDK_MLX4_PMD=n DPDK_MLX5_PMD=n DPDK_MLX5_COMMON_PMD=n install-dep
	make PLATFORM=vpp DPDK_MLX4_PMD=n DPDK_MLX5_PMD=n DPDK_MLX5_COMMON_PMD=n install-ext-deps
	make UNATTENDED=y PLATFORM=vpp \
		-j$(VPP_BUILD_JOBS) DPDK_MLX4_PMD=n DPDK_MLX5_PMD=n DPDK_MLX5_COMMON_PMD=n pkg-deb
	pushd build-root
	@for target in *_$(CONFIGURED_ARCH).deb; do \
		cp $$target $(DEST)/; \
	done
	popd
	popd

$(addprefix $(DEST)/, $(DERIVED_TARGETS)): $(DEST)/% : $(DEST)/$(MAIN_TARGET)

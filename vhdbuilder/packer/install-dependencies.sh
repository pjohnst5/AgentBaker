#!/bin/bash
source /home/packer/provision_installs.sh
source /home/packer/provision_source.sh
source /home/packer/tool_installs.sh
source /home/packer/packer_source.sh
source /home/packer/image_cache.sh

VHD_LOGS_FILEPATH=/opt/azure/vhd-install.complete

echo "Starting build on " $(date) > ${VHD_LOGS_FILEPATH}

copyPackerFiles

echo ""
echo "Components downloaded in this VHD build (some of the below components might get deleted during cluster provisioning if they are not needed):" >> ${VHD_LOGS_FILEPATH}

AUDITD_ENABLED=true
installDeps
cat << EOF >> ${VHD_LOGS_FILEPATH}
  - apache2-utils
  - apt-transport-https
  - auditd
  - blobfuse=1.1.1
  - ca-certificates
  - ceph-common
  - cgroup-lite
  - cifs-utils
  - conntrack
  - cracklib-runtime
  - ebtables
  - ethtool
  - fuse
  - git
  - glusterfs-client
  - init-system-helpers
  - iproute2
  - ipset
  - iptables
  - jq
  - libpam-pwquality
  - libpwquality-tools
  - mount
  - nfs-common
  - pigz socat
  - traceroute
  - util-linux
  - xz-utils
  - zip
EOF

if [[ ${UBUNTU_RELEASE} == "18.04" ]]; then
  overrideNetworkConfig || exit 1
  disableSystemdTimesyncdAndEnableNTP || exit 1
fi

if [[ ${CONTAINER_RUNTIME:-"docker"} == "containerd" ]]; then
  echo "VHD will be built with containerd as runtime" >> ${VHD_LOGS_FILEPATH}
else
  echo "VHD will be built with docker as runtime" >> ${VHD_LOGS_FILEPATH}
fi

installBpftrace
echo "  - bpftrace" >> ${VHD_LOGS_FILEPATH}

MOBY_VERSION="19.03.12"

installMoby
echo "  - moby v${MOBY_VERSION}" >> ${VHD_LOGS_FILEPATH}

if [[ ${CONTAINER_RUNTIME} == "containerd" ]]; then
  # start up a bg containerd process if not yet started
  containerdPID=$(startContainerd)
  ctr namespace create k8s.io
fi

installGPUDrivers
echo "  - nvidia-docker2 nvidia-container-runtime" >> ${VHD_LOGS_FILEPATH}
retrycmd_if_failure 30 5 3600 apt-get -o Dpkg::Options::="--force-confold" install -y nvidia-container-runtime="${NVIDIA_CONTAINER_RUNTIME_VERSION}+docker18.09.2-1" --download-only || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
echo "  - nvidia-container-runtime=${NVIDIA_CONTAINER_RUNTIME_VERSION}+docker18.09.2-1" >> ${VHD_LOGS_FILEPATH}

if grep -q "fullgpu" <<< "$FEATURE_FLAGS"; then
    echo "  - ensureGPUDrivers" >> ${VHD_LOGS_FILEPATH}
    ensureGPUDrivers
fi

installBcc
cat << EOF >> ${VHD_LOGS_FILEPATH}
  - bcc-tools
  - libbcc-examples
EOF

VNET_CNI_VERSIONS="
1.1.7
1.1.6
1.1.3
"
for VNET_CNI_VERSION in $VNET_CNI_VERSIONS; do
    VNET_CNI_PLUGINS_URL="https://acs-mirror.azureedge.net/azure-cni/v${VNET_CNI_VERSION}/binaries/azure-vnet-cni-linux-amd64-v${VNET_CNI_VERSION}.tgz"
    downloadAzureCNI
    echo "  - Azure CNI version ${VNET_CNI_VERSION}" >> ${VHD_LOGS_FILEPATH}
done

CNI_PLUGIN_VERSIONS="
0.7.6
0.7.5
0.7.1
"
for CNI_PLUGIN_VERSION in $CNI_PLUGIN_VERSIONS; do
    CNI_PLUGINS_URL="https://acs-mirror.azureedge.net/cni/cni-plugins-amd64-v${CNI_PLUGIN_VERSION}.tgz"
    downloadCNI
    echo "  - CNI plugin version ${CNI_PLUGIN_VERSION}" >> ${VHD_LOGS_FILEPATH}
done

CNI_PLUGIN_VERSIONS="
0.8.6
"
for CNI_PLUGIN_VERSION in $CNI_PLUGIN_VERSIONS; do
    CNI_PLUGINS_URL="https://acs-mirror.azureedge.net/cni-plugins/v${CNI_PLUGIN_VERSION}/binaries/cni-plugins-linux-amd64-v${CNI_PLUGIN_VERSION}.tgz"
    downloadCNI
    echo "  - CNI plugin version ${CNI_PLUGIN_VERSION}" >> ${VHD_LOGS_FILEPATH}
done


if [[ "${CONTAINER_RUNTIME}" == "containerd" ]]; then
  CRICTL_VERSION="v1.17.0"
  export CRICTL_DOWNLOAD_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  installCrictl
  echo "  - crictl version ${CRICTL_VERSION}" >> ${VHD_LOGS_FILEPATH}
fi

# pre-pull system images 
pullSystemImages ${CONTAINER_RUNTIME}

# pull k8s component images and extract components
pullKubeComponents ${CONTAINER_RUNTIME}

# pre-pull additional addon images
pullAddonImages ${CONTAINER_RUNTIME}

if [[ ${containerdPID:-""} != "" ]]; then
  echo "Killing background containerd process. PID=${containerdPID}" >> ${VHD_LOGS_FILEPATH}
  kill -9 ${containerdPID}
fi

# shellcheck disable=SC2010
ls -ltr /dev/* | grep sgx >>  ${VHD_LOGS_FILEPATH} 

df -h

# warn at 75% space taken
[ -s $(df -P | grep '/dev/sda1' | awk '0+$5 >= 75 {print}') ] || echo "WARNING: 75% of /dev/sda1 is used" >> ${VHD_LOGS_FILEPATH}
# error at 99% space taken
[ -s $(df -P | grep '/dev/sda1' | awk '0+$5 >= 99 {print}') ] || exit 1

echo "Using kernel:" >> ${VHD_LOGS_FILEPATH}
tee -a ${VHD_LOGS_FILEPATH} < /proc/version
{
  echo "Install completed successfully on " $(date)
  echo "VSTS Build NUMBER: ${BUILD_NUMBER}"
  echo "VSTS Build ID: ${BUILD_ID}"
  echo "Commit: ${COMMIT}"
  echo "Ubuntu version: ${UBUNTU_RELEASE}"
  echo "Hyperv generation: ${HYPERV_GENERATION}"
  echo "Feature flags: ${FEATURE_FLAGS}"
} >> ${VHD_LOGS_FILEPATH}

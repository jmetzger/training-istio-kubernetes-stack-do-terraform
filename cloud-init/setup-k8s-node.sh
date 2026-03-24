#!/bin/bash
set -euo pipefail

K8S_VERSION="v1.35"

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Update & install basic tools
apt-get update && apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  gnupg2 \
  lsb-release \
  software-properties-common

# Install containerd
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Configure containerd to use systemd cgroups
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# Add Kubernetes repo and keys
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ / # ${K8S_VERSION}
EOF

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Enable networking
modprobe br_netfilter
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Log result
echo "Kubernetes ${K8S_VERSION} installiert auf $(hostname)"

# Needed for training to access it 
groupadd sshadmin
USERS="11trainingdo $(echo tln{1..20})"
echo $USERS
for USER in $USERS
do
  echo "Adding user $USER"
  useradd -s /bin/bash --create-home $USER
  usermod -aG sshadmin $USER
  echo "$USER:11essen22" | chpasswd
done

# We can sudo with 11trainingdo
usermod -aG sudo 11trainingdo 

# 20.04 and 22.04 this will be in the subfolder
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]
then
  sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
fi

# seen this in ubuntu 24.04 important here
if [ -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf ]
then
  sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
fi

## both is needed 
sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config
usermod -aG sshadmin root

# TBD - Delete AllowUsers Entries with sed 
# otherwice we cannot login by group 
echo "AllowGroups sshadmin" >> /etc/ssh/sshd_config 

# Looks like it takes a while till ssh is running 
date > /var/log/training_reload_ssh
systemctl restart ssh 



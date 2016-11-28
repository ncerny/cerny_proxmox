#
# Cookbook Name:: cerny_proxmox
# Recipe:: default
#
# Copyright 2016 Nathan Cerny
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# rubocop:disable LineLength

template '/etc/network/interfaces' do
  source 'interfaces.erb'
  variables copper_interfaces: 'eth0 eth1 eth2 eth3',
            optical_interfaces: 'eth4',
            cluster_interface: 'eth5',
            ip: "1#{node['hostname'][-1]}"
end

apt_repository 'pve-enterprise' do
  action :remove
end

apt_repository 'pve-no-subscription' do
  uri 'http://download.proxmox.com/debian'
  distribution node['lsb']['codename'] || 'jessie'
  components ['pve-no-subscription']
  notifies :update, 'apt_update[pve]', :immediately
end

apt_update 'pve' do
  action :periodic
  frequency 86_400
  notifies :run, 'execute[dist-upgrade]', :immediately
end

file '/etc/apt/apt.conf.d/15update-stamp' do
  content 'APT::Update::Post-Invoke-Success {"touch /var/lib/apt/periodic/update-success-stamp 2>/dev/null || true";};'
end

execute 'dist-upgrade' do
  action :nothing
  command 'apt-get -y dist-upgrade'
  notifies :reboot_now, 'reboot[reboot-for-upgrades]', :immediately
  not_if do
    ::File.exist?('/etc/apt/apt.conf.d/15update-stamp') &&
      (::DateTime.now - ::File.mtime('/etc/apt/apt.conf.d/15update-stamp')).to_i <= 7
  end
  only_if { ::Date.today.wday.eql?(node['hostname'][-2, 2].to_i % 7) }
end

reboot 'reboot-for-upgrades' do
  action :nothing
  only_if { reboot_pending? }
end

execute 'join proxmox cluster' do
  if node['hostname'].eql?('pve01')
    command 'pvecm create proxmox -bindnet0_addr 172.16.40.11 -ring0_addr 172.16.40.11'
  else
    command "pvecm add 172.16.40.11 -nodeid #{node['hostname'][-1]} -ring0_addr 172.16.40.1#{node['hostname'][-1]}"
  end
  not_if { ::File.exist?('/etc/pve/corosync.conf') }
end

#
#
#
# fdisk -u /dev/sdd
#
#
# pvcreate /dev/sdd1
# vgcreate pvedata /dev/sdd1
# lvcreate -n data -L 400G pvedata
# mkfs.xfs -i size=512 /dev/pvedata/data
#
#
# vi /etc/fstab
#
#
# umount /var/lib/vz && mount -a

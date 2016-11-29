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

apt_repository 'glusterfs' do
  uri 'http://download.gluster.org/pub/gluster/glusterfs/3.9/LATEST/Debian/jessie/apt'
  distribution node['lsb']['codename'] || 'jessie'
  components ['main']
  key 'http://download.gluster.org/pub/gluster/glusterfs/3.9/rsa.pub'
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

%w(lsb-release glusterfs-server glusterfs-client).each do |pkg|
  package pkg
end

include_recipe 'lvm::default'

# VM Disks
pve_pvs = []
node['block_device'].each do |drive, props|
  pve_pvs << "/dev/#{drive}" if props['model'].eql?('MK3001GRRB')
end

lvm_volume_group 'pvedata' do
  physical_volumes pve_pvs
  wipe_signatures true

  thin_pool 'vmstore' do
    size '99%VG'
  end
end

# GlusterFS Disks
gluster_pvs = []
node['block_device'].each do |drive, props|
  gluster_pvs << "/dev/#{drive}" if props['model'].eql?('MBF2600RC')
end
unless gluster_pvs.empty?
  directory '/export/gv0' do
    recursive true
  end

  lvm_volume_group 'glusterfs' do
    physical_volumes gluster_pvs
    wipe_signatures true

    logical_volume 'gv0' do
      size        '99%VG'
      filesystem  'xfs'
      mount_point location: '/export/gv0'
      stripes     2
    end
  end

  directory '/export/gv0/brick'

  gluster_hosts = %w(pve01.infra.cerny.cc pve02.infra.cerny.cc)
  gluster_hosts.each do |host|
    execute "GlusterFS: Configure the Trusted Pool - #{host}" do
      command "gluster peer probe #{host}"
      not_if { node['fqdn'].eql?(host) }
      not_if "gluster peer status | grep #{host}"
    end
  end

  bricks = ''
  gluster_hosts.each do |host|
    bricks << "#{host}:/export/gv0/brick "
  end

  # setfattr -x trusted.glusterfs.volume-id /export/gv0/brick
  # setfattr -x trusted.gfid /export/gv0/brick

  execute 'GlusterFS: Create Volume gv0' do
    command "gluster volume create gv0 replica #{gluster_hosts.count} #{bricks}"
    not_if 'gluster volume status gv0'
  end

  execute 'GlusterFS: Start volume gv0' do
    command 'gluster volume start gv0'
    not_if 'gluster volume info gv0 | grep Status | grep Started'
  end
end

execute 'PVE: Remove default storage - local-lvm' do
  command 'pvesh delete /storage/local-lvm'
  only_if 'pvesh get /storage/local-lvm'
end

execute 'PVE: Configure Thin-LVM Storage' do
  command 'pvesh create /storage -storage lvm -type lvmthin -content rootdir,images -vgname pvedata -thinpool vmstore'
  not_if 'pvesh get /storage/lvm'
end

execute 'PVE: Configure GlusterFS Storage' do
  command 'pvesh create /storage -storage gluster -type glusterfs -content images,iso,vztmpl -server pve01.infra.cerny.cc -server2 pve02.infra.cerny.cc -transport tcp -volume gv0'
  not_if 'pvesh get /storage/gluster'
end

{
  'CentOS-7-x86_64-Minimal-1511.iso' => 'http://mirrors.mit.edu/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-1511.iso',
  'centos-7-default' => :system,
  'ubuntu-14.04-standard' => :system,
  'ubuntu-16.04-standard' => :system
}.each do |fn, src|
  if src.is_a?(String)
    remote_file fn do
      source src
      not_if "pvesh get /nodes/#{node['hostname']}/storage/gluster/content | grep #{fn}"
      notifies :run, "execute[GlusterFS: Upload #{fn}]", :immediately
    end
    execute "GlusterFS: Upload #{fn}" do
      command "pvesh create /nodes/#{node['hostname']}/storage/gluster/upload -content #{(fn.end_with?('iso') ? 'iso' : 'vztmpl')} -filename #{fn} -tmpfilename #{fn}"
      action :nothing
    end
  elsif src.is_a?(Symbol)
    vztmpl = {}
    Mixlib::ShellOut.new('pveam available').run_command.stdout.each_line do |line|
      line = line.split
      vztmpl[line[0]] ||= []
      vztmpl[line[0]] << line[1]
    end

    vztmpl[src.to_s].select { |n| n =~ /#{fn}/ }.each do |f|
      execute "GlusterFS: Upload #{f}" do
        command "pveam download gluster #{f}"
        not_if "pvesh get /nodes/#{node['hostname']}/storage/gluster/content | grep #{f}"
      end
    end
  end
end

# Ceph Cache Disks
# TXA2D20400GA6001

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
